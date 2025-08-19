defmodule Membrane.HLS.PackedAACSink do
  use Membrane.Sink
  alias HLS.Packager
  require Membrane.Logger

  def_input_pad(:input,
    accepted_format: Membrane.AAC
  )

  def_options(
    packager: [
      spec: pid(),
      description: "PID of the packager."
    ],
    track_id: [
      spec: String.t(),
      description: "ID of the track."
    ],
    build_stream: [
      spec: (Membrane.AAC.t() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
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

    stream = state.opts.build_stream.(format)

    info = %{
      mp4a: %{
        aot_id: Membrane.AAC.profile_to_aot_id(format.profile),
        channels: Membrane.AAC.channels_to_channel_config_id(format.channels),
        frequency: format.sample_rate
      }
    }

    codecs = Membrane.HLS.serialize_codecs(info)

    Packager.add_track(
      state.opts.packager,
      track_id,
      codecs: codecs,
      stream: stream,
      segment_extension: ".aac",
      target_segment_duration: target_segment_duration
    )

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    Packager.put_segment(
      state.opts.packager,
      state.opts.track_id,
      buffer.payload,
      Membrane.Time.as_seconds(buffer.metadata.duration) |> Ratio.to_float()
    )

    {[], state}
  end
end
