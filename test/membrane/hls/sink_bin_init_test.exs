defmodule Membrane.HLS.SinkBinInitTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias HLS.Playlist.{Master, Media}
  alias HLS.{Segment, VariantStream}
  alias Membrane.Pad
  require Pad

  @tag :tmp_dir
  test "emits packager_updated for a new playlist", %{tmp_dir: tmp_dir} do
    {pipeline, _manifest_uri} = start_sink(tmp_dir, resume?: false)

    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :new, %HLS.Packager{}})
    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "resumes CMAF playlist with init section and content", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)
    media_uri = URI.new!("stream_video.m3u8")

    write_cmaf_playlists(storage, manifest_uri, media_uri)

    {pipeline, _manifest_uri} =
      start_sink(tmp_dir, resume?: true, resume_on_error: :raise, storage: storage)

    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :resumed, packager})
    assert map_size(packager.tracks) == 1
    assert %HLS.Packager.Track{init_section: %{uri: _}} = packager.tracks["video"]

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "falls back to a new playlist when resume fails", %{tmp_dir: tmp_dir} do
    {pipeline, _manifest_uri} =
      start_sink(tmp_dir, resume?: true, resume_on_error: :start_new)

    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :resume_failed, _reason})
    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :new, %HLS.Packager{}})

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "falls back to a new playlist when master playlist is invalid", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)
    :ok = HLS.Storage.put(storage, manifest_uri, "not a playlist")

    {pipeline, _manifest_uri} =
      start_sink(tmp_dir, resume?: true, resume_on_error: :start_new, storage: storage)

    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :resume_failed, _reason})
    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :new, %HLS.Packager{}})

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "ignores existing CMAF playlists with init section when starting new", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)
    media_uri = URI.new!("stream_video.m3u8")

    write_cmaf_playlists(storage, manifest_uri, media_uri)

    {pipeline, _manifest_uri} = start_sink(tmp_dir, resume?: false, storage: storage)

    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :new, %HLS.Packager{}})
    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "falls back to a new playlist when CMAF media playlist is empty", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)
    media_uri = URI.new!("stream_video.m3u8")

    write_cmaf_master(storage, manifest_uri, media_uri)
    :ok = HLS.Storage.put(storage, media_uri, "")

    {pipeline, _manifest_uri} =
      start_sink(tmp_dir, resume?: true, resume_on_error: :start_new, storage: storage)

    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :resume_failed, _reason})
    assert_pipeline_notified(pipeline, :sink, {:packager_updated, :new, %HLS.Packager{}})

    Membrane.Testing.Pipeline.terminate(pipeline)
  end

  defp start_sink(tmp_dir, opts) do
    {manifest_uri, storage} = build_storage(tmp_dir)

    sink_opts =
      [
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(6),
        playlist_mode: :vod,
        flush_on_end: true
      ]
      |> Keyword.merge(opts)

    spec = [
      child(:sink, struct(Membrane.HLS.SinkBin, sink_opts)),
      child(:source, %Membrane.Testing.Source{stream_format: %Membrane.Text{}, output: []})
      |> via_in(Pad.ref(:input, "subtitles"),
        options: [
          encoding: :TEXT,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.Text{} ->
            %HLS.AlternativeRendition{
              uri: URI.new!("subtitles.m3u8"),
              name: "Subtitles",
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

    pipeline =
      Membrane.Testing.Pipeline.start_link_supervised!(spec: spec, test_process: self())

    {pipeline, manifest_uri}
  end

  defp build_storage(tmp_dir) do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")
    {manifest_uri, storage}
  end

  defp write_cmaf_playlists(storage, manifest_uri, media_uri) do
    write_cmaf_master(storage, manifest_uri, media_uri)

    segment = %Segment{
      uri: URI.new!("segment_00001.m4s"),
      duration: 6.0,
      init_section: %{uri: "init.mp4"}
    }

    media = %Media{
      uri: media_uri,
      version: 7,
      target_segment_duration: 6,
      media_sequence_number: 0,
      type: :event,
      segments: [segment]
    }

    :ok = HLS.Storage.put(storage, media_uri, HLS.Playlist.marshal(media))
  end

  defp write_cmaf_master(storage, manifest_uri, media_uri) do
    master = %Master{
      uri: manifest_uri,
      version: 7,
      independent_segments: true,
      streams: [
        %VariantStream{
          uri: media_uri,
          bandwidth: 100_000,
          codecs: ["avc1.42e01e"]
        }
      ]
    }

    :ok = HLS.Storage.put(storage, manifest_uri, HLS.Playlist.marshal(master))
  end
end
