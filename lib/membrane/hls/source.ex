defmodule Membrane.HLS.Source do
  use Membrane.Source

  alias Membrane.Buffer
  alias Membrane.HLS.Format
  require Membrane.Logger

  def_output_pad(:output, [
    mode: :push,
    caps: [Format.PackedAudio, Format.WebVTT, Format.MPEG],
  ])

  def_options([
    storage: [spec: HLS.Storage.t(), description: "HLS.Storage instance pointing to the target HLS playlist"],
    rendition: [spec: HLS.AlternativeRendition.t() | HLS.VariantStream.t(), description: "Stream to be followed"],
  ])

  @impl true
  def handle_init(options) do
    {:ok, %{storage: options.storage, rendition: options.rendition}}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    caps = build_caps(state.rendition)
    {{:ok, [caps: {:output, caps}]}, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {:ok, pid} = HLS.Tracker.start_link(state.storage)
    target = build_target(state.rendition)
    ref = HLS.Tracker.follow(pid, target)

    tracking_config = [tracking: ref, tracker: pid]
    state = Enum.reduce(tracking_config, state, fn {key, val}, state ->
      Map.put(state, key, val)
    end)

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    HLS.Tracker.stop(state.tracking)
    state = Enum.reduce([:tracking, :tracker], state, fn key, state ->
      Map.delete(state, key)
    end)
    {:ok, state}
  end

  @impl true
  def handle_other({:segment, ref, segment}, _ctx, state) do
    audit_tracking_reference(ref, state.tracking)

    data = HLS.Storage.get_segment!(state.storage, segment.uri)
    buffer = %Buffer{payload: data, metadata: segment}
    action = {:buffer, {:output, buffer}}
    {{:ok, [action]}, state}
  end

  def handle_other({:end_of_track, ref}, _ctx, state) do
    audit_tracking_reference(ref, state.tracking)
    {{:ok, [{:end_of_stream, :output}]}, state}
  end

  def handle_other({:start_of_track, ref, _}, _ctx, state) do
    audit_tracking_reference(ref, state.tracking)
    {:ok, state}
  end

  defp build_target(%HLS.AlternativeRendition{uri: uri}), do: uri
  defp build_target(%HLS.VariantStream{uri: uri}), do: uri

  defp audit_tracking_reference(have, want) when have != want, do:
    raise ArgumentError, "While following tracking #{inspect want} a message with reference #{inspect have} was received"
  defp audit_tracking_reference(_have, _want), do: :ok

  defp build_caps(%HLS.VariantStream{codecs: codecs}), do: %Format.MPEG{codecs: codecs}
  defp build_caps(%HLS.AlternativeRendition{type: :subtitles, language: lang}), do: %Format.WebVTT{language: lang}
  defp build_caps(%HLS.AlternativeRendition{type: :audio}), do: %Format.PackedAudio{}
  defp build_caps(rendition), do:
    raise ArgumentError, "Unable to provide a proper cap for rendition #{inspect rendition}"
end
