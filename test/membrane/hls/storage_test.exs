defmodule Membrane.HLS.StorageTest do
  use ExUnit.Case

  alias Membrane.HLS.Storage.FS
  alias Membrane.HLS.Storage
  alias Membrane.HLS.Playlist.Master
  alias Membrane.HLS.Playlist.Media

  @master_playlist_path "./fixtures/mpeg-ts/stream.m3u8"
  @store Storage.new(%FS{location: @master_playlist_path})

  describe "Load playlist from disk" do
    test "fails when manifest location is invalid" do
      store = Storage.new(%FS{location: "invalid location"})
      assert {:error, _reason} = Storage.get_master_playlist(store)
    end

    test "gets valid master playlist" do
      assert {:ok, %Master{}} = Storage.get_master_playlist(@store)
    end

    test "gets media playlists from variant streams" do
      seen =
        @store
        |> Storage.get_master_playlist!()
        |> Master.variant_streams()
        |> Enum.reduce(0, fn stream, seen ->
          assert {:ok, %Media{}} = Storage.get_media_playlist(@store, stream.uri)
          seen + 1
        end)

      assert seen == 2
    end

    test "gets segments" do
      seen =
        @store
        |> Storage.get_master_playlist!()
        |> Master.variant_streams()
        |> Enum.reduce(0, fn stream, seen ->
          segments_seen =
            @store
            |> Storage.get_media_playlist!(stream.uri)
            |> Media.segments()
            |> Enum.reduce(0, fn segment, seen ->
              assert {:ok, _data} = Storage.get_segment(@store, segment.uri)
              seen + 1
            end)
          segments_seen + seen
        end)

      assert seen == 10
    end
  end
end
