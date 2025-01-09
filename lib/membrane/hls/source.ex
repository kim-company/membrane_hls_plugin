defmodule Membrane.HLS.Source do
  use Membrane.Source

  alias HLS.Tracker
  alias HLS.Playlist
  alias HLS.Playlist.Master
  alias HLS.Storage
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias Membrane.HLS.TaskSupervisor
  alias Membrane.HLS.TrackerSupervisor

  @master_check_retry_interval_ms 1_000
  require Membrane.Logger

  def_output_pad(:output,
    flow_control: :manual,
    availability: :on_request,
    accepted_format:
      %Membrane.RemoteStream{content_format: %format{}}
      when format in [Format.PackedAudio, Format.WebVTT, Format.MPEG]
  )

  def_options(
    storage: [
      spec: Storage.t(),
      description: "HLS.Storage implementation used to obtain playlist's contents"
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
       storage: options.storage,
       master_playlist_uri: options.master_playlist_uri,
       pad_to_tracker: %{},
       ref_to_pad: %{},
       monitor_to_pad: %{}
     }}
  end

  @impl true
  def handle_pad_added(pad = {Membrane.Pad, :output, {:rendition, rendition}}, _, state) do
    uri = Playlist.build_absolute_uri(state.master_playlist_uri, extract_uri(rendition))
    ref = make_ref()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        TrackerSupervisor,
        {Tracker,
         [
           media_playlist_uri: uri,
           storage: state.storage,
           ref: ref,
           owner: self()
         ]}
      )

    monitor_ref = Process.monitor(pid)

    config = %{
      media_uri: uri,
      monitor_ref: monitor_ref,
      tracking: ref,
      tracker: pid,
      ready: :queue.new(),
      pending: :queue.new(),
      download: nil,
      closed: false
    }

    state =
      state
      |> put_in([:pad_to_tracker, pad], config)
      # When the tracker sends us messages it forwards ref. We use this mapping
      # to retrieve the tracker.
      |> put_in([:ref_to_pad, ref], pad)
      # In case the tracker exits.
      |> put_in([:monitor_to_pad, monitor_ref], pad)

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
  def handle_demand(pad, _size, :buffers, _ctx, state) do
    tracker = get_in(state, [:pad_to_tracker, pad])

    # First take one ready if available.
    {actions, tracker} =
      get_and_update_in(tracker, [:ready], fn q ->
        case :queue.out(q) do
          {{:value, action}, q} -> {[action], q}
          {:empty, q} -> {[], q}
        end
      end)

    {actions, tracker} =
      cond do
        not is_nil(tracker.download) ->
          # We're already downloading another segment. We can chill out.
          {actions, tracker}

        not :queue.is_empty(tracker.pending) ->
          # The pending queue is not empty. Schedule a download.
          {actions, schedule_download!(tracker, state.storage)}

        not :queue.is_empty(tracker.ready) ->
          # We have other ready segments.
          {actions ++ [{:redemand, pad}], tracker}

        tracker.closed ->
          # Everything is out and the tracker is not going to provide
          # more segments. Time to close.
          {actions ++ [{:end_of_stream, pad}], tracker}

        true ->
          # We're waiting for more segments from the tracker.
          {actions, tracker}
      end

    state = put_in(state, [:pad_to_tracker, pad], tracker)

    {actions, state}
  end

  @impl true
  def handle_info(
        :check_master_playlist,
        _ctx,
        state = %{storage: storage, master_playlist_uri: uri}
      ) do
    case Storage.get(storage, uri) do
      {:ok, data} ->
        playlist = Playlist.unmarshal(data, %Master{uri: uri})
        {[{:notify_parent, {:hls_master_playlist, playlist}}], state}

      {:error, reason} ->
        Membrane.Logger.warning("Master playlist check failed: #{inspect(reason)}")

        Membrane.Logger.warning(
          "Master playlist check attempt scheduled in #{@master_check_retry_interval_ms}ms"
        )

        Process.send_after(self(), :check_master_playlist, @master_check_retry_interval_ms)
        {[], state}
    end
  end

  def handle_info({:segment, ref, segment}, _ctx, state) do
    Membrane.Logger.debug("HLS segment received on #{inspect(ref)}: #{to_string(segment.uri)}")
    pad = Map.fetch!(state.ref_to_pad, ref)

    # We're not downloading the segment, we're only putting it into the pending
    # queue. Download will be triggered when the segment is demanded. This allows
    # to download a VOD playlist in a controlled fashion.
    state =
      update_in(state, [:pad_to_tracker, pad, :pending], fn q ->
        :queue.in(segment, q)
      end)

    {[{:redemand, pad}], state}
  end

  def handle_info({task_ref, {:segment, {:data, binary}}}, _ctx, state) do
    # The task succeed so we can cancel the monitoring and discard the DOWN message
    Process.demonitor(task_ref, [:flush])
    pad = find_pad_by_download_ref(task_ref, state)
    tracker = get_in(state, [:pad_to_tracker, pad])
    action = {:buffer, {pad, %Buffer{payload: binary, metadata: tracker.download.segment}}}

    state =
      state
      |> update_in([:pad_to_tracker, pad, :ready], fn q -> :queue.in(action, q) end)
      |> put_in([:pad_to_tracker, pad, :download], nil)

    {[{:redemand, pad}], state}
  end

  def handle_info({:DOWN, task_ref, _, _, reason}, _ctx, state) do
    # This could either be a download message or a tracker.
    cond do
      Map.has_key?(state.monitor_to_pad, task_ref) ->
        pad = get_in(state, [:monitor_to_pad, task_ref])

        raise RuntimeError,
              "Tracker for pad #{inspect(pad)} exited with reason: #{inspect(reason)}"

      true ->
        # In this case, is is a download task.
        pad = find_pad_by_download_ref(task_ref, state)

        Membrane.Logger.warning(
          "HLS could not get next segment for pad #{inspect(pad)}: #{inspect(reason)}"
        )

        state = put_in(state, [:pad_to_tracker, pad, :download], nil)
        {[{:redemand, pad}], state}
    end
  end

  def handle_info({:start_of_track, _ref, _next_sequence}, _ctx, state) do
    {[], state}
  end

  def handle_info({:end_of_track, ref}, _ctx, state) do
    # Note that the tracker process is going to exit at this point.
    Membrane.Logger.debug("HLS end_of_track received on #{inspect(ref)}")

    pad = Map.fetch!(state.ref_to_pad, ref)
    monitor_ref = get_in(state, [:pad_to_tracker, pad, :monitor_ref])
    # Avoid receiving the exit message, even though we should not receive
    # it anyway in case it goes down with :normal reason.
    Process.demonitor(monitor_ref, [:flush])

    state = put_in(state, [:pad_to_tracker, pad, :closed], true)
    {[{:redemand, pad}], state}
  end

  defp find_pad_by_download_ref(task_ref, state) do
    {pad, _tracker} =
      Enum.find(
        state.pad_to_tracker,
        {nil, nil},
        fn {_pad, tracker} ->
          tracker.download != nil and tracker.download.task_ref == task_ref
        end
      )

    pad
  end

  defp schedule_download!(%{download: nil, media_uri: media_uri} = tracker, storage) do
    {{:value, segment}, queue} = :queue.out(tracker.pending)

    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        uri = Playlist.build_absolute_uri(media_uri, segment.uri)
        Membrane.Logger.debug("Getting segment: #{to_string(uri)}")

        case Storage.get(storage, uri) do
          {:ok, data} -> {:segment, {:data, data}}
          {:error, reason} -> raise RuntimeError, reason
        end
      end)

    %{tracker | pending: queue, download: %{task_ref: task.ref, segment: segment}}
  end

  defp extract_uri(%HLS.AlternativeRendition{uri: uri}), do: uri
  defp extract_uri(%HLS.VariantStream{uri: uri}), do: uri

  defp build_stream_format(%HLS.VariantStream{codecs: codecs}), do: %Format.MPEG{codecs: codecs}

  defp build_stream_format(%HLS.AlternativeRendition{type: :subtitles, language: lang}),
    do: %Format.WebVTT{language: lang}

  defp build_stream_format(%HLS.AlternativeRendition{type: :audio}), do: %Format.PackedAudio{}

  defp build_stream_format(rendition),
    do: raise(ArgumentError, "Unable to provide a proper cap for rendition #{inspect(rendition)}")
end
