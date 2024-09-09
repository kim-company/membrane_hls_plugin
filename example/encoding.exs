Mix.install([
  {:membrane_core, "~> 1.0"},
  {:membrane_ffmpeg_swscale_plugin, "~> 0.16.1"},
  {:membrane_h264_ffmpeg_plugin, "~> 0.31.6"},
  {:membrane_file_plugin, "~> 0.17.2"},
  {:membrane_mp4_plugin, "~> 0.35.2"},
  {:membrane_h26x_plugin, "~> 0.10.2"},
  {:membrane_tee_plugin, "~> 0.12.0"},
  {:membrane_realtimer_plugin, "~> 0.9.0"}
])

defmodule EncoderTest do
  use Membrane.Pipeline

  @outputs [
    {3840, 2160},
    {1920, 1080},
    {1280, 720},
    {640, 360},
    {416, 234}
  ]

  @impl true
  def handle_init(_ctx, _opts) do
    Enum.each(@outputs, fn {_w, h} ->
      File.rm("output_#{h}.h264")
    end)

    spec = [
      child(:source, %Membrane.File.Source{chunk_size: 40_960, location: "lg-uhd-LG-Greece-and-Norway.mp4"})
      # child(:source, %Membrane.File.Source{location: "/Users/phil/Documents/Testdata/globe.mp4"})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM),
      # Video
      get_child(:demuxer)
      |> via_out(:output, options: [kind: :video])
      |> child(:parser_video, %Membrane.H264.Parser{output_stream_structure: :annexb})
      |> child(:decoder, Membrane.H264.FFmpeg.Decoder)
      |> child(:rt, Membrane.Realtimer)
      |> child(:tee, Membrane.Tee.Parallel),
      # Audio
      get_child(:demuxer)
      |> via_out(:output, options: [kind: :audio])
      |> child(:sink_audio, Membrane.Debug.Sink)
    ] ++ Enum.map(@outputs, fn {w, h} = res ->
      get_child(:tee)
      |> child({:converter,res}, %Membrane.FFmpeg.SWScale.Scaler{
        output_width: w,
        output_height: h,
      })
      |> child({:encoder, res}, %Membrane.H264.FFmpeg.Encoder{tune: :zerolatency, profile: :baseline, preset: :veryfast, crf: 29})
      |> child({:sink, res}, %Membrane.File.Sink{location: "output_#{h}.h264"})
    end)

    {[spec: spec], %{children_with_eos: MapSet.new()}}
  end

  @impl true
  def handle_element_end_of_stream(element, _pad, _ctx, state) do
    state = %{state | children_with_eos: MapSet.put(state.children_with_eos, element)}

    sinks = Enum.map(@outputs, &{:sink, &1})

    actions =
      if Enum.all?(sinks, &(&1 in state.children_with_eos)),
        do: [terminate: :shutdown],
        else: []

    {actions, state}
  end
end

{:ok, _supervisor, pipeline_pid} = Membrane.Pipeline.start_link(EncoderTest)
ref = Process.monitor(pipeline_pid)

# Wait for the pipeline to finish
:timer.tc(fn ->
  receive do
    {:DOWN, ^ref, :process, _pipeline_pid, _reason} ->
      :ok
  end
end)
|> IO.inspect()
