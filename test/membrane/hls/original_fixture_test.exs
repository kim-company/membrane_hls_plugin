defmodule Membrane.HLS.OriginalFixtureTest do
  @moduledoc """
  Test the original avsync.ts fixture to understand why it requires 50s target.
  """

  use ExUnit.Case, async: true
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
    test "target 2s", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing avsync.ts with target_duration: 2s ===")

      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_pipeline(tmp_dir, 2)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      analyze_results(tmp_dir, 2, logs)
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 7s", %{tmp_dir: tmp_dir} do
      IO.puts("\n=== Testing avsync.ts with target_duration: 7s ===")

      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_pipeline(tmp_dir, 7)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      analyze_results(tmp_dir, 7, logs)
    end
  end

  defp analyze_results(tmp_dir, target_seconds, logs) do
    video_playlist_path = Path.join(tmp_dir, "stream_video_460x720.m3u8")

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
        IO.puts("  All durations: #{inspect(Enum.map(durations, &Float.round(&1, 3)))}")

        violations = Enum.filter(durations, fn d -> d > target end)
        if length(violations) > 0 do
          IO.puts("  ⚠️  VIOLATIONS: #{length(violations)} segments exceed target")
        else
          IO.puts("  ✅ NO VIOLATIONS")
        end

        if logs =~ "[HLS RFC8216 Violation]" do
          IO.puts("  ⚠️  RFC violations logged")
        end

        IO.puts("")

      {:error, reason} ->
        IO.puts("ERROR: Could not read playlist: #{inspect(reason)}")
    end
  end
end
