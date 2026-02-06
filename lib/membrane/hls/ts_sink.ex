defmodule Membrane.HLS.TSSink do
  use Membrane.Sink

  def_input_pad(:input,
    accepted_format: Membrane.RemoteStream
  )

  def_options(
    track_id: [
      spec: String.t(),
      description: "ID of the track."
    ],
    build_stream: [
      spec: (map() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
      description: "Build the stream with the given stream format"
    ],
    target_segment_duration: [
      spec: Membrane.Time.t()
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    track_id = state.opts.track_id

    target_segment_duration =
      Membrane.Time.as_seconds(state.opts.target_segment_duration, :exact)
      |> Ratio.ceil()

    {stream, legacy_codecs} =
      case state.opts.build_stream.(format) do
        {aac_format, stream} ->
          info = %{
            mp4a: %{
              aot_id: Membrane.AAC.profile_to_aot_id(aac_format.profile),
              channels: Membrane.AAC.channels_to_channel_config_id(aac_format.channels),
              frequency: aac_format.sample_rate
            }
          }

          {stream, Membrane.HLS.serialize_codecs(info)}

        stream ->
          {stream, List.wrap(Map.get(stream, :codecs))}
      end

    Membrane.HLS.maybe_warn_deprecated_stream_fields(track_id, stream)

    {derived_codecs, derived_complete?} = derive_codecs_from_ts_format(format)

    {codecs, codecs_complete?} =
      cond do
        derived_complete? -> {derived_codecs, true}
        derived_codecs == [] and legacy_codecs != [] -> {legacy_codecs, true}
        true -> {derived_codecs, false}
      end

    add_track_opts = [
      codecs: codecs,
      codecs_complete?: codecs_complete?,
      stream: stream,
      segment_extension: ".ts",
      target_segment_duration: target_segment_duration
    ]

    {[notify_parent: {:packager_add_track, track_id, add_track_opts}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    duration =
      buffer.metadata.duration
      |> Membrane.Time.as_seconds()
      |> Ratio.to_float()

    actions = [
      notify_parent:
        {:packager_put_segment, state.opts.track_id, buffer.payload, duration, buffer.pts,
         Map.get(buffer, :dts)}
    ]

    {actions, state}
  end

  defp derive_codecs_from_ts_format(%Membrane.RemoteStream{content_format: content_format})
       when is_struct(content_format, Membrane.MPEG.TS.StreamFormat) do
    streams = Map.get(content_format, :elementary_streams, [])

    if streams == [] do
      {[], false}
    else
      codecs =
        streams
        |> Enum.flat_map(fn stream ->
          stream
          |> Map.get(:upstream_format)
          |> serialize_upstream_codec()
        end)
        |> Enum.uniq()

      complete? =
        Enum.all?(streams, fn stream ->
          stream
          |> Map.get(:upstream_format)
          |> codec_known?()
        end)

      {codecs, complete?}
    end
  end

  defp derive_codecs_from_ts_format(_format), do: {[], false}

  defp codec_known?(%Membrane.AAC{}), do: true
  defp codec_known?(_other), do: false

  defp serialize_upstream_codec(%Membrane.AAC{} = format) do
    info = %{
      mp4a: %{
        aot_id: Membrane.AAC.profile_to_aot_id(format.profile),
        channels: Membrane.AAC.channels_to_channel_config_id(format.channels),
        frequency: format.sample_rate
      }
    }

    Membrane.HLS.serialize_codecs(info)
  end

  defp serialize_upstream_codec(_format), do: []
end
