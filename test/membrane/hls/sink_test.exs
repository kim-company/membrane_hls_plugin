defmodule Membrane.HLS.SinkTest do
  use ExUnit.Case
  use Membrane.Pipeline

  alias HLS.Playlist.Media
  alias Membrane.Buffer
  import Membrane.Testing.Assertions

  defp build_links(playlist, writer, buffers) do
    [
      child(:source, %Membrane.Testing.Source{
        output: Membrane.Testing.Source.output_from_buffers(buffers),
        stream_format: %Membrane.HLS.Format.WebVTT{language: "en-US"}
      })
      |> child(:sink, %Membrane.HLS.Sink{
        playlist: playlist,
        writer: writer,
        formatter: %Support.SegmentFormatter{}
      })
    ]
  end

  setup do
    %{
      playlist: Media.new(URI.new!("s3://bucket/media.m3u8"), 1),
      writer: Support.Writer.new()
    }
  end

  describe "hls sink" do
    test "handles one segment starting from an empty playlist", %{
      playlist: playlist,
      writer: writer
    } do
      buffers = [
        %Buffer{
          payload: "a",
          pts: 0,
          # this payload covers the whole segment.
          metadata: %{duration: Membrane.Time.seconds(1)}
        }
      ]

      links = build_links(playlist, writer, buffers)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(structure: links)

      assert_end_of_stream(pipeline, :sink, :input, 200)
      :ok = Membrane.Pipeline.terminate(pipeline, blocking?: true)

      assert [
               {URI.new!("s3://bucket/media/00000.txt"), "a"},
               {URI.new!("s3://bucket/media.m3u8"),
                "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nmedia/00000.txt\n"}
             ] == Support.Writer.history(writer)
    end

    test "writes pending segments at EOS", %{playlist: playlist, writer: writer} do
      buffers = [
        %Buffer{
          payload: "a",
          pts: 0,
          metadata: %{duration: Membrane.Time.milliseconds(50)}
        }
      ]

      links = build_links(playlist, writer, buffers)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(structure: links)

      assert_end_of_stream(pipeline, :sink, :input, 200)
      :ok = Membrane.Pipeline.terminate(pipeline, blocking?: true)

      assert [
               {URI.new!("s3://bucket/media/00000.txt"), "a"},
               {URI.new!("s3://bucket/media.m3u8"),
                "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nmedia/00000.txt\n"}
             ] == Support.Writer.history(writer)
    end

    test "in case of failure an empty segment replaces the failing upload", %{playlist: playlist} do
      writer = Support.Writer.new(fail: true)

      buffers = [
        %Buffer{
          payload: "a",
          pts: 0,
          metadata: %{duration: Membrane.Time.seconds(1)}
        }
      ]

      links = build_links(playlist, writer, buffers)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(structure: links)

      assert_end_of_stream(pipeline, :sink, :input, 200)
      :ok = Membrane.Pipeline.terminate(pipeline, blocking?: true)

      assert [
               {URI.new!("s3://bucket/media/00000.txt"), "a"},
               {URI.new!("s3://bucket/media.m3u8"),
                "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nmedia/empty.txt\n"}
             ] == Support.Writer.history(writer)
    end

    test "empty buffers are replaced with the empty segment", %{
      playlist: playlist,
      writer: writer
    } do
      buffers = [
        %Buffer{
          payload: <<>>,
          pts: 0,
          metadata: %{duration: Membrane.Time.seconds(1)}
        }
      ]

      links = build_links(playlist, writer, buffers)
      pipeline = Membrane.Testing.Pipeline.start_link_supervised!(structure: links)

      assert_end_of_stream(pipeline, :sink, :input, 200)
      :ok = Membrane.Pipeline.terminate(pipeline, blocking?: true)

      assert [
               {URI.new!("s3://bucket/media/empty.txt"), ""},
               {URI.new!("s3://bucket/media.m3u8"),
                "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nmedia/empty.txt\n"}
             ] == Support.Writer.history(writer)
    end
  end
end
