defmodule Membrane.HLS.Source do
  use Membrane.Source

  alias HLS.FS.Reader
  alias HLS.Playlist.Media.Tracker
  alias HLS.Playlist
  alias HLS.Playlist.Master
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias Membrane.HLS.TaskSupervisor

  @master_check_retry_interval_ms 1_000
  require Membrane.Logger

  def_output_pad(:output,
    mode: :pull,
    availability: :on_request,
    accepted_format:
      %Membrane.RemoteStream{content_format: %format{}}
      when format in [Format.PackedAudio, Format.WebVTT, Format.MPEG]
  )

  def_options(
    reader: [
      spec: HLS.FS.Reader.t(),
      description: "HLS.Reader implementation used to obtain playlist's contents"
    ],
    master_playlist_uri: [
      spec: URI.t(),
      description: "URI of the master playlist"
    ]
  )

  @impl true
  def handle_init(_ctx, options) do
    {[],
     %{
       reader: options.reader,
       master_playlist_uri: options.master_playlist_uri,
       pad_to_tracker: %{},
       ref_to_pad: %{}
     }}
  end

  @impl true
  def handle_pad_added(pad = {Membrane.Pad, :output, {:rendition, rendition}}, _, state) do
    {:ok, pid} = Tracker.start_link(state.reader)
    target = build_target(rendition)
    ref = Tracker.follow(pid, target)

    config = %{
      tracking: ref,
      tracker: pid,
      ready: Q.new("hls-ready-#{rendition.uri.path}"),
      pending: Q.new("hls-pending-#{rendition.uri.path}"),
      download: nil,
      closed: false
    }

    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, config)}
    state = %{state | ref_to_pad: Map.put(state.ref_to_pad, ref, pad)}

    {[
       {:stream_format,
        {pad, %Membrane.RemoteStream{content_format: build_stream_format(rendition)}}}
     ], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(self(), :check_master_playlist)
    {[], state}
  end

  @impl true
  def handle_demand(pad, size, :buffers, _ctx, state) do
    tracker = Map.fetch!(state.pad_to_tracker, pad)
    {actions, ready} = Q.take(tracker.ready, size)

    actions =
      if tracker.closed and Q.empty?(ready) and Q.empty?(tracker.pending) and
           is_nil(tracker.download) do
        actions ++ [{:end_of_stream, pad}]
      else
        actions
      end

    tracker = %{tracker | ready: ready}
    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}

    {actions, state}
  end

  @impl true
  def handle_info(
        :check_master_playlist,
        _ctx,
        state = %{reader: reader, master_playlist_uri: uri}
      ) do
    case Reader.read(reader, uri) do
      {:ok, data} ->
        playlist = Playlist.unmarshal(data, %Master{uri: uri})
        {[{:notify_parent, {:hls_master_playlist, playlist}}], state}

      {:error, reason} ->
        Membrane.Logger.warn("Master playlist check failed: #{inspect(reason)}")

        Membrane.Logger.warn(
          "Master playlist check attempt scheduled in #{@master_check_retry_interval_ms}ms"
        )

        Process.send_after(self(), :check_master_playlist, @master_check_retry_interval_ms)
        {[], state}
    end
  end

  def handle_info({:segment, ref, segment}, _ctx, state) do
    Membrane.Logger.debug("HLS segment received on #{inspect(ref)}: #{inspect(segment)}")

    pad = Map.fetch!(state.ref_to_pad, ref)
    tracker = Map.fetch!(state.pad_to_tracker, pad)

    tracker =
      tracker
      |> Map.update!(:pending, &Q.push(&1, segment))
      |> start_download(state.reader)

    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}
    {[], state}
  end

  def handle_info({task_ref, result}, _ctx, state) when is_reference(task_ref) do
    # The task succeed so we can cancel the monitoring and discard the DOWN message
    Process.demonitor(task_ref, [:flush])

    {pad, tracker} = tracker_by_task_ref!(state.pad_to_tracker, task_ref)
    segment = tracker.download.segment

    tracker =
      case result do
        {:ok, data} ->
          action = {:buffer, {pad, %Buffer{payload: data, metadata: segment}}}
          ready = Q.push(tracker.ready, action)
          %{tracker | ready: ready, download: nil}

        {:error, message} ->
          Membrane.Logger.warn(
            "HLS could not get segment #{inspect(segment.uri)}: #{inspect(message)}"
          )

          %{tracker | download: nil}
      end

    tracker = start_download(tracker, state.reader)
    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}
    {[{:redemand, pad}], state}
  end

  def handle_info({:DOWN, task_ref, _, _, reason}, _ctx, state) do
    {pad, tracker} = tracker_by_task_ref!(state.pad_to_tracker, task_ref)
    segment = tracker.download.segment

    Membrane.Logger.warn("HLS could not get segment #{inspect(segment.uri)}: #{inspect(reason)}")

    tracker =
      tracker
      |> Map.replace!(:download, nil)
      |> start_download(state.reader)

    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}

    {[{:redemand, pad}], state}
  end

  def handle_info({:start_of_track, _ref, _next_sequence}, _ctx, state) do
    {[], state}
  end

  def handle_info({:end_of_track, ref}, _ctx, state) do
    Membrane.Logger.debug("HLS end_of_track received on #{inspect(ref)}")

    pad = Map.fetch!(state.ref_to_pad, ref)
    tracker = Map.fetch!(state.pad_to_tracker, pad)
    Tracker.stop(tracker.tracker)
    tracker = %{tracker | closed: true}

    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}

    {[{:redemand, pad}], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    Enum.each(state.pad_to_tracker, fn {_, %{tracker: pid, closed: closed}} ->
      unless closed, do: Tracker.stop(pid)
    end)

    {[terminate: :normal], %{state | pad_to_tracker: %{}, ref_to_pad: %{}}}
  end

  defp tracker_by_task_ref!(pad_to_tracker, task_ref) do
    tracker =
      Enum.find(pad_to_tracker, fn {_pad, tracker} ->
        tracker.download != nil and tracker.download.task_ref == task_ref
      end)

    tracker || raise "tracker with task reference #{inspect(task_ref)} not found"
  end

  defp start_download(%{download: nil} = tracker, reader) do
    case Q.pop(tracker.pending) do
      {{:value, segment}, queue} ->
        Membrane.Logger.debug("Starting download of segment: #{inspect(segment)}")

        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            Reader.read(reader, segment.uri)
          end)

        %{tracker | pending: queue, download: %{task_ref: task.ref, segment: segment}}

      {:empty, _q} ->
        tracker
    end
  end

  defp start_download(tracker, _reader), do: tracker

  defp build_target(%HLS.AlternativeRendition{uri: uri}), do: uri
  defp build_target(%HLS.VariantStream{uri: uri}), do: uri

  defp build_stream_format(%HLS.VariantStream{codecs: codecs}), do: %Format.MPEG{codecs: codecs}

  defp build_stream_format(%HLS.AlternativeRendition{type: :subtitles, language: lang}),
    do: %Format.WebVTT{language: lang}

  defp build_stream_format(%HLS.AlternativeRendition{type: :audio}), do: %Format.PackedAudio{}

  defp build_stream_format(rendition),
    do: raise(ArgumentError, "Unable to provide a proper cap for rendition #{inspect(rendition)}")
end
