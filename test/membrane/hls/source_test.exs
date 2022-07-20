defmodule Membrane.HLS.SourceTest do
  use ExUnit.Case

  alias Membrane.HLS.Source
  alias Membrane.Testing
  alias HLS.Storage
  alias HLS.Playlist.Master

  import Membrane.Testing.Assertions

  @master_playlist_path "./fixtures/mpeg-ts/stream.m3u8"
  @store Storage.new(%Storage.FS{location: @master_playlist_path})

  describe "hls source" do
    test "provides all segments of selected stream" do
      stream =
        @store
        |> Storage.get_master_playlist!()
        |> Master.variant_streams()
        |> List.first()

      children = [
        source: %Source{storage: @store, target: stream},
        sink: %Testing.Sink{}
      ]

      {:ok, pid} = Testing.Pipeline.start_link(
        links: Membrane.ParentSpec.link_linear(children)
      )

      # assert_sink_buffer(pid, :sink ,%Membrane.Buffer{payload: 255})
      # assert_sink_buffer(pid, :sink ,%Membrane.Buffer{payload: 255})
      # assert_sink_buffer(pid, :sink ,%Membrane.Buffer{payload: 255})
      # assert_sink_buffer(pid, :sink ,%Membrane.Buffer{payload: 255})
      # assert_sink_buffer(pid, :sink ,%Membrane.Buffer{payload: 255})
      assert_start_of_stream(pid, :sink)
      assert_end_of_stream(pid, :sink)
    end
  end
end
