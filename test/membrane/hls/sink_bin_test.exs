defmodule Membrane.HLS.SinkBinTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  @avsync "test/fixtures/avsync.ts"

  defp build_base_spec(packager) do
    [
      child(:sink, %Membrane.HLS.SinkBin{
        packager: packager,
        target_segment_duration: Membrane.Time.seconds(7)
      }),

      # Source
      child(:source, %Membrane.File.Source{
        location: @avsync
      })
      |> child(:demuxer, Membrane.MPEG.TS.AVDemuxer)
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
      |> via_out(:audio)
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
      |> via_out(:video)
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
      |> via_out(:audio)
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
      |> via_out(:video)
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

  @tag :tmp_dir
  test "on a new stream, CMAF", %{tmp_dir: tmp_dir} do
    {:ok, packager} =
      HLS.Packager.start_link(
        manifest_uri: URI.new!("file://#{tmp_dir}/stream.m3u8"),
        storage: HLS.Storage.File.new(),
        resume_finished_tracks: true,
        restore_pending_segments: false
      )

    spec =
      packager
      |> build_base_spec()
      |> Enum.concat(build_subtitles_spec())
      |> Enum.concat(build_cmaf_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS", %{tmp_dir: tmp_dir} do
    {:ok, packager} =
      HLS.Packager.start_link(
        manifest_uri: URI.new!("file://#{tmp_dir}/stream.m3u8"),
        storage: HLS.Storage.File.new(),
        resume_finished_tracks: true,
        restore_pending_segments: false
      )

    spec =
      packager
      |> build_base_spec()
      |> Enum.concat(build_subtitles_spec())
      |> Enum.concat(build_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end
end
