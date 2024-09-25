defmodule Membrane.HLS.CMAFSink do
  use Membrane.Sink
  alias HLS.Packager

  def_input_pad(
    :input,
    accepted_format: Membrane.CMAF.Track
  )

  def_options(
    packager_pid: [
      spec: pid(),
      description: """
      PID of the packager.
      """
    ],
    build_stream: [
      spec: (Membrane.CMAF.Track.t() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
      description: "Build the stream with the given stream format"
    ],
    segment_duration: [
      spec: Membrane.Time.t()
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts, stream_id: nil}}
  end

  def handle_stream_format(:input, format, _ctx, state) do
    stream = state.opts.build_stream.(format)

    target_duration =
      Membrane.Time.as_seconds(state.opts.segment_duration, :exact)
      |> Ratio.ceil()

    stream_id =
      Agent.get_and_update(state.opts.packager_pid, fn packager ->
        {packager, stream_id} =
          Packager.put_stream(packager,
            stream: stream,
            segment_extension: ".m4s",
            target_segment_duration: target_duration
          )

        packager = Packager.put_init_section(packager, stream_id, format.header)

        {stream_id, packager}
      end)

    {[], %{state | stream_id: stream_id}}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    Agent.update(state.opts.packager_pid, fn packager ->
      Packager.put_segment(
        packager,
        state.stream_id,
        buffer.payload,
        Membrane.Time.as_seconds(buffer.metadata.duration) |> Ratio.to_float()
      )
    end)

    {[], state}
  end
end
