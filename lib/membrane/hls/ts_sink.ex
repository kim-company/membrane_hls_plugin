defmodule Membrane.HLS.TSSink do
  use Membrane.Sink

  def_input_pad(:input,
    accepted_format: Membrane.RemoteStream
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

    {codecs, stream} =
      case state.opts.build_stream.(format) do
        {format, stream} ->
          info = %{
            mp4a: %{
              aot_id: Membrane.AAC.profile_to_aot_id(format.profile),
              channels: Membrane.AAC.channels_to_channel_config_id(format.channels),
              frequency: format.sample_rate
            }
          }

          codecs = Membrane.HLS.serialize_codecs(info)
          {codecs, stream}

        stream ->
          {Map.get(stream, Access.key!(:codecs), []), stream}
      end

    # Send track registration to parent
    track_opts = [
      codecs: codecs,
      stream: stream,
      segment_extension: ".ts",
      target_segment_duration: target_segment_duration
    ]

    send(state.opts.parent, {:hls_add_track, track_id, track_opts})

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # Send segment to parent
    duration = Membrane.Time.as_seconds(buffer.metadata.duration) |> Ratio.to_float()
    send(state.opts.parent, {:hls_segment, state.opts.track_id, buffer.payload, duration})

    {[], state}
  end
end
