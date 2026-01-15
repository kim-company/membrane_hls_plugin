defmodule Membrane.HLS.CMAFSink do
  use Membrane.Sink

  def_input_pad(
    :input,
    accepted_format: Membrane.CMAF.Track
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
    {[], %{opts: opts, next_pts: nil}}
  end

  def handle_stream_format(:input, format, _ctx, state) do
    track_id = state.opts.track_id

    target_segment_duration =
      Membrane.Time.as_seconds(state.opts.target_segment_duration, :exact)
      |> Ratio.ceil()

    add_track_opts = [
      codecs: Membrane.HLS.serialize_codecs(format.codecs),
      stream: state.opts.build_stream.(format),
      segment_extension: ".m4s",
      target_segment_duration: target_segment_duration
    ]

    actions = [
      notify_parent: {:packager_add_track, track_id, add_track_opts},
      notify_parent: {:packager_put_init_section, track_id, format.header}
    ]

    {actions, state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    duration_ns = buffer.metadata.duration

    duration =
      duration_ns
      |> Membrane.Time.as_seconds()
      |> Ratio.to_float()

    pts = buffer.pts || state.next_pts || 0
    next_pts = pts + duration_ns

    actions = [
      notify_parent:
        {:packager_put_segment, state.opts.track_id, buffer.payload, duration, pts,
         Map.get(buffer, :dts)}
    ]

    {actions, %{state | next_pts: next_pts}}
  end
end
