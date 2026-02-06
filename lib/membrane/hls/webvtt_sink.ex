defmodule Membrane.HLS.WebVTTSink do
  use Membrane.Sink

  def_input_pad(
    :input,
    accepted_format: Membrane.Text
  )

  def_options(
    track_id: [
      spec: String.t(),
      description: "ID of the track."
    ],
    build_stream: [
      spec: (Membrane.CMAF.Track.t() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
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

  def handle_stream_format(:input, format, _ctx, state) do
    track_id = state.opts.track_id

    target_segment_duration =
      Membrane.Time.as_seconds(state.opts.target_segment_duration, :exact)
      |> Ratio.ceil()

    stream = state.opts.build_stream.(format)
    Membrane.HLS.maybe_warn_deprecated_stream_fields(track_id, stream)

    add_track_opts = [
      stream: stream,
      segment_extension: ".vtt",
      target_segment_duration: target_segment_duration,
      codecs_complete?: false
    ]

    {[notify_parent: {:packager_add_track, track_id, add_track_opts}], state}
  end

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
