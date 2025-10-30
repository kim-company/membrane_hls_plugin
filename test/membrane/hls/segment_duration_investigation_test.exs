defmodule Membrane.HLS.SegmentDurationInvestigationTest do
  @moduledoc """
  Investigation test for the 50-second target duration issue.

  This test explores why segments scale with target duration and require
  unrealistically large targets (50s) to pass compliance tests.

  Expected behavior: With h264_2s_keyframes.ts (keyframes every 2s),
  a target_duration of 2s should produce ~2s segments.

  Actual behavior (to be determined): Segments may be scaling proportionally
  with target duration, causing violations.
  """

  use ExUnit.Case, async: true
  use Membrane.Pipeline

  import Membrane.Testing.Assertions
  import Membrane.HLS.RFC8216Helper
  import ExUnit.CaptureLog

  @h264_2s_keyframes "test/fixtures/h264_2s_keyframes.ts"

  # Helper to build a diagnostic pipeline
  defp build_diagnostic_pipeline(tmp_dir, fixture, target_duration_seconds) do
    target_duration = Membrane.Time.seconds(target_duration_seconds)
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: target_duration
      }),
      child(:source, %Membrane.File.Source{location: fixture})
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
              name: "Audio",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: "1",
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
        generate_best_effort_timestamps: %{framerate: {30, 1}},
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
              bandwidth: 1_000_000,
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

  describe "Segment Duration Investigation" do
    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 2s with 2s keyframes", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing target_duration: 2s with h264_2s_keyframes.ts ===")

      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_diagnostic_pipeline(tmp_dir, @h264_2s_keyframes, 2)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      # Analyze results
      analyze_results(tmp_dir, 2, logs)
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 4s with 2s keyframes", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing target_duration: 4s with h264_2s_keyframes.ts ===")

      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_diagnostic_pipeline(tmp_dir, @h264_2s_keyframes, 4)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      analyze_results(tmp_dir, 4, logs)
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 6s with 2s keyframes", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing target_duration: 6s with h264_2s_keyframes.ts ===")

      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_diagnostic_pipeline(tmp_dir, @h264_2s_keyframes, 6)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      analyze_results(tmp_dir, 6, logs)
    end
  end

  defp analyze_results(tmp_dir, target_seconds, logs) do
    video_playlist_path = Path.join(tmp_dir, "stream_video.m3u8")

    case File.read(video_playlist_path) do
      {:ok, content} ->
        durations = extract_segment_durations(content)
        target = extract_target_duration(content)

        max_duration = Enum.max(durations, fn -> 0.0 end)
        min_duration = Enum.min(durations, fn -> 0.0 end)
        avg_duration = Enum.sum(durations) / length(durations)

        IO.puts("\nRESULTS:")
        IO.puts("  Requested target_duration: #{target_seconds}s")
        IO.puts("  EXT-X-TARGETDURATION:      #{target}s")
        IO.puts("  Number of segments:        #{length(durations)}")
        IO.puts("  Min segment duration:      #{Float.round(min_duration, 3)}s")
        IO.puts("  Max segment duration:      #{Float.round(max_duration, 3)}s")
        IO.puts("  Avg segment duration:      #{Float.round(avg_duration, 3)}s")
        IO.puts("  Expected segment duration: ~2.0s (based on keyframe interval)")

        # Check for violations
        violations = Enum.filter(durations, fn d -> d > target end)
        if length(violations) > 0 do
          IO.puts("  ⚠️  VIOLATIONS: #{length(violations)} segments exceed target")
          IO.puts("  Violating durations: #{inspect(Enum.map(violations, &Float.round(&1, 3)))}")
        else
          IO.puts("  ✅ NO VIOLATIONS: All segments within target")
        end

        # Check for RFC violations in logs
        if logs =~ "[HLS RFC8216 Violation]" do
          IO.puts("  ⚠️  RFC violations logged")
        else
          IO.puts("  ✅ No RFC violations logged")
        end

        IO.puts("")

      {:error, reason} ->
        IO.puts("ERROR: Could not read playlist: #{inspect(reason)}")
    end
  end
end
