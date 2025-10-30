defmodule Membrane.HLS.RFC8216ComplianceTest do
  @moduledoc """
  Tests for RFC 8216 (HTTP Live Streaming) compliance.

  These tests verify that the SinkBin adheres to key requirements from RFC 8216
  (https://datatracker.ietf.org/doc/html/rfc8216).

  ## Test Coverage

  ### Warning Emission (Section 4.3.3.1)
  - Verifies that warnings are emitted when segments exceed target duration
  - Confirms no warnings for compliant streams with adequate target duration

  ### Playlist Structure (Section 4)
  - Master playlists start with #EXTM3U tag (Section 4.3.1.1)
  - Media playlists contain required tags: VERSION, TARGETDURATION (Section 4.3.3)
  - VOD playlists include EXT-X-ENDLIST and TYPE:VOD (Section 4.3.3.5)
  - CMAF playlists include EXT-X-MAP for initialization section (Section 4.3.2.5)

  ### Segment Timing (Section 4.3.3.1)
  - All segments are within the declared target duration (with warnings for violations)
  - EXT-X-TARGETDURATION matches the configured target duration
  - Segment durations are relatively consistent across the stream

  ### Codec Strings (Section 4.3.4.1)
  - H.264 codec strings follow avc1.PPCCLL format (RFC 6381)
  - Codec strings are properly included in variant stream definitions

  ### Positive Compliance Tests
  - CMAF streams with adequate target duration produce no RFC violations
  - MPEG-TS streams with adequate target duration produce no RFC violations

  ## Implementation Notes

  - The implementation uses a warning-based approach: RFC violations are logged
    but do not prevent stream creation
  - Segment duration constraints depend on keyframe positioning in source media
  - Tests use realistic target durations (2-6s) with correct framerate configuration
    to validate production scenarios
  """

  use ExUnit.Case, async: true
  use Membrane.Pipeline

  import Membrane.Testing.Assertions
  import Membrane.HLS.RFC8216Helper
  import ExUnit.CaptureLog

  @avsync "test/fixtures/avsync.ts"

  # Helper to build a basic SinkBin pipeline with both audio and video
  defp build_pipeline(tmp_dir, opts \\ []) do
    target_duration = Keyword.get(opts, :target_duration, Membrane.Time.seconds(6))
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
        generate_best_effort_timestamps: %{framerate: {30, 1}},
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

  describe "Warning Emission - segment_exceeds_target_duration" do
    @tag :tmp_dir
    test "emits error when segment exceeds target duration", %{tmp_dir: tmp_dir} do
      # Use a very short target duration (1s) to force violations (keyframes are at 2s intervals)
      logs =
        capture_log(fn ->
          {spec, _manifest_uri} = build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(1))
          pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
          assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
          :ok = Membrane.Pipeline.terminate(pipeline)

          # Wait for async tasks
          Process.sleep(500)
        end)

      # Should emit RFC 8216 violation for segments exceeding target
      assert_rfc_violation_logged(logs, :segment_exceeds_target_duration)
    end

    @tag :tmp_dir
    test "no warning when segments are within target duration", %{tmp_dir: tmp_dir} do
      # Use a realistic target duration (6s) - now works correctly with fixed framerate
      logs =
        capture_log(fn ->
          {spec, _manifest_uri} =
            build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(6))

          pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
          assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
          :ok = Membrane.Pipeline.terminate(pipeline)

          # Wait for async tasks
          Process.sleep(500)
        end)

      # Should NOT emit violations when segments are within target
      assert_no_warnings(logs)
    end
  end

  describe "Playlist Structure Compliance" do
    @tag :tmp_dir
    test "master playlist starts with #EXTM3U", %{tmp_dir: tmp_dir} do
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, master_content} = File.read(Path.join(tmp_dir, "stream.m3u8"))
      assert_valid_playlist_header(master_content)
    end

    @tag :tmp_dir
    test "media playlist has required tags", %{tmp_dir: tmp_dir} do
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      assert_valid_playlist_header(media_content)
      assert_required_media_playlist_tags(media_content)
    end

    @tag :tmp_dir
    test "VOD playlist has EXT-X-ENDLIST and TYPE:VOD", %{tmp_dir: tmp_dir} do
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      assert_vod_playlist_complete(media_content)
    end

    @tag :tmp_dir
    test "CMAF playlist has EXT-X-MAP for initialization section", %{tmp_dir: tmp_dir} do
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      assert_cmaf_has_init_section(media_content)
    end
  end

  describe "Segment Timing Compliance" do
    @tag :tmp_dir
    test "all segments are within target duration", %{tmp_dir: tmp_dir} do
      # Use realistic target (6s) - now works correctly with fixed framerate
      {spec, _manifest_uri} = build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(6))
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      assert_segments_within_target(media_content)
    end

    @tag :tmp_dir
    test "EXT-X-TARGETDURATION matches requested target duration", %{tmp_dir: tmp_dir} do
      target = 7
      {spec, _manifest_uri} = build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(target))
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      actual_target = extract_target_duration(media_content)

      assert actual_target == target,
             "EXT-X-TARGETDURATION should be #{target} (requested), but was #{actual_target}"
    end

    @tag :tmp_dir
    test "EXT-X-TARGETDURATION equals ceiling of max segment duration", %{tmp_dir: tmp_dir} do
      # RFC 8216 Section 4.3.3.1: MUST be equal to ceiling of maximum segment duration
      {spec, _manifest_uri} = build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(6))
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))

      # Verify the RFC requirement
      assert_correct_target_duration(media_content)
    end

    @tag :tmp_dir
    test "segment durations are consistent", %{tmp_dir: tmp_dir} do
      # Use realistic target (6s) - now works correctly with fixed framerate
      {spec, _manifest_uri} = build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(6))
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))
      durations = extract_segment_durations(media_content)

      # Check that segment durations are relatively consistent with each other
      # (not checking against target, since packager may produce smaller segments)
      avg_duration = Enum.sum(durations) / length(durations)
      min_expected = avg_duration * 0.5
      max_expected = avg_duration * 1.5

      Enum.each(durations, fn duration ->
        assert duration >= min_expected and duration <= max_expected,
               "Segment duration #{duration}s should be within 50% of average #{avg_duration}s for consistency"
      end)
    end
  end

  describe "Discontinuity and Sequence Compliance" do
    @tag :tmp_dir
    test "discontinuity tags are properly formatted when present", %{tmp_dir: tmp_dir} do
      # RFC 8216 Section 4.3.2.3: Discontinuity tags must be properly formatted
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))

      # Check that if discontinuities exist, they're properly formatted
      # For VOD streams, discontinuities may or may not be present
      if has_discontinuity?(media_content) do
        # Discontinuity tags should be standalone (no parameters)
        lines = String.split(media_content, "\n")
        discontinuity_lines = Enum.filter(lines, &String.starts_with?(&1, "#EXT-X-DISCONTINUITY"))

        Enum.each(discontinuity_lines, fn line ->
          assert line == "#EXT-X-DISCONTINUITY",
                 "Discontinuity tag should have no parameters, but was: #{line}"
        end)
      end
    end

    @tag :tmp_dir
    test "VOD playlists do not require media sequence numbers", %{tmp_dir: tmp_dir} do
      # RFC 8216 Section 4.3.3.2: Media sequence is required for live/event, optional for VOD
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, media_content} = File.read(Path.join(tmp_dir, "stream_video_460x720.m3u8"))

      # Verify it's VOD
      assert media_content =~ "#EXT-X-PLAYLIST-TYPE:VOD",
             "Expected VOD playlist type"

      # VOD playlists may or may not have media sequence
      # If they do, it should start at 0 or 1
      if media_content =~ "#EXT-X-MEDIA-SEQUENCE:" do
        case Regex.run(~r/#EXT-X-MEDIA-SEQUENCE:(\d+)/, media_content) do
          [_, seq] ->
            seq_num = String.to_integer(seq)
            assert seq_num >= 0,
                   "Media sequence should be >= 0, but was #{seq_num}"
          nil -> :ok
        end
      end
    end
  end

  describe "Codec String Compliance" do
    @tag :tmp_dir
    test "H.264 codec strings follow avc1.PPCCLL format", %{tmp_dir: tmp_dir} do
      {spec, _manifest_uri} = build_pipeline(tmp_dir)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
      :ok = Membrane.Pipeline.terminate(pipeline)

      Process.sleep(500)

      {:ok, master_content} = File.read(Path.join(tmp_dir, "stream.m3u8"))

      # Extract codec strings from variant streams
      codecs =
        master_content
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "#EXT-X-STREAM-INF"))
        |> Enum.flat_map(&extract_codecs_from_variant/1)
        |> Enum.filter(&String.starts_with?(&1, "avc1"))

      # Should have at least one H.264 codec
      assert length(codecs) > 0, "Expected H.264 codec in master playlist"

      # All H.264 codecs should follow RFC format
      Enum.each(codecs, &assert_valid_h264_codec/1)
    end
  end

  describe "Positive Compliance Tests" do
    @tag :tmp_dir
    test "compliant CMAF stream emits no RFC warnings", %{tmp_dir: tmp_dir} do
      logs =
        capture_log(fn ->
          # Use realistic target (6s) - now works correctly with fixed framerate
          {spec, _manifest_uri} = build_pipeline(tmp_dir, target_duration: Membrane.Time.seconds(6))
          pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
          assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
          :ok = Membrane.Pipeline.terminate(pipeline)

          Process.sleep(500)
        end)

      # A properly configured stream should not emit RFC violations
      # (Though it may emit warnings for segment duration variance which is expected)
      # We specifically check there are no ERROR level violations
      refute logs =~ "[HLS RFC8216 Violation]",
             "Compliant CMAF stream should not emit RFC 8216 violations"
    end

    @tag :tmp_dir
    test "compliant MPEG-TS stream emits no RFC warnings", %{tmp_dir: tmp_dir} do
      logs =
        capture_log(fn ->
          # Use TS container for this test
          storage = HLS.Storage.File.new(base_dir: tmp_dir)
          manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

          spec = [
            child(:sink, %Membrane.HLS.SinkBin{
              storage: storage,
              manifest_uri: manifest_uri,
              target_segment_duration: Membrane.Time.seconds(7)
            }),
            child(:source, %Membrane.File.Source{location: @avsync})
            |> child(:demuxer, Membrane.MPEG.TS.Demuxer),

            # Audio path with TS
            get_child(:demuxer)
            |> via_out(:output, options: [stream_category: :audio])
            |> child(:aac_parser, %Membrane.AAC.Parser{
              out_encapsulation: :ADTS
            })
            |> via_in(Pad.ref(:input, "audio_128k"),
              options: [
                encoding: :AAC,
                container: :PACKED_AAC,
                segment_duration: Membrane.Time.seconds(6),
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

            # Video path with TS
            get_child(:demuxer)
            |> via_out(:output, options: [stream_category: :video])
            |> child(:h264_parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {25, 1}},
              output_stream_structure: :annexb
            })
            |> via_in(Pad.ref(:input, "video_460x720"),
              options: [
                encoding: :H264,
                container: :TS,
                segment_duration: Membrane.Time.seconds(6),
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

          pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
          assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
          :ok = Membrane.Pipeline.terminate(pipeline)

          Process.sleep(500)
        end)

      refute logs =~ "[HLS RFC8216 Violation]",
             "Compliant MPEG-TS stream should not emit RFC 8216 violations"
    end
  end
end
