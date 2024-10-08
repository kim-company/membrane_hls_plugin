defmodule Membrane.HLS.WebVTTSink do
  use Membrane.Sink
  alias HLS.Packager

  def_input_pad(
    :input,
    accepted_format: Membrane.Text
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
      spec: (Membrane.CMAF.Track.t() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
      description: "Build the stream with the given stream format"
    ],
    target_segment_duration: [
      spec: Membrane.Time.t()
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts, upload_tasks: %{}}}
  end

  def handle_stream_format(:input, format, _ctx, state) do
    track_id = state.opts.track_id

    target_segment_duration =
      Membrane.Time.as_seconds(state.opts.target_segment_duration, :exact)
      |> Ratio.ceil()

    if Packager.has_track?(state.opts.packager, track_id) do
      # TODO: Render this configurable
      # Packager.discontinue_track(packager, track_id)
    else
      Packager.add_track(
        state.opts.packager,
        track_id,
        stream: state.opts.build_stream.(format),
        segment_extension: ".vtt",
        target_segment_duration: target_segment_duration
      )
    end

    {[], state}
  end

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
