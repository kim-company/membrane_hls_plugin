defmodule Membrane.HLS.Source do
  use Membrane.Source

  alias HLS.Storage
  alias HLS.Playlist.Media.Tracker
  alias Membrane.Buffer
  alias Membrane.HLS.Format

  @master_check_retry_interval_ms 1_000
  require Membrane.Logger

  def_output_pad(:output,
    mode: :pull,
    availability: :on_request,
    caps: [Format.PackedAudio, Format.WebVTT, Format.MPEG]
  )

  def_options(
    storage: [
      spec: HLS.Storage.t(),
      description: "HLS.Storage instance pointing to the target HLS playlist"
    ]
  )

  @impl true
  def handle_init(options) do
    {:ok, %{storage: options.storage, pad_to_tracker: %{}, ref_to_pad: %{}}}
  end

  @impl true
  def handle_pad_added(pad = {Membrane.Pad, :output, {:rendition, rendition}}, _, state) do
    {:ok, pid} = Tracker.start_link(state.storage)
    target = build_target(rendition)
    ref = Tracker.follow(pid, target)
    config = %{tracking: ref, tracker: pid, queue: Q.new("hls"), closed: false}

    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, config)}
    state = %{state | ref_to_pad: Map.put(state.ref_to_pad, ref, pad)}

    caps = build_caps(rendition)

    {{:ok, [caps: {pad, caps}]}, state}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    send(self(), :check_master_playlist)
    {:ok, state}
  end

  def handle_demand(pad, size, :buffers, _ctx, state) do
    tracker = Map.fetch!(state.pad_to_tracker, pad)

    size =
      if tracker.closed do
        tracker.queue.count
      else
        size
      end

    {actions, queue} = Q.take(tracker.queue, size)

    actions =
      if tracker.closed do
        actions ++ [{:end_of_stream, pad}]
      else
        actions
      end

    tracker = %{tracker | queue: queue}
    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other(:check_master_playlist, _ctx, state = %{storage: store}) do
    case Storage.get_master_playlist(store) do
      {:ok, playlist} ->
        {{:ok, [notify: {:hls_master_playlist, playlist}]}, state}

      {:error, reason} ->
        Membrane.Logger.debug("Master playlist check failed: #{inspect(reason)}")

        Membrane.Logger.debug(
          "Master playlist check attempt scheduled in #{@master_check_retry_interval_ms}ms"
        )

        Process.send_after(self(), :check_master_playlist, @master_check_retry_interval_ms)
        {:ok, state}
    end
  end

  def handle_other({:segment, ref, segment}, _ctx, state) do
    Membrane.Logger.debug("HLS segment received on #{inspect(ref)}: #{inspect(segment)}")

    pad = Map.fetch!(state.ref_to_pad, ref)
    tracker = Map.fetch!(state.pad_to_tracker, pad)

    data = HLS.Storage.get_segment!(state.storage, segment.uri)
    action = {:buffer, {pad, %Buffer{payload: data, metadata: segment}}}

    queue = Q.push(tracker.queue, action)
    tracker = %{tracker | queue: queue}
    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}

    {{:ok, [{:redemand, pad}]}, state}
  end

  def handle_other({:start_of_track, _ref, _next_sequence}, _ctx, state) do
    {:ok, state}
  end

  def handle_other({:end_of_track, ref}, _ctx, state) do
    Membrane.Logger.debug("HLS end_of_track received on #{inspect(ref)}")

    pad = Map.fetch!(state.ref_to_pad, ref)
    tracker = Map.fetch!(state.pad_to_tracker, pad)
    Tracker.stop(tracker.tracker)
    tracker = %{tracker | closed: true}

    state = %{state | pad_to_tracker: Map.put(state.pad_to_tracker, pad, tracker)}

    {{:ok, [{:redemand, pad}]}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    Enum.each(state.pad_to_tracker, fn {_, %{tracker: pid, closed: closed}} ->
      unless closed, do: Tracker.stop(pid)
    end)

    {:ok, %{state | pad_to_tracker: %{}, ref_to_pad: %{}}}
  end

  defp build_target(%HLS.AlternativeRendition{uri: uri}), do: uri
  defp build_target(%HLS.VariantStream{uri: uri}), do: uri

  defp build_caps(%HLS.VariantStream{codecs: codecs}), do: %Format.MPEG{codecs: codecs}

  defp build_caps(%HLS.AlternativeRendition{type: :subtitles, language: lang}),
    do: %Format.WebVTT{language: lang}

  defp build_caps(%HLS.AlternativeRendition{type: :audio}), do: %Format.PackedAudio{}

  defp build_caps(rendition),
    do: raise(ArgumentError, "Unable to provide a proper cap for rendition #{inspect(rendition)}")
end
