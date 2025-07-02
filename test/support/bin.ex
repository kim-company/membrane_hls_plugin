defmodule Support.Bin do
  use Membrane.Bin

  def_input_pad(:input,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:video,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:audio,
    accepted_format: Membrane.RemoteStream
  )

  @impl true
  def handle_init(_ctx, _opts) do
    spec = [
      bin_input(:input)
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer),
      child({:audio, :funnel}, Membrane.Funnel)
      |> bin_output(:audio),
      child({:video, :funnel}, Membrane.Funnel)
      |> bin_output(:video)
    ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification({:mpeg_ts_pmt, pmt}, _element, _context, state) do
    audio_stream =
      Enum.find_value(pmt.streams, fn {sid, x} ->
        if x.stream_type == :AAC, do: sid
      end)

    video_stream =
      Enum.find_value(pmt.streams, fn {sid, x} ->
        if x.stream_type == :H264, do: sid
      end)

    spec = [
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, {:stream_id, audio_stream}))
      |> get_child({:audio, :funnel}),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, {:stream_id, video_stream}))
      |> get_child({:video, :funnel})
    ]

    {[spec: spec], state}
  end
end
