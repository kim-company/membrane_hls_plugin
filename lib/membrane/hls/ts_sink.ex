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

  defp codec_known?(%Membrane.H264{stream_structure: {avc, _dcr}})
       when avc in [:avc1, :avc3],
       do: true

  defp codec_known?(%Membrane.H264{profile: profile, width: w, height: h})
       when not is_nil(profile) and is_integer(w) and is_integer(h),
       do: true

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

  defp serialize_upstream_codec(
         %Membrane.H264{stream_structure: {avc, <<1, profile, compat, level, _rest::binary>>}}
       )
       when avc in [:avc1, :avc3] do
    Membrane.HLS.serialize_codecs([
      {:avc1, %{profile: profile, compatibility: compat, level: level}}
    ])
  end

  defp serialize_upstream_codec(
         %Membrane.H264{profile: profile, width: w, height: h} = format
       )
       when not is_nil(profile) and is_integer(w) and is_integer(h) do
    profile_idc = h264_profile_idc(profile)
    fps = h264_framerate(format.framerate)
    level_idc = h264_min_level_idc(w, h, fps)

    if profile_idc != nil and level_idc != nil do
      compat = h264_compatibility(profile, format)

      Membrane.HLS.serialize_codecs([
        {:avc1, %{profile: profile_idc, compatibility: compat, level: level_idc}}
      ])
    else
      []
    end
  end

  defp serialize_upstream_codec(_format), do: []

  # Maps H264 profile atoms to profile_idc values (ITU-T H.264 Table A-1).
  defp h264_profile_idc(:constrained_baseline), do: 66
  defp h264_profile_idc(:baseline), do: 66
  defp h264_profile_idc(:main), do: 77
  defp h264_profile_idc(:high), do: 100
  defp h264_profile_idc(:high_10), do: 110
  defp h264_profile_idc(:high_10_intra), do: 110
  defp h264_profile_idc(:high_422), do: 122
  defp h264_profile_idc(:high_422_intra), do: 122
  defp h264_profile_idc(:high_444), do: 244
  defp h264_profile_idc(:high_444_intra), do: 244
  defp h264_profile_idc(_), do: nil

  # Derives constraint_set flags from profile where deterministic.
  # Constrained Baseline requires constraint_set1_flag (bit 6).
  defp h264_compatibility(:constrained_baseline, _format), do: 0xC0
  defp h264_compatibility(_profile, _format), do: 0x00

  defp h264_framerate({num, den}) when den > 0, do: num / den
  defp h264_framerate(_nil_or_invalid), do: 30.0

  # H264 level limits table (ITU-T H.264 Table A-1).
  # Each entry: {level_idc, max_frame_size_macroblocks, max_macroblocks_per_second}
  @h264_levels [
    {10, 99, 1_485},
    {11, 396, 3_000},
    {12, 396, 6_000},
    {13, 396, 11_880},
    {20, 396, 11_880},
    {21, 792, 19_800},
    {22, 1_620, 20_250},
    {30, 1_620, 40_500},
    {31, 3_600, 108_000},
    {32, 5_120, 216_000},
    {40, 8_192, 245_760},
    {41, 8_192, 245_760},
    {42, 8_704, 522_240},
    {50, 22_080, 589_824},
    {51, 36_864, 983_040},
    {52, 36_864, 2_073_600}
  ]

  # Derives the minimum H264 level_idc from resolution and framerate.
  defp h264_min_level_idc(width, height, fps) do
    fs = ceil(width / 16) * ceil(height / 16)
    mbps = ceil(fs * fps)

    Enum.find_value(@h264_levels, fn {level_idc, max_fs, max_mbps} ->
      if fs <= max_fs and mbps <= max_mbps, do: level_idc
    end)
  end
end
