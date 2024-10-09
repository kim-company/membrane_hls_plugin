defmodule Membrane.HLS.SinkBinTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  @tag :tmp_dir
  test "on a new stream", %{tmp_dir: tmp_dir} do
    {:ok, packager} =
      HLS.Packager.start_link(
        manifest_uri: URI.new!("file://#{tmp_dir}/stream.m3u8"),
        storage: HLS.Storage.File.new(),
        resume_finished_tracks: true,
        restore_pending_segments: false
      )

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        packager: packager,
        target_segment_duration: Membrane.Time.seconds(7)
      }),

      # Source
      child(:source, %Membrane.File.Source{
        location: "test/fixtures/avsync.flv"
      })
      |> child(:demuxer, Membrane.FLV.Demuxer),

      # Audio
      get_child(:demuxer)
      |> via_out(Pad.ref(:audio, 0))
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

      # Subtitles
      child(:text_source, %Membrane.Testing.Source{
        stream_format: %Membrane.Text{locale: "de"},
        output: [
          %Membrane.Buffer{
            payload: "",
            pts: 0,
            metadata: %{to: Membrane.Time.milliseconds(99)}
          },
          %Membrane.Buffer{
            payload: "Subtitle from start to 6s",
            pts: Membrane.Time.milliseconds(100),
            metadata: %{to: Membrane.Time.seconds(6) - Membrane.Time.millisecond()}
          },
          %Membrane.Buffer{
            payload: "",
            pts: Membrane.Time.seconds(6),
            metadata: %{to: Membrane.Time.seconds(12) - Membrane.Time.millisecond()}
          },
          %Membrane.Buffer{
            payload: "Subtitle from 12s to 16s",
            pts: Membrane.Time.seconds(12),
            metadata: %{to: Membrane.Time.seconds(16) - Membrane.Time.millisecond()}
          },
          %Membrane.Buffer{
            payload: "",
            pts: Membrane.Time.seconds(16),
            metadata: %{to: Membrane.Time.seconds(30) - Membrane.Time.millisecond()}
          }
        ]
      })
      |> via_in(Pad.ref(:input, "subtitles"),
        options: [
          encoding: :TEXT,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.Text{} = format ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Subtitles (EN)",
              type: :subtitles,
              group_id: "subtitles",
              language: format.locale,
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink),

      # Video
      # Audio
      get_child(:demuxer)
      |> via_out(Pad.ref(:video, 0))
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

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end
end
