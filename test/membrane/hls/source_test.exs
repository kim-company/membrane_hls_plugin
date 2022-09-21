defmodule Membrane.HLS.SourceTest do
  use ExUnit.Case

  alias Membrane.HLS.Source

  alias HLS.Storage
  alias HLS.Playlist.Master

  import Membrane.Testing.Assertions

  @master_playlist_path "./fixtures/mpeg-ts/stream.m3u8"
  @store Storage.new(%Storage.FS{location: @master_playlist_path})

  defmodule Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(opts = %{storage: storage}) do
      elements = [
        source: %Source{storage: storage}
      ]

      links = []

      spec = %ParentSpec{
        children: elements,
        links: links
      }

      {{:ok, spec: spec, playback: :playing}, opts}
    end

    def handle_notification({:hls_master_playlist, master}, :source, _ctx, state) do
      stream =
        master
        |> Master.variant_streams()
        |> Enum.find(fn x -> state.stream_selector.(x) end)

      case stream do
        nil ->
          {:ok, state}

        stream ->
          elements = [
            sink: Membrane.Testing.Sink
          ]

          links = [
            link(:source)
            |> via_out(Pad.ref(:output, {:rendition, stream}))
            |> to(:sink)
          ]

          spec = %ParentSpec{
            children: elements,
            links: links
          }

          {{:ok, spec: spec}, state}
      end
    end
  end

  describe "hls source" do
    test "uses the selected rendition" do
      options = [
        module: Pipeline,
        custom_args: %{
          storage: @store,
          stream_selector: fn _ -> false end
        }
      ]

      {:ok, pipeline} = Membrane.Testing.Pipeline.start_link(options)
      assert_pipeline_notified(pipeline, :source, {:hls_master_playlist, %Master{}})
      Membrane.Testing.Pipeline.terminate(pipeline, blocking?: true)
    end

    test "provides all segments of selected rendition" do
      stream_name = "stream_416x234"

      options = [
        module: Pipeline,
        custom_args: %{
          storage: @store,
          stream_selector: fn stream -> stream.uri.path == stream_name <> ".m3u8" end
        }
      ]

      {:ok, pipeline} = Membrane.Testing.Pipeline.start_link(options)

      assert_start_of_stream(pipeline, :sink)
      assert_sink_caps(pipeline, :sink, %Membrane.HLS.Format.MPEG{})

      # Asserting that each chunks in the selected playlist is seen by the sink
      base_dir = Path.join([Path.dirname(@master_playlist_path), stream_name, "00000"])

      base_dir
      |> File.ls!()
      |> Enum.map(&Path.join([base_dir, &1]))
      |> Enum.map(&File.read!/1)
      |> Enum.each(&assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: &1}, 5_000))

      assert_end_of_stream(pipeline, :sink)
      Membrane.Testing.Pipeline.terminate(pipeline, blocking?: true)
    end
  end
end
