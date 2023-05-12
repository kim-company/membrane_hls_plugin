defmodule Membrane.HLS.SinkTest do
  use ExUnit.Case
  use Membrane.Pipeline

  alias HLS.Playlist.Media
  alias Membrane.Buffer
  import Membrane.Testing.Assertions

  describe "hls sink" do
    test "handles one segment" do
      playlist_uri = URI.new!("s3://bucket/media.m3u8")

      playlist = Media.new(playlist_uri, 1)

      buffers = [
        %Buffer{
          payload: "a",
          pts: 0,
          metadata: %{duration: Membrane.Time.milliseconds(1_500)}
        }
      ]

      links = [
        child(:source, %Membrane.Testing.Source{
          output: Membrane.Testing.Source.output_from_buffers(buffers),
          stream_format: %Membrane.HLS.Format.WebVTT{language: "en-US"}
        })
        |> child(:sink, %Membrane.HLS.Sink{
          playlist: playlist
        })
      ]

      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(structure: links)

      segment_uri = URI.new!("s3://bucket/media/00000.vtt")

      assert_pipeline_notified(
        pipeline,
        :sink,
        {:write,
         %{
           uri: ^segment_uri,
           buffers: [%Membrane.Buffer{payload: "a"}],
           type: :segment,
           format: %Membrane.HLS.Format.WebVTT{},
           segment: %{from: 0, to: 1}
         }},
        1_000
      )

      # This comes as soon as segments are complete; in this case "a" lasts for
      # the whole duration of the first segment and finishes in the second.
      assert_pipeline_notified(
        pipeline,
        :sink,
        {:write, %{type: :playlist, uri: ^playlist_uri, playlist: %Media{finished: false}}},
        1_000
      )

      # Assertion on end-of-stream
      assert_pipeline_notified(
        pipeline,
        :sink,
        {:write, %{type: :playlist, uri: ^playlist_uri, playlist: %Media{finished: true}}},
        1_000
      )

      refute_pipeline_notified(pipeline, :sink, {:write, %{type: :segment}}, 1_000)
      refute_pipeline_notified(pipeline, :sink, {:write, %{type: :playlist}}, 1_000)
      assert_end_of_stream(pipeline, :sink, :input, 1_000)

      :ok = Membrane.Pipeline.terminate(pipeline, blocking?: true)
    end
  end
end
