defmodule Membrane.HLS.SinkTest do
  use ExUnit.Case

  alias HLS.Storage
  alias HLS.Playlist.Media
  alias Membrane.Buffer
  alias HLS.Playlist

  defmodule Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, %{
          storage: storage,
          playlist: playlist,
          output: output
        }) do
      structure = [
        child(:source, %Membrane.Testing.Source{
          output: output,
          stream_format: %Membrane.HLS.Format.WebVTT{language: "en-US"}
        })
        |> child(:sink, %Membrane.HLS.Sink{
          storage: storage,
          playlist: playlist
        })
      ]

      {[{:spec, structure}, {:playback, :playing}], %{}}
    end
  end

  def buffer_generator(buffers, size) do
    {buffers, rest} = Enum.split(buffers, size)

    if Enum.empty?(buffers) do
      {[end_of_stream: :output], rest}
    else
      buffer_actions = [buffer: {:output, buffers}]

      actions =
        if Enum.empty?(rest) do
          buffer_actions ++ [end_of_stream: :output]
        else
          buffer_actions
        end

      {actions, rest}
    end
  end

  describe "hls sink" do
    test "works with one segment" do
      storage = %Storage{driver: %Support.TestingStorage{owner: self()}}
      playlist_uri = URI.new!("s3://bucket/media.m3u8")

      options = [
        module: Pipeline,
        custom_args: %{
          storage: storage,
          playlist: %Media{
            target_segment_duration: 1,
            uri: playlist_uri
          },
          output:
            {[
               %Buffer{
                 payload: "a",
                 pts: 0,
                 metadata: %{duration: Membrane.Time.milliseconds(1_500)}
               }
             ], &__MODULE__.buffer_generator/2}
        },
        test_process: self()
      ]

      _pipeline = Membrane.Testing.Pipeline.start_link_supervised!(options)

      assert_receive({:put, ^playlist_uri, _data}, 1_000)
      segment_uri = URI.new!("s3://bucket/media/00000.vtt")
      assert_receive({:put, ^segment_uri, "a"}, 1_000)

      # Assertion on end-of-stream
      assert_receive({:put, ^playlist_uri, payload}, 1_000)
      playlist = %Media{}
      assert %Media{finished: true} = Playlist.unmarshal(payload, playlist)
    end
  end
end
