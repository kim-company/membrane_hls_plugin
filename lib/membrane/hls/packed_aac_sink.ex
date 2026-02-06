defmodule Membrane.HLS.PackedAACSink do
  use Membrane.Sink

  def_input_pad(:input,
    accepted_format: Membrane.AAC
  )

  def_options(
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
    Membrane.HLS.maybe_warn_deprecated_stream_fields(track_id, stream)

    info = %{
      mp4a: %{
        aot_id: Membrane.AAC.profile_to_aot_id(format.profile),
        channels: Membrane.AAC.channels_to_channel_config_id(format.channels),
        frequency: format.sample_rate
      }
    }

    codecs = Membrane.HLS.serialize_codecs(info)

    add_track_opts = [
      codecs: codecs,
      stream: stream,
      segment_extension: ".aac",
      target_segment_duration: target_segment_duration,
      codecs_complete?: true
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
        {:packager_put_segment, state.opts.track_id, buffer.payload, duration, buffer.pts, nil}
    ]

    {actions, state}
  end
end
