defmodule Membrane.HLS.OriginalFixtureTest do
  @moduledoc """
  Test the original avsync.ts fixture to understand why it requires 50s target.
  """

  use ExUnit.Case, async: false
  use Membrane.Pipeline

  import Membrane.Testing.Assertions
  import Membrane.HLS.RFC8216Helper
  import ExUnit.CaptureLog

  @avsync "test/fixtures/avsync.ts"

  defp build_pipeline(tmp_dir, target_duration_seconds) do
    target_duration = Membrane.Time.seconds(target_duration_seconds)
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: target_duration
      }),
      child(:source, %Membrane.File.Source{location: @avsync})
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer),

      # Audio path
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :audio])
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          container: :CMAF,
          segment_duration: target_duration,
          build_stream: fn _format ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Audio (EN)",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: "2",
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink),

      # Video path
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {25, 1}},
        output_stream_structure: :avc1
      })
      |> via_in(Pad.ref(:input, "video_460x720"),
        options: [
          encoding: :H264,
          container: :CMAF,
          segment_duration: target_duration,
          build_stream: fn _format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 1_500_000,
              resolution: {460, 720},
              codecs: [],
              audio: "audio"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]

    {spec, manifest_uri}
  end

  describe "Original avsync.ts fixture" do
    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 2s with wrong framerate causes oversized segments", %{tmp_dir: tmp_dir} do
      # This test demonstrates the original issue: avsync.ts is 30fps but when
      # the H264 parser is configured with 25fps (as in the original tests),
      # segments become ~2.4s instead of 2.0s due to the 30/25 = 1.2x timing error
      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_pipeline(tmp_dir, 2)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      durations = extract_segment_durations(content)

      # With the wrong framerate (25fps for 30fps video), segments should exceed target
      assert Enum.all?(durations, &(&1 > 2.0)),
             "Expected segments to exceed 2.0s due to framerate mismatch, got: #{inspect(durations)}"

      # Should log RFC violations
      assert logs =~ "[HLS RFC8216 Violation]",
             "Expected RFC violations to be logged"
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 7s with wrong framerate causes oversized segments", %{tmp_dir: tmp_dir} do
      # With 7s target and 25fps config on 30fps video, segments become ~7.2s
      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_pipeline(tmp_dir, 7)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      durations = extract_segment_durations(content)

      # Segments should exceed 7.0s due to framerate mismatch
      assert Enum.all?(durations, &(&1 > 7.0)),
             "Expected segments to exceed 7.0s due to framerate mismatch, got: #{inspect(durations)}"

      assert logs =~ "[HLS RFC8216 Violation]"
    end
  end
end
