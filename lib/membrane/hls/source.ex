defmodule Membrane.HLS.Source do
  use Membrane.Source

  alias HLS.Storage
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
    {:ok, %{storage: options.storage}}
  end

  # @impl true
  # def handle_pad_added(pad, _, state) do
  #   # TODO: send caps, see build_caps
  # caps = build_caps(state.rendition)
  # {{:ok, [caps: {:output, caps}]}, state}
  #   {:ok, state}
  # end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    send(self(), :check_master_playlist)
    {:ok, state}
  end

  # @impl true
  # def handle_prepared_to_playing(_ctx, state) do
  # end
  #
  # @impl true
  # def handle_prepared_to_playing(_ctx, state) do
  #   {:ok, pid} = HLS.Tracker.start_link(state.storage)
  #   target = build_target(state.rendition)
  #   ref = HLS.Tracker.follow(pid, target)
  #
  #   config = [tracking: ref, tracker: pid, queue: Qex.new(), queued: 0, closed: false]
  #
  #   state =
  #     Enum.reduce(config, state, fn {key, val}, state ->
  #       Map.put(state, key, val)
  #     end)
  #
  #   {:ok, state}
  # end

  #
  # @impl true
  # def handle_prepared_to_stopped(_ctx, state) do
  #   HLS.Tracker.stop(state.tracking)
  #
  #   state =
  #     Enum.reduce([:tracking, :tracker, :queue, :queued, :closed], state, fn key, state ->
  #       Map.delete(state, key)
  #     end)
  #
  #   {:ok, state}
  # end

  def handle_demand(:output, _size, :buffers, _ctx, state = %{queued: 0}) do
    # Put the output pad on hold. As soon as the first packet is received,
    # notify it to redemand.
    {:ok, state}
  end

  def handle_demand(:output, _size, :buffers, _ctx, state) do
    {segment, queue} = Qex.pop!(state.queue)
    queued = state.queued - 1
    state = %{state | queue: queue, queued: queued}

    data = HLS.Storage.get_segment!(state.storage, segment.uri)
    buffer = %Buffer{payload: data, metadata: segment}
    action = {:buffer, {:output, buffer}}

    actions =
      cond do
        queued > 0 -> [action, {:redemand, :output}]
        state.closed -> [action, {:end_of_stream, :output}]
        true -> [action]
      end

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

        Process.send_after(self(), :check_master_plalist, @master_check_retry_interval_ms)
        {:ok, state}
    end
  end

  def handle_other({:segment, ref, segment}, _ctx, state) do
    audit_tracking_reference(ref, state.tracking)

    queue = Qex.push(state.queue, segment)
    queued = state.queued + 1
    state = %{state | queue: queue, queued: queued}

    if state.queued == 1 do
      # It means that the previous demand request was put on hold. Tell our
      # output pad that we're ready to provide one more chunk.
      {{:ok, [{:redemand, :output}]}, state}
    else
      {:ok, state}
    end
  end

  def handle_other({:start_of_track, ref, _next_sequence}, _ctx, state) do
    audit_tracking_reference(ref, state.tracking)
    {:ok, state}
  end

  def handle_other({:end_of_track, ref}, _ctx, state) do
    audit_tracking_reference(ref, state.tracking)
    state = %{state | closed: true}

    if state.queued == 0 do
      # If the output pad was on hold it would not call re-demand and we won't
      # have a chance to notify it.
      {{:ok, [{:end_of_stream, :output}]}, state}
    else
      {:ok, state}
    end
  end

  defp build_target(%HLS.AlternativeRendition{uri: uri}), do: uri
  defp build_target(%HLS.VariantStream{uri: uri}), do: uri

  defp audit_tracking_reference(have, want) when have != want,
    do:
      raise(
        ArgumentError,
        "While following tracking #{inspect(want)} a message with reference #{inspect(have)} was received"
      )

  defp audit_tracking_reference(_have, _want), do: :ok

  defp build_caps(%HLS.VariantStream{codecs: codecs}), do: %Format.MPEG{codecs: codecs}

  defp build_caps(%HLS.AlternativeRendition{type: :subtitles, language: lang}),
    do: %Format.WebVTT{language: lang}

  defp build_caps(%HLS.AlternativeRendition{type: :audio}), do: %Format.PackedAudio{}

  defp build_caps(rendition),
    do: raise(ArgumentError, "Unable to provide a proper cap for rendition #{inspect(rendition)}")
end
