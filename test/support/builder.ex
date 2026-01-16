defmodule Support.Builder do
  import Membrane.ChildrenSpec
  import ExUnit.Assertions

  alias Membrane.Pad

  require Pad

  @avsync "test/fixtures/avsync_48k.ts"

  def avsync_fixture, do: @avsync

  def build_base_spec(manifest_uri, storage, opts \\ []) do
    playlist_mode = Keyword.get(opts, :playlist_mode, :vod)
    target_segment_duration = Keyword.get(opts, :target_segment_duration, Membrane.Time.seconds(7))
    flush_on_end = Keyword.get(opts, :flush_on_end, true)

    [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: target_segment_duration,
        playlist_mode: playlist_mode,
        flush_on_end: flush_on_end
      }),

      child(:source, %Membrane.File.Source{
        location: @avsync
      })
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer)
    ]
  end

  def build_subtitles_spec() do
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

  def build_cmaf_spec() do
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
        output_stream_structure: :avc1,
        skip_until_keyframe: false
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

  def build_cmaf_video_spec() do
    [
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        skip_until_keyframe: false
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
              codecs: []
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  def build_mpeg_ts_spec() do
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

  def build_mpeg_ts_video_spec() do
    [
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
              codecs: codecs
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  def build_mpeg_ts_audio_spec() do
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
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 128_000,
              codecs: ["mp4a.40.2"]
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  def build_packed_aac_spec() do
    [
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :audio])
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          container: :PACKED_AAC,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn _format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 128_000,
              codecs: ["mp4a.40.2"]
            }
          end
        ]
      )
      |> get_child(:sink)
    ]
  end

  def build_full_mpeg_ts_spec() do
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

  def assert_hls_output(manifest_uri) do
    {manifest_path, master_playlist} = load_master_playlist(manifest_uri)

    (master_playlist.streams ++ master_playlist.alternative_renditions)
    |> Enum.each(fn stream ->
      case Map.get(stream, :uri) do
        nil -> :ok
        uri -> validate_media_playlist_exists(uri, manifest_path)
      end
    end)
  end

  def assert_event_output(manifest_uri, opts \\ []) do
    assert_hls_output(manifest_uri)

    allow_vod = Keyword.get(opts, :allow_vod, false)
    media_playlists = load_media_playlists(manifest_uri)

    Enum.each(media_playlists, fn media ->
      type_ok? =
        case media.type do
          :event -> true
          :vod -> allow_vod
          _ -> false
        end

      assert type_ok?, "Media playlist should be EVENT type"

      Enum.each(media.segments, fn segment ->
        assert segment.program_date_time != nil,
               "Segment should include EXT-X-PROGRAM-DATE-TIME"
      end)
    end)
  end

  def load_media_playlists(manifest_uri) do
    {manifest_path, master_playlist} = load_master_playlist(manifest_uri)
    manifest_dir = Path.dirname(manifest_path)

    (master_playlist.streams ++ master_playlist.alternative_renditions)
    |> Enum.reduce([], fn stream, acc ->
      case Map.get(stream, :uri) do
        nil ->
          acc

        uri ->
          uri_path = if is_struct(uri, URI), do: uri.path, else: uri
          playlist_path = Path.join(manifest_dir, uri_path)
          playlist_content = File.read!(playlist_path)

          media_playlist =
            HLS.Playlist.unmarshal(
              playlist_content,
              %HLS.Playlist.Media{uri: URI.new!("file://#{playlist_path}")}
            )

          [media_playlist | acc]
      end
    end)
    |> Enum.reverse()
  end

  def assert_program_date_time_alignment(manifest_uri, tolerance_ms) do
    media_playlists = load_media_playlists(manifest_uri)

    sequence_sets =
      media_playlists
      |> Enum.map(fn media ->
        media.segments
        |> Enum.map(& &1.absolute_sequence)
        |> MapSet.new()
      end)

    common_sequences =
      case sequence_sets do
        [] -> MapSet.new()
        [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
      end

    Enum.each(common_sequences, fn seq ->
      datetimes =
        Enum.map(media_playlists, fn media ->
          segment = Enum.find(media.segments, &(&1.absolute_sequence == seq))
          segment.program_date_time
        end)

      [first | rest] = datetimes

      max_diff_ms =
        Enum.map(rest, fn dt -> abs(DateTime.diff(dt, first, :millisecond)) end)
        |> Enum.max(fn -> 0 end)

      assert max_diff_ms <= tolerance_ms,
             "EXT-X-PROGRAM-DATE-TIME drift exceeds tolerance at sequence #{seq}"
    end)
  end

  defp make_cue_buffer(from, to, text) do
    %Membrane.Buffer{
      payload: text,
      pts: Membrane.Time.milliseconds(from),
      metadata: %{to: Membrane.Time.milliseconds(to)}
    }
  end

  defp load_master_playlist(manifest_uri) do
    manifest_path = URI.to_string(manifest_uri) |> String.replace("file://", "")
    assert File.exists?(manifest_path), "Master playlist should exist at #{manifest_path}"

    manifest_content = File.read!(manifest_path)

    master_playlist =
      HLS.Playlist.unmarshal(manifest_content, %HLS.Playlist.Master{uri: manifest_uri})

    {manifest_path, master_playlist}
  end

  defp validate_media_playlist_exists(playlist_uri, manifest_path) do
    manifest_dir = Path.dirname(manifest_path)
    uri_path = if is_struct(playlist_uri, URI), do: playlist_uri.path, else: playlist_uri
    playlist_path = Path.join(manifest_dir, uri_path)

    assert File.exists?(playlist_path),
           "Media playlist should exist at #{playlist_path}"

    validate_media_playlist_content(playlist_path)
  end

  defp validate_media_playlist_content(playlist_path) do
    playlist_content = File.read!(playlist_path)
    playlist_dir = Path.dirname(playlist_path)

    media_uri = URI.new!("file://#{playlist_path}")
    media_playlist = HLS.Playlist.unmarshal(playlist_content, %HLS.Playlist.Media{uri: media_uri})

    assert media_playlist.version > 0, "Media playlist should have a valid version"

    assert media_playlist.target_segment_duration > 0,
           "Media playlist should have a target segment duration"

    if Enum.empty?(media_playlist.segments) do
      :ok
    else
      assert length(media_playlist.segments) > 0,
             "Media playlist should contain at least one segment"

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

        assert File.stat!(segment_path).size > 0,
               "Segment file should not be empty: #{segment_path}"
      end)
    end
  end
end
