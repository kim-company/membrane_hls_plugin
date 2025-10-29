defmodule Membrane.HLS.SinkBinTest do
  use ExUnit.Case, async: true
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  @avsync "test/fixtures/avsync.ts"

  defp build_base_spec(storage, manifest_uri) do
    [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(7)
      }),

      # Source
      child(:source, %Membrane.File.Source{
        location: @avsync
      })
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer)
    ]
  end

  defp make_cue_buffer(from, to, text) do
    %Membrane.Buffer{
      payload: text,
      pts: Membrane.Time.milliseconds(from),
      metadata: %{to: Membrane.Time.milliseconds(to)}
    }
  end

  defp build_subtitles_spec() do
    [
      child(:text_source, %Membrane.Testing.Source{
        stream_format: %Membrane.Text{},
        output: [
          make_cue_buffer(0, 99, ""),
          make_cue_buffer(100, 8_000, "Subtitle from start to 6s"),
          make_cue_buffer(8_001, 12_000, ""),
          make_cue_buffer(12_001, 16_000, "Subtitle from 12s to 16s"),
          make_cue_buffer(16_001, 30_000, "")
        ]
      })
      |> via_in(Pad.ref(:input, "subtitles"),
        options: [
          encoding: :TEXT,
          segment_duration: Membrane.Time.seconds(6),
          omit_subtitle_repetition: false,
          build_stream: fn %Membrane.Text{} ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Subtitles (EN)",
              type: :subtitles,
              group_id: "subtitles",
              language: "en",
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  defp build_cmaf_spec() do
    [
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :audio])
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Audio (EN)",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: to_string(format.codecs.mp4a.channels),
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink),
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {25, 1}},
        output_stream_structure: :avc1
      })
      |> via_in(Pad.ref(:input, "video_460x720"),
        options: [
          encoding: :H264,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 850_000,
              resolution: format.resolution,
              frame_rate: 30.0,
              codecs: [],
              audio: "audio",
              subtitles: "subtitles"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  defp build_mpeg_ts_spec() do
    # %{mp4a: %{channels: 2, aot_id: 2, frequency: 44100}}
    # %{avc1: %{profile: 100, level: 31, compatibility: 0}}

    [
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
          build_stream: fn format ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Audio (EN)",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: to_string(format.channels),
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink),
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.NALU.ParserBin{
        assume_aligned: true,
        alignment: :aud
      })
      |> via_in(Pad.ref(:input, "video_460x720"),
        options: [
          encoding: :H264,
          container: :TS,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn _format ->
            codecs =
              Membrane.HLS.serialize_codecs(%{
                avc1: %{profile: 100, level: 31, compatibility: 0}
              })

            %HLS.VariantStream{
              uri: nil,
              bandwidth: 850_000,
              resolution: {460, 720},
              frame_rate: 30.0,
              codecs: codecs,
              audio: "audio",
              subtitles: "subtitles"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  defp build_full_mpeg_ts_spec() do
    # %{mp4a: %{channels: 2, aot_id: 2, frequency: 44100}}
    # %{avc1: %{profile: 100, level: 31, compatibility: 0}}

    [
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :audio])
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :ADTS
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          container: :TS,
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
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.NALU.ParserBin{
        assume_aligned: true,
        alignment: :aud
      })
      |> via_in(Pad.ref(:input, "video_460x720"),
        options: [
          encoding: :H264,
          container: :TS,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn _format ->
            codecs =
              Membrane.HLS.serialize_codecs(%{
                avc1: %{profile: 100, level: 31, compatibility: 0}
              })

            %HLS.VariantStream{
              uri: nil,
              bandwidth: 850_000,
              resolution: {460, 720},
              frame_rate: 30.0,
              codecs: codecs,
              audio: "audio",
              subtitles: "subtitles"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  defp assert_hls_output(manifest_uri) do
    # Read and parse master playlist
    manifest_path = URI.to_string(manifest_uri) |> String.replace("file://", "")
    assert File.exists?(manifest_path), "Master playlist should exist at #{manifest_path}"

    manifest_content = File.read!(manifest_path)

    master_playlist =
      HLS.Playlist.unmarshal(manifest_content, %HLS.Playlist.Master{uri: manifest_uri})

    # Validate master playlist has content
    assert length(master_playlist.streams) > 0 ||
             length(master_playlist.alternative_renditions) > 0,
           "Master playlist should have at least one stream or rendition"

    # Validate each variant stream has a valid media playlist
    Enum.each(master_playlist.streams, fn stream ->
      validate_media_playlist_from_stream(stream, manifest_path)
    end)

    # Validate each alternative rendition has a valid media playlist
    Enum.each(master_playlist.alternative_renditions, fn rendition ->
      if rendition.uri do
        validate_media_playlist_from_uri(rendition.uri, manifest_path)
      end
    end)
  end

  defp validate_media_playlist_from_stream(stream, manifest_path) do
    manifest_dir = Path.dirname(manifest_path)
    uri_path = if is_struct(stream.uri, URI), do: stream.uri.path, else: stream.uri

    playlist_path =
      if String.starts_with?(uri_path, "/") do
        uri_path
      else
        Path.join(manifest_dir, uri_path)
      end

    assert File.exists?(playlist_path),
           "Media playlist for variant stream should exist at #{playlist_path}"

    validate_media_playlist_content(playlist_path, uri_path)
  end

  defp validate_media_playlist_from_uri(uri, manifest_path) do
    manifest_dir = Path.dirname(manifest_path)
    uri_path = if is_struct(uri, URI), do: uri.path, else: uri

    playlist_path =
      if String.starts_with?(uri_path, "/") do
        uri_path
      else
        Path.join(manifest_dir, uri_path)
      end

    assert File.exists?(playlist_path),
           "Media playlist for alternative rendition should exist at #{playlist_path}"

    validate_media_playlist_content(playlist_path, uri_path)
  end

  defp validate_media_playlist_content(playlist_path, _playlist_uri) do
    playlist_content = File.read!(playlist_path)
    playlist_dir = Path.dirname(playlist_path)

    # Parse the media playlist using HLS.Playlist
    media_uri = URI.new!("file://#{playlist_path}")
    media_playlist = HLS.Playlist.unmarshal(playlist_content, %HLS.Playlist.Media{uri: media_uri})

    # Validate basic playlist properties
    assert media_playlist.version > 0, "Media playlist should have a valid version"

    assert media_playlist.target_segment_duration > 0,
           "Media playlist should have a target segment duration"

    # Validate segments exist
    assert length(media_playlist.segments) > 0,
           "Media playlist should contain at least one segment"

    # Check each segment file exists
    Enum.each(media_playlist.segments, fn segment ->
      segment_uri_path = if is_struct(segment.uri, URI), do: segment.uri.path, else: segment.uri

      segment_path =
        if String.starts_with?(segment_uri_path, "/") do
          segment_uri_path
        else
          Path.join(playlist_dir, segment_uri_path)
        end

      assert File.exists?(segment_path),
             "Segment file should exist: #{segment_path}"

      # Check segment file is not empty
      assert File.stat!(segment_path).size > 0,
             "Segment file should not be empty: #{segment_path}"
    end)
  end

  @tag :tmp_dir
  test "on a new stream, CMAF", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new()
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      build_base_spec(storage, manifest_uri)
      |> Enum.concat(build_subtitles_spec())
      |> Enum.concat(build_cmaf_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    # Wait for async tasks to complete
    Process.sleep(500)

    # Validate the generated HLS output
    assert_hls_output(manifest_uri)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new()
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      build_base_spec(storage, manifest_uri)
      |> Enum.concat(build_subtitles_spec())
      |> Enum.concat(build_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    # Wait for async tasks to complete
    Process.sleep(500)

    # Validate the generated HLS output
    assert_hls_output(manifest_uri)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS with AAC", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new()
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      build_base_spec(storage, manifest_uri)
      |> Enum.concat(build_subtitles_spec())
      |> Enum.concat(build_full_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    # Wait for async tasks to complete
    Process.sleep(500)

    # Validate the generated HLS output
    assert_hls_output(manifest_uri)
  end
end
