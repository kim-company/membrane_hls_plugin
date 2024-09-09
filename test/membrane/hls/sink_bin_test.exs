defmodule Membrane.HLS.SinkBinTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  test "basic pipeline" do
    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        base_manifest_uri: "s3://bucket/stream",
        segment_duration: Membrane.Time.seconds(4),
        outputs: :manifests_and_segments,
        storage: Membrane.HLS.Storage.File.new()
      }),
      # Audio
      child(:aac_source, %Membrane.File.Source{
        location: "test/fixtures/samples_big-buck-bunny_bun33s.aac"
      })
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, :a), options: [encoding: :AAC, track_name: "audio_128k"])
      |> get_child(:sink),
      # Video
      child(:h264_source, %Membrane.File.Source{
        location: "test/fixtures/samples_big-buck-bunny_bun33s_720x480.h264"
      })
      |> child(:h264_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {25, 1}},
        output_stream_structure: :avc1
      })
      |> via_in(Pad.ref(:input, :v),
        options: [encoding: :H264, track_name: "audio_720x480"]
      )
      |> get_child(:sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_end_of_stream(pipeline, :aac_parser, :input, 5_000)
    # todo: how are we sure that all the files have been written?
    Process.sleep(1000)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end
end
