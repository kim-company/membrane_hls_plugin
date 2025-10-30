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

  use ExUnit.Case, async: false
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
    test "target 2s with 2s keyframes produces exact 2s segments", %{tmp_dir: tmp_dir} do
      # With h264_2s_keyframes.ts (keyframes every 2s) and target_duration=2s,
      # segments should be exactly 2.0s with no violations
      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_diagnostic_pipeline(tmp_dir, @h264_2s_keyframes, 2)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video.m3u8"))
      durations = extract_segment_durations(content)

      # All segments should be exactly 2.0s
      assert Enum.all?(durations, &(&1 == 2.0)),
             "Expected all segments to be 2.0s, got: #{inspect(durations)}"

      # No RFC violations should be logged
      refute logs =~ "[HLS RFC8216 Violation]",
             "Should not emit RFC violations with matching target and keyframes"
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 4s with 2s keyframes produces exact 4s segments", %{tmp_dir: tmp_dir} do
      # With 2s keyframes, a 4s target should combine 2 keyframes per segment
      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_diagnostic_pipeline(tmp_dir, @h264_2s_keyframes, 4)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video.m3u8"))
      durations = extract_segment_durations(content)

      # All segments should be exactly 4.0s
      assert Enum.all?(durations, &(&1 == 4.0)),
             "Expected all segments to be 4.0s, got: #{inspect(durations)}"

      refute logs =~ "[HLS RFC8216 Violation]"
    end

    @tag :tmp_dir
    @tag timeout: 30_000
    test "target 6s with 2s keyframes produces exact 6s segments", %{tmp_dir: tmp_dir} do
      # With 2s keyframes, a 6s target should combine 3 keyframes per segment
      logs = capture_log(fn ->
        {spec, _manifest_uri} = build_diagnostic_pipeline(tmp_dir, @h264_2s_keyframes, 6)
        pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
        assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 30_000)
        :ok = Membrane.Pipeline.terminate(pipeline)
        Process.sleep(500)
      end)

      {:ok, content} = File.read(Path.join(tmp_dir, "stream_video.m3u8"))
      durations = extract_segment_durations(content)

      # All segments should be exactly 6.0s
      assert Enum.all?(durations, &(&1 == 6.0)),
             "Expected all segments to be 6.0s, got: #{inspect(durations)}"

      refute logs =~ "[HLS RFC8216 Violation]"
    end
  end
end
