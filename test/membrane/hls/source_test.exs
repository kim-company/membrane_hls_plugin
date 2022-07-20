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
      stream_name = "stream_416x234" 
      stream =
        @store
        |> Storage.get_master_playlist!()
        |> Master.variant_streams()
        |> Enum.find(fn stream -> stream.uri.path == stream_name <> ".m3u8" end)

      children = [
        source: %Source{storage: @store, rendition: stream},
        sink: %Testing.Sink{}
      ]

      {:ok, pid} = Testing.Pipeline.start_link(
        links: Membrane.ParentSpec.link_linear(children)
      )

      assert_start_of_stream(pid, :sink)

      # Asserting that each chunks in the selected playlist is seen by the sink
      base_dir = Path.join([Path.dirname(@master_playlist_path), stream_name, "00000"])

      base_dir
      |> File.ls!()
      |> Enum.map(&Path.join([base_dir, &1]))
      |> Enum.map(&File.read!/1)
      |> Enum.each(&assert_sink_buffer(pid, :sink ,%Membrane.Buffer{payload: &1}, 5_000))

      assert_end_of_stream(pid, :sink)
    end
  end
end
