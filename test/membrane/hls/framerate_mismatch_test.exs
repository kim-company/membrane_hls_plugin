defmodule Membrane.HLS.FramerateMismatchTest do
  @moduledoc """
  Test to prove that framerate mismatch causes segment duration issues.

  The original avsync.ts is 30fps but the test configures the parser with 25fps.
  This causes a 30/25 = 1.2x timing error, explaining why:
  - Target 2s → 2.4s segments (2.0 * 1.2 = 2.4)
  - Target 7s → 7.2s segments (6.0 * 1.2 = 7.2)
  """

  use ExUnit.Case, async: true
  use Membrane.Pipeline

  import Membrane.Testing.Assertions
  import Membrane.HLS.RFC8216Helper
  import ExUnit.CaptureLog

  @avsync "test/fixtures/avsync.ts"

  defp build_pipeline(tmp_dir, target_seconds, framerate) do
    target_duration = Membrane.Time.seconds(target_seconds)
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
      |> via_in(Pad.ref(:input, "audio"),
        options: [
          encoding: :AAC,
          container: :CMAF,
          segment_duration: target_duration,
          build_stream: fn _format ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Audio",
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

      # Video path with CONFIGURABLE framerate
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: framerate},
        output_stream_structure: :avc1
      })
      |> via_in(Pad.ref(:input, "video"),
        options: [
          encoding: :H264,
          container: :CMAF,
          segment_duration: target_duration,
          build_stream: fn _format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 1_500_000,
              resolution: {1280, 720},
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

  describe "Framerate Mismatch Hypothesis" do
    @tag :tmp_dir
    @tag timeout: 30_000
    test "avsync.ts with WRONG framerate (25fps) causes overshoot", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing avsync.ts @ 25fps (WRONG) with target 2s ===")

      logs = capture_log(fn ->
        {spec, _} = build_pipeline(tmp_dir, 2, {25, 1})
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video.m3u8"))
      durations = extract_segment_durations(content)
      max = Enum.max(durations, fn -> 0.0 end)

      IO.puts("Max segment: #{Float.round(max, 3)}s")
      IO.puts("Expected:    ~2.4s (due to 30/25 = 1.2x timing error)")
      IO.puts("Has violations: #{logs =~ "[HLS RFC8216 Violation]"}")
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "avsync.ts with CORRECT framerate (30fps) works perfectly", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing avsync.ts @ 30fps (CORRECT) with target 2s ===")

      logs = capture_log(fn ->
        {spec, _} = build_pipeline(tmp_dir, 2, {30, 1})
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video.m3u8"))
      durations = extract_segment_durations(content)
      max = Enum.max(durations, fn -> 0.0 end)

      IO.puts("Max segment: #{Float.round(max, 3)}s")
      IO.puts("Expected:    ~2.0s (correct timing)")
      IO.puts("Has violations: #{logs =~ "[HLS RFC8216 Violation]"}")
    end
  end
end
