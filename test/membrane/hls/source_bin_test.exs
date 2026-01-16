defmodule Membrane.HLS.SourceBinTest do
  use ExUnit.Case, async: true

  alias Membrane.HLS.SourceBin
  alias HLS.Playlist.Master

  import Membrane.Testing.Assertions

  @master_playlist_uri URI.new!("file://test/fixtures/mpeg-ts/stream.m3u8")

  defmodule Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts = %{storage: storage, master_playlist_uri: uri}) do
      structure = [
        child(:source, %SourceBin{storage: storage, master_playlist_uri: uri})
      ]

      {[spec: structure], opts}
    end

    def handle_child_notification({:hls_master_playlist, master}, :source, _ctx, state) do
      stream =
        master
        |> Master.variant_streams()
        |> Enum.find(fn x -> state.stream_selector.(x) end)

      case stream do
        nil ->
          {[], state}

        stream ->
          base = [
            get_child(:source)
            |> via_out(Pad.ref(:output, {:rendition, stream}))
            |> child(:sink, Membrane.Testing.Sink)
          ]

          structure =
            if Map.get(state, :select_alternatives, false) do
              alt_specs =
                master.alternative_renditions
                |> Enum.map(fn alt ->
                  sink_name =
                    case alt.type do
                      :audio -> :audio_sink
                      :subtitles -> :subs_sink
                      other -> {:alt_sink, other}
                    end

                  get_child(:source)
                  |> via_out(Pad.ref(:output, {:rendition, alt}))
                  |> child(sink_name, Membrane.Testing.Sink)
                end)

              base ++ alt_specs
            else
              base
            end

          {[{:spec, structure}], state}
      end
    end
  end

  describe "hls source bin" do
    test "notifies master playlist" do
      options = [
        module: Pipeline,
        custom_args: %{
          storage: %HLS.Storage.File{},
          master_playlist_uri: @master_playlist_uri,
          stream_selector: fn _ -> false end
        }
      ]

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(options)
      assert_pipeline_notified(pipeline, :source, {:hls_master_playlist, %Master{}})
      Membrane.Testing.Pipeline.terminate(pipeline)
    end

    test "provides all segments of selected rendition" do
      stream_name = "stream_416x234"
      target_stream_uri = URI.new!(stream_name <> ".m3u8")

      options = [
        module: Pipeline,
        custom_args: %{
          storage: %HLS.Storage.File{},
          master_playlist_uri: @master_playlist_uri,
          stream_selector: fn stream ->
            stream.uri == target_stream_uri
          end
        },
        test_process: self()
      ]

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(options)

      assert_start_of_stream(pipeline, :sink)

      assert_sink_stream_format(pipeline, :sink, %Membrane.RemoteStream{
        content_format: %Membrane.HLS.Format.MPEG{}
      })

      master_playlist_path = to_path(@master_playlist_uri)
      base_dir = Path.join([Path.dirname(master_playlist_path), stream_name, "00000"])

      base_dir
      |> File.ls!()
      |> Enum.map(&Path.join([base_dir, &1]))
      |> Enum.map(&File.read!/1)
      |> Enum.each(&assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^&1}, 5_000))

      assert_end_of_stream(pipeline, :sink)
      Membrane.Testing.Pipeline.terminate(pipeline)
    end

    @tag :tmp_dir
    test "supports audio and subtitles renditions", %{tmp_dir: tmp_dir} do
      master_uri = URI.new!("file://#{tmp_dir}/master.m3u8")

      File.write!(Path.join(tmp_dir, "video.ts"), "video")
      File.write!(Path.join(tmp_dir, "audio.aac"), "audio")
      File.write!(Path.join(tmp_dir, "subs.vtt"), "WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n")

      write_media_playlist(tmp_dir, "video.m3u8", ["video.ts"])
      write_media_playlist(tmp_dir, "audio.m3u8", ["audio.aac"])
      write_media_playlist(tmp_dir, "subs.m3u8", ["subs.vtt"])
      write_master_playlist(tmp_dir, "master.m3u8")

      options = [
        module: Pipeline,
        custom_args: %{
          storage: %HLS.Storage.File{},
          master_playlist_uri: master_uri,
          stream_selector: fn stream ->
            stream.uri == URI.new!("video.m3u8")
          end,
          select_alternatives: true
        },
        test_process: self()
      ]

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(options)

      assert_start_of_stream(pipeline, :sink)
      assert_start_of_stream(pipeline, :audio_sink)
      assert_start_of_stream(pipeline, :subs_sink)

      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "video"}, 5_000)
      assert_sink_buffer(pipeline, :audio_sink, %Membrane.Buffer{payload: "audio"}, 5_000)

      assert_sink_buffer(
        pipeline,
        :subs_sink,
        %Membrane.Buffer{payload: "WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n"},
        5_000
      )

      assert_end_of_stream(pipeline, :sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert_end_of_stream(pipeline, :subs_sink)

      Membrane.Testing.Pipeline.terminate(pipeline)
    end

    @tag :tmp_dir
    test "retries master playlist fetch", %{tmp_dir: tmp_dir} do
      master_uri = URI.new!("file://#{tmp_dir}/master.m3u8")

      options = [
        module: Pipeline,
        custom_args: %{
          storage: %HLS.Storage.File{},
          master_playlist_uri: master_uri,
          stream_selector: fn _ -> false end
        },
        test_process: self()
      ]

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(options)

      File.write!(Path.join(tmp_dir, "video.ts"), "video")
      write_media_playlist(tmp_dir, "video.m3u8", ["video.ts"])
      write_master_playlist(tmp_dir, "master.m3u8")

      assert_pipeline_notified(pipeline, :source, {:hls_master_playlist, %Master{}}, 5_000)
      Membrane.Testing.Pipeline.terminate(pipeline)
    end
  end

  defp to_path(%URI{scheme: "file"} = uri) do
    [uri.host, uri.path]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Path.join()
  end

  defp write_master_playlist(tmp_dir, filename) do
    content = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Subs",DEFAULT=YES,AUTOSELECT=YES,URI="subs.m3u8",LANGUAGE="en"
    #EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS="avc1.4d401f",RESOLUTION=640x360,AUDIO="audio",SUBTITLES="subs"
    video.m3u8
    """

    File.write!(Path.join(tmp_dir, filename), String.trim_leading(content))
  end

  defp write_media_playlist(tmp_dir, filename, segments) do
    body =
      [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-TARGETDURATION:1",
        "#EXT-X-MEDIA-SEQUENCE:0",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        Enum.map(segments, fn segment ->
          "#EXTINF:1.00000,\n#{segment}"
        end),
        "#EXT-X-ENDLIST"
      ]
      |> List.flatten()
      |> Enum.join("\n")

    File.write!(Path.join(tmp_dir, filename), body <> "\n")
  end
end
