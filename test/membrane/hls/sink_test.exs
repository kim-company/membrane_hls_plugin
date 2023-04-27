defmodule Membrane.HLS.SinkTest do
  use ExUnit.Case

  alias HLS.Storage
  alias HLS.Playlist.Media

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

  describe "hls sink" do
    test "works with one segment" do
      storage = %Storage{driver: %Support.TestingStorage{owner: self()}}
      playlist_uri = URI.new!("media.m3u8")

      generator = fn state = {buffers_left, _last_pts, _buffer_duration}, size ->
        produce = min(buffers_left, size)

        if produce <= 0 do
          [{:output, :end_of_stream}]
        else
          {buffers, state} =
            Enum.map_reduce(Range.new(1, produce), state, fn _, {buffers_left, from, duration} ->
              {%Membrane.Buffer{
                 pts: from,
                 metadata: %{duration: duration},
                 payload: <<>>
               }, {buffers_left - 1, from + duration, duration}}
            end)

          {[{:buffer, {:output, buffers}}], state}
        end
      end

      target_segment_duration_seconds = 1
      buffer_duration = Membrane.Time.seconds(target_segment_duration_seconds)

      options = [
        module: Pipeline,
        custom_args: %{
          storage: storage,
          playlist: %Media{
            target_segment_duration: target_segment_duration_seconds,
            uri: playlist_uri
          },
          output: {{2, Membrane.Time.seconds(0), buffer_duration}, generator}
        },
        test_process: self()
      ]

      _pipeline = Membrane.Testing.Pipeline.start_link_supervised!(options)
      assert_receive({:put, ^playlist_uri, _data}, 2_000)
      assert_receive({:put, %URI{path: "media/" <> _}, _data}, 2_000)
    end
  end
end
