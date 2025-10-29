defmodule Membrane.HLS.CMAFSink do
  use Membrane.Sink

  def_input_pad(
    :input,
    accepted_format: Membrane.CMAF.Track
  )

  def_options(
    parent: [
      spec: pid(),
      description: "PID of the parent SinkBin that manages the packager."
    ],
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

    # Send track registration to parent
    track_opts = [
      codecs: Membrane.HLS.serialize_codecs(format.codecs),
      stream: state.opts.build_stream.(format),
      segment_extension: ".m4s",
      target_segment_duration: target_segment_duration
    ]

    send(state.opts.parent, {:hls_add_track, track_id, track_opts})

    # Send init section to parent
    send(state.opts.parent, {:hls_init_section, track_id, format.header})

    {[], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    # Send segment to parent
    duration = Membrane.Time.as_seconds(buffer.metadata.duration) |> Ratio.to_float()
    send(state.opts.parent, {:hls_segment, state.opts.track_id, buffer.payload, duration})

    {[], state}
  end
end
