defmodule Membrane.HLS.SourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.HLS.Source
  alias HLS.Playlist.Media

  @media_playlist_uri URI.new!("file://test/fixtures/mpeg-ts/stream_416x234.m3u8")

  test "provides all segments of media playlist" do
    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: @media_playlist_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []}
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    assert_start_of_stream(pipeline, :sink)

    assert_sink_stream_format(pipeline, :sink, %Membrane.RemoteStream{
      content_format: %Membrane.HLS.Format.MPEG{codecs: []}
    })

    playlist_path = to_path(@media_playlist_uri)
    playlist_data = File.read!(playlist_path)
    playlist = HLS.Playlist.unmarshal(playlist_data, %Media{uri: @media_playlist_uri})
    base_dir = Path.dirname(playlist_path)

    playlist.segments
    |> Enum.map(&segment_path(base_dir, &1.uri))
    |> Enum.map(&File.read!/1)
    |> Enum.each(&assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^&1}, 5_000))

    assert_end_of_stream(pipeline, :sink)
    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "emits new segments when live playlist updates", %{tmp_dir: tmp_dir} do
    media_uri = URI.new!("file://#{tmp_dir}/media.m3u8")
    seg0 = "seg0.ts"
    seg1 = "seg1.ts"
    seg2 = "seg2.ts"

    File.write!(Path.join(tmp_dir, seg0), "segment0")
    write_media_playlist(tmp_dir, [seg0], finished: false)

    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: media_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []}
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment0"}, 5_000)

    File.write!(Path.join(tmp_dir, seg1), "segment1")
    write_media_playlist(tmp_dir, [seg0, seg1], finished: false)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment1"}, 5_000)

    File.write!(Path.join(tmp_dir, seg2), "segment2")
    write_media_playlist(tmp_dir, [seg0, seg1, seg2], finished: true)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment2"}, 5_000)
    assert_end_of_stream(pipeline, :sink)

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "supports packed audio and webvtt playlists", %{tmp_dir: tmp_dir} do
    audio_uri = URI.new!("file://#{tmp_dir}/audio.m3u8")
    subs_uri = URI.new!("file://#{tmp_dir}/subs.m3u8")

    File.write!(Path.join(tmp_dir, "audio.aac"), "audio")
    File.write!(Path.join(tmp_dir, "subs.vtt"), "WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n")

    write_media_playlist(tmp_dir, ["audio.aac"], finished: true, filename: "audio.m3u8")
    write_media_playlist(tmp_dir, ["subs.vtt"], finished: true, filename: "subs.m3u8")

    spec = [
      child(:audio_source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: audio_uri,
        stream_format: %Membrane.HLS.Format.PackedAudio{}
      })
      |> child(:audio_sink, Membrane.Testing.Sink),
      child(:subs_source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: subs_uri,
        stream_format: %Membrane.HLS.Format.WebVTT{language: "en"}
      })
      |> child(:subs_sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    assert_start_of_stream(pipeline, :audio_sink)
    assert_start_of_stream(pipeline, :subs_sink)

    assert_sink_stream_format(pipeline, :audio_sink, %Membrane.RemoteStream{
      content_format: %Membrane.HLS.Format.PackedAudio{}
    })

    assert_sink_stream_format(pipeline, :subs_sink, %Membrane.RemoteStream{
      content_format: %Membrane.HLS.Format.WebVTT{language: "en"}
    })

    assert_sink_buffer(pipeline, :audio_sink, %Membrane.Buffer{payload: "audio"}, 5_000)
    assert_sink_buffer(pipeline, :subs_sink, %Membrane.Buffer{payload: "WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n"}, 5_000)

    assert_end_of_stream(pipeline, :audio_sink)
    assert_end_of_stream(pipeline, :subs_sink)

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "propagates discontinuity, init section, and byterange metadata", %{tmp_dir: tmp_dir} do
    media_uri = URI.new!("file://#{tmp_dir}/media.m3u8")

    File.write!(Path.join(tmp_dir, "init.mp4"), "initdata")
    File.write!(Path.join(tmp_dir, "seg.ts"), "segmentdata")

    write_media_playlist(tmp_dir, ["seg.ts"],
      finished: true,
      filename: "media.m3u8",
      init_section: %{uri: "init.mp4", byterange: "4@0"},
      discontinuity: true,
      byterange: "4@2"
    )

    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: media_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []}
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    assert_sink_buffer(
      pipeline,
      :sink,
      %Membrane.Buffer{payload: "segmentdata", metadata: segment},
      5_000
    )

    assert segment.discontinuity == true
    assert segment.byterange == %{length: 4, offset: 2}
    assert segment.init_section == %{uri: "init.mp4", byterange: %{length: 4, offset: 0}}

    assert_end_of_stream(pipeline, :sink)
    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "waits for demand before delivering buffers", %{tmp_dir: tmp_dir} do
    media_uri = URI.new!("file://#{tmp_dir}/media.m3u8")
    seg0 = "seg0.ts"

    File.write!(Path.join(tmp_dir, seg0), "segment0")
    write_media_playlist(tmp_dir, [seg0], finished: true)

    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: media_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []}
      })
      |> child(:sink, %Membrane.Testing.Sink{autodemand: false})
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    assert_sink_stream_format(pipeline, :sink, %Membrane.RemoteStream{
      content_format: %Membrane.HLS.Format.MPEG{codecs: []}
    })

    refute_receive {Membrane.Testing.Notification, {:buffer, _}}, 200

    Membrane.Testing.Pipeline.notify_child(pipeline, :sink, {:make_demand, 1})
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment0"}, 5_000)
    assert_end_of_stream(pipeline, :sink)

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "retries when media playlist is missing", %{tmp_dir: tmp_dir} do
    media_uri = URI.new!("file://#{tmp_dir}/media.m3u8")
    seg0 = "seg0.ts"

    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: media_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []}
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    File.write!(Path.join(tmp_dir, seg0), "segment0")
    write_media_playlist(tmp_dir, [seg0], finished: true)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment0"}, 5_000)
    assert_end_of_stream(pipeline, :sink)

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "skips missing segments but continues when new ones arrive", %{tmp_dir: tmp_dir} do
    media_uri = URI.new!("file://#{tmp_dir}/media.m3u8")
    seg0 = "seg0.ts"
    seg1 = "seg1.ts"

    write_media_playlist(tmp_dir, [seg0], finished: false)

    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: media_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []}
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    File.write!(Path.join(tmp_dir, seg1), "segment1")
    write_media_playlist(tmp_dir, [seg0, seg1], finished: true)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment1"}, 5_000)
    assert_end_of_stream(pipeline, :sink)

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "respects poll interval override for live playlist", %{tmp_dir: tmp_dir} do
    media_uri = URI.new!("file://#{tmp_dir}/media.m3u8")
    seg0 = "seg0.ts"
    seg1 = "seg1.ts"

    File.write!(Path.join(tmp_dir, seg0), "segment0")
    write_media_playlist(tmp_dir, [seg0], finished: false)

    spec = [
      child(:source, %Source{
        storage: %HLS.Storage.File{},
        media_playlist_uri: media_uri,
        stream_format: %Membrane.HLS.Format.MPEG{codecs: []},
        poll_interval_ms: 50
      })
      |> child(:sink, Membrane.Testing.Sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())
    assert_start_of_stream(pipeline, :sink)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment0"}, 1_000)

    File.write!(Path.join(tmp_dir, seg1), "segment1")
    write_media_playlist(tmp_dir, [seg0, seg1], finished: true)
    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: "segment1"}, 1_000)
    assert_end_of_stream(pipeline, :sink)

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  defp write_media_playlist(tmp_dir, segments, opts) do
    target = Keyword.get(opts, :target_duration, 1)
    finished = Keyword.get(opts, :finished, false)
    type = Keyword.get(opts, :type, :event)
    filename = Keyword.get(opts, :filename, "media.m3u8")
    init_section = Keyword.get(opts, :init_section)
    discontinuity = Keyword.get(opts, :discontinuity, false)
    byterange = Keyword.get(opts, :byterange)

    segment_rows =
      Enum.map(segments, fn segment ->
        [
          if(discontinuity, do: "#EXT-X-DISCONTINUITY", else: nil),
          if(byterange, do: "#EXT-X-BYTERANGE:#{byterange}", else: nil),
          "#EXTINF:#{format_duration(target)},",
          segment
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    body =
      [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-TARGETDURATION:#{target}",
        "#EXT-X-MEDIA-SEQUENCE:0",
        if(type, do: "#EXT-X-PLAYLIST-TYPE:#{String.upcase(to_string(type))}", else: nil),
        if(init_section, do: "#EXT-X-MAP:#{format_map(init_section)}", else: nil),
        segment_rows
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    content =
      if finished do
        body <> "\n#EXT-X-ENDLIST\n"
      else
        body <> "\n"
      end

    File.write!(Path.join(tmp_dir, filename), content)
  end

  defp format_duration(seconds) do
    :erlang.float_to_binary(seconds * 1.0, decimals: 5)
  end

  defp format_map(%{uri: uri, byterange: byterange}) do
    ~s(URI="#{uri}",BYTERANGE="#{byterange}")
  end

  defp format_map(%{uri: uri}) do
    ~s(URI="#{uri}")
  end

  defp segment_path(base_dir, %URI{path: path}), do: Path.join(base_dir, path)
  defp segment_path(base_dir, path) when is_binary(path), do: Path.join(base_dir, path)

  defp to_path(%URI{scheme: "file"} = uri) do
    [uri.host, uri.path]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Path.join()
  end
end
