Mix.install([
  :membrane_core,
  :membrane_rtmp_plugin,
  :membrane_aac_plugin,
  :membrane_h26x_plugin,
  :membrane_tee_plugin,
  {:membrane_ffmpeg_transcoder_plugin, "~> 1.1"},
  {:membrane_hls_plugin, path: Path.expand(Path.join(__DIR__, "../"))}
])

defmodule Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, _opts) do
    File.rm_rf("tmp")

    {:ok, packager} =
      HLS.Packager.start_link(
        storage: HLS.Storage.File.new(),
        manifest_uri: URI.new!("file://tmp/stream.m3u8"),
        resume_finished_tracks: true,
        restore_pending_segments: false
      )

    structure = [
      # Source
      child(:source, %Membrane.RTMP.Source{
        url: "rtmp://0.0.0.0:1935/app/stream_key"
      })
      |> child(:transcoder, Membrane.FFmpeg.Transcoder),
      
      # Sink
      child(:sink, %Membrane.HLS.SinkBin{
        packager: packager,
        target_segment_duration: Membrane.Time.seconds(7),
      }),

      # Audio
      get_child(:transcoder)
      |> via_out(:audio, options: [bitrate: 128_000])
      |> child(:audio_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            %HLS.AlternativeRendition{
              name: "Audio (EN)",
              type: :audio,
              group_id: "program_audio",
              language: "en",
              channels: to_string(format.codecs.mp4a.channels),
              autoselect: true,
              default: true
            }
          end
        ]
      )
      |> get_child(:sink),

      # Video HD
      get_child(:transcoder)
      |> via_out(:video, options: [
        resolution: {-2, 720},
        bitrate: 3_300_000,
        profile: :high,
        fps: 30,
        gop_size: 60,
        b_frames: 3,
        crf: 26,
        preset: :veryfast,
        tune: :zerolatency
      ])
      |> child({:parser, :hd}, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        output_alignment: :au
      })
      |> via_in(Pad.ref(:input, "video_720p"),
        options: [
          encoding: :H264,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 3951200,
              resolution: format.resolution,
              codecs: Membrane.HLS.serialize_codecs(format.codecs),
              audio: "program_audio"
            }
          end
        ]
      )
      |> get_child(:sink),

      # Video SD
      get_child(:transcoder)
      |> via_out(:video, options: [
        resolution: {-2, 360},
        bitrate: 1020800,
        profile: :main,
        fps: 15,
        gop_size: 30,
        b_frames: 3,
        crf: 26,
        preset: :veryfast,
        tune: :zerolatency
      ])
      |> child({:parser, :sd}, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        output_alignment: :au
      })
      |> via_in(Pad.ref(:input, "video_360p"),
        options: [
          encoding: :H264,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 1_200_000,
              resolution: format.resolution,
              codecs: Membrane.HLS.serialize_codecs(format.codecs),
              audio: "program_audio"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]

    {[spec: structure], %{}}
  end

  def handle_child_notification(:end_of_stream, :sink, _ctx, state) do
    {[terminate: :normal], state}
  end
end

# Start a pipeline with `Membrane.RTMP.Source` that will spawn an RTMP server waiting for
# the client connection on given URL
{:ok, _supervisor, pipeline} = Membrane.Pipeline.start_link(Pipeline)

# Wait for the pipeline to terminate itself
ref = Process.monitor(pipeline)

:ok =
  receive do
    {:DOWN, ^ref, _process, ^pipeline, :normal} -> :ok
  end
