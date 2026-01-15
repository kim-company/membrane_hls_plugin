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

    add_track_opts = [
      codecs: codecs,
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
end
