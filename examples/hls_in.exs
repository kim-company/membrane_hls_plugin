Mix.install(
  [
    {:membrane_core, "~> 1.1.1"},
    {:membrane_file_plugin, "~> 0.17.0"},
    {:req, "~> 0.5.0"},
    # {:membrane_hls_plugin, github: "kim-company/membrane_hls_plugin"},
    {:membrane_hls_plugin,
     github: "kim-company/membrane_hls_plugin", ref: "a19ab7e12aa75c31c6b75b40f709c8f0ce9195a"},
    {:membrane_mpeg_ts_plugin, github: "kim-company/membrane_mpeg_ts_plugin"},
    {:kim_hls,
     github: "kim-company/kim_hls",
     ref: "4226bf8a6f75bb69376a9b04097d783fabd33451",
     override: true},
    {:membrane_h264_ffmpeg_plugin, "~> 0.32.5"},
    # hls egress
    {:membrane_http_adaptive_stream_plugin, "~> 0.18.6"},
    # rtp egress
    {:membrane_rtp_plugin, "~> 0.29.1"}
  ],
  consolidate_protocols: false
)

defmodule My.Reader do
  defstruct []
end

defimpl Membrane.HLS.Reader, for: My.Reader do
  @impl true
  def read(_, path, _) do
    %Req.Response{status: 200, body: body} = Req.get!(path)
    {:ok, body}
  end
end

defmodule Membrane.Demo.HLSIn do
  @moduledoc """
  Pipeline that contains HLS input element.
  """

  use Membrane.Pipeline
  alias Membrane.HLS.Source
  alias HLS.Playlist.Master

  @impl true
  def handle_init(_ctx, opts) do
    structure =
      child(:source, %Membrane.HLS.Source{
        reader: %My.Reader{},
        master_playlist_uri: "<URL>"
      })

    {[spec: structure], opts}
  end

  @impl true
  def handle_child_notification({:hls_master_playlist, master}, :source, _ctx, state) do
    stream =
      master
      |> Master.variant_streams()
      # we always choose stream variant 0 here
      |> Enum.at(0)

    case stream do
      nil ->
        {[], state}

      stream ->
        structure = [
          get_child(:source)
          |> via_out(Pad.ref(:output, {:rendition, stream}))
          |> child(:demuxer, Membrane.MPEG.TS.Demuxer)
        ]

        {[{:spec, structure}], state}
    end
  end

  @impl true
  def handle_child_notification({:mpeg_ts_pmt, pmt}, :demuxer, _context, state) do
    %{streams: streams} = pmt

    audio_track_id =
      Enum.find_value(streams, fn {track_id, content} ->
        if content.stream_type == :AAC, do: track_id
      end)

    video_track_id =
      Enum.find_value(streams, fn {track_id, content} ->
        if content.stream_type == :H264, do: track_id
      end)

    {:ok, packager} =
      HLS.Packager.start_link(
        storage: HLS.Storage.File.new(),
        manifest_uri: URI.new!("file://tmp/stream.m3u8"),
        resume_finished_tracks: true,
        restore_pending_segments: false
      )

    structure = [
      child(:sink, %Membrane.HLS.SinkBin{
        packager: packager,
        target_segment_duration: Membrane.Time.seconds(7)
      }),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, {:stream_id, audio_track_id}))
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
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, {:stream_id, video_track_id}))
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
              bandwidth: 3_951_200,
              resolution: format.resolution,
              codecs: Membrane.HLS.serialize_codecs(format.codecs),
              audio: "program_audio"
            }
          end
        ]
      )
      |> get_child(:sink)
    ]

    {[spec: {structure, log_metadata: Logger.metadata()}], state}
  end

  @impl true
  def handle_child_notification(_msg, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:sink, :input, _ctx, state) do
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end
end

{:ok, _supervisor, pipeline_pid} = Membrane.Pipeline.start_link(Membrane.Demo.HLSIn, [])
IO.inspect(pipeline_pid, label: "pipeline_pid")
ref = Process.monitor(pipeline_pid)

:ok =
  receive do
    {:DOWN, ^ref, :process, ^pipeline_pid, _reason} -> :ok
  end
