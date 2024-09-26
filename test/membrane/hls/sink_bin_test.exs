defmodule Membrane.HLS.SinkBinTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  @tag :tmp_dir
  test "on a new stream", %{tmp_dir: tmp_dir} do
    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        manifest_uri: URI.new!("file://#{tmp_dir}/stream.m3u8"),
        target_segment_duration: Membrane.Time.seconds(4),
        storage: HLS.Storage.File.new()
      }),

      # Audio
      child(:aac_source, %Membrane.File.Source{
        location: "test/fixtures/samples_big-buck-bunny_bun33s.aac"
      })
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          build_stream: fn uri, %Membrane.CMAF.Track{} = format ->
            %HLS.AlternativeRendition{
              uri: uri,
              name: "Audio (EN)",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: to_string(format.codecs.mp4a.channels)
            }
          end
        ]
      )
      |> get_child(:sink),

      # Subtitles
      # child(:text_source, %Membrane.Testing.Source{
      #   stream_format: %Membrane.Text{locale: "de"},
      #   output: [
      #     %Membrane.Buffer{
      #       payload:
      #         "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua.",
      #       pts: Membrane.Time.milliseconds(100),
      #       metadata: %{duration: Membrane.Time.seconds(12)}
      #     }
      #   ]
      # })
      # |> via_in(Pad.ref(:input, "subtitles"),
      #   options: [
      #     encoding: :TEXT,
      #     build_stream: fn uri, %Membrane.Text{} = format ->
      #       %HLS.AlternativeRendition{
      #         uri: uri,
      #         name: "Subtitles (EN)",
      #         type: :subtitles,
      #         group_id: "subtitles",
      #         language: format.locale
      #       }
      #     end
      #   ]
      # )
      # |> get_child(:sink),

      # Video
      child(:h264_source, %Membrane.File.Source{
        location: "test/fixtures/samples_big-buck-bunny_bun33s_720x480.h264"
      })
      |> child(:h264_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {25, 1}},
        output_stream_structure: :avc1
      })
      |> via_in(Pad.ref(:input, "video_460x720"),
        options: [
          encoding: :H264,
          build_stream: fn uri, %Membrane.CMAF.Track{} = format ->
            %HLS.VariantStream{
              uri: uri,
              bandwidth: 10_000,
              resolution: format.resolution,
              frame_rate: 30.0,
              codecs: Membrane.HLS.serialize_codecs(format.codecs),
              audio: "audio",
              subtitles: "subtitles"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, :end_of_stream, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end
end
