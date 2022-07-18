defmodule Membrane.HLS.PlaylistTest do
  use ExUnit.Case

  alias Membrane.HLS.Playlist
  alias Membrane.HLS.Playlist.Master
  alias Membrane.HLS.VariantStream
  alias Membrane.HLS.AlternativeRendition

  describe "Unmarshal Master Playlist" do
    test "fails with empty content" do
      [
        fn -> Playlist.unmarshal("", Master) end,
        fn -> Playlist.unmarshal("some invalid content", Master) end
      ]
      |> Enum.each(fn t -> assert_raise ArgumentError, t end)
    end

    test "parses manifest version" do
      version = 3

      content = """
      #EXTM3U
      #EXT-X-VERSION:#{version}
      """

      manifest = Playlist.unmarshal(content, Master)
      assert manifest.version == version
    end

    test "collects all variant streams" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-STREAM-INF:BANDWIDTH=1187651,CODECS="avc1.42e00a"
      muxed_video_480x270.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=609514,CODECS="avc1.42e00a"
      muxed_video_540x360.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=863865,CODECS="avc1.42e00a"
      muxed_video_720x480.m3u8
      """

      manifest = Playlist.unmarshal(content, Master)
      assert Enum.count(Master.variant_streams(manifest)) == 3
    end

    test "collects variant stream configuration" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:3
      #EXT-X-STREAM-INF:BANDWIDTH=1478400,AVERAGE-BANDWIDTH=1425600,CODECS="avc1.4d4029,mp4a.40.2",RESOLUTION=854x480,FRAME-RATE=30.000
      stream_854x480.m3u8
      """

      manifest = Playlist.unmarshal(content, Master)
      assert %VariantStream{} = stream = List.first(Master.variant_streams(manifest))

      [
        uri: %URI{path: "stream_854x480.m3u8"},
        bandwidth: 1_478_400,
        average_bandwidth: 1_425_600,
        codecs: ["avc1.4d4029", "mp4a.40.2"],
        resolution: [416, 234],
        frame_rate: 30.0
      ]
      |> Enum.each(fn {key, val} ->
        assert Map.get(stream, key, val) == val
      end)
    end

    test "handels complex uri specifications" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:3
      #EXT-X-STREAM-INF:BANDWIDTH=1478400,AVERAGE-BANDWIDTH=1425600,CODECS="avc1.4d4029,mp4a.40.2",RESOLUTION=854x480,FRAME-RATE=30.000
      stream_with_token.m3u8?t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc5MTYzMDcsImlhdCI6MTY1Nzg3MzEwNywiaXNzIjoiY2RwIiwia2VlcF9zZWdtZW50cyI6bnVsbCwia2luZCI6ImNoaWxkIiwicGFyZW50IjoiNmhReUhyUGRhRTNuL3N0cmVhbS5tM3U4Iiwic3ViIjoiNmhReUhyUGRhRTNuL3N0cmVhbV82NDB4MzYwXzgwMGsubTN1OCIsInRyaW1fZnJvbSI6NTIxLCJ0cmltX3RvIjpudWxsLCJ1c2VyX2lkIjoiMzA2IiwidXVpZCI6bnVsbCwidmlzaXRvcl9pZCI6ImI0NGFlZjYyLTA0MTYtMTFlZC04NTRmLTBhNThhOWZlYWMwMiJ9.eVrBzEBbjHxDcg6xnZXfXy0ZoNoj_seaZwaja_WDwuc
      """

      manifest = Playlist.unmarshal(content, Master)
      stream = List.first(Master.variant_streams(manifest))

      assert stream.attributes.uri == %URI{
               path: "stream_with_token.m3u8",
               query:
                 "t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc5MTYzMDcsImlhdCI6MTY1Nzg3MzEwNywiaXNzIjoiY2RwIiwia2VlcF9zZWdtZW50cyI6bnVsbCwia2luZCI6ImNoaWxkIiwicGFyZW50IjoiNmhReUhyUGRhRTNuL3N0cmVhbS5tM3U4Iiwic3ViIjoiNmhReUhyUGRhRTNuL3N0cmVhbV82NDB4MzYwXzgwMGsubTN1OCIsInRyaW1fZnJvbSI6NTIxLCJ0cmltX3RvIjpudWxsLCJ1c2VyX2lkIjoiMzA2IiwidXVpZCI6bnVsbCwidmlzaXRvcl9pZCI6ImI0NGFlZjYyLTA0MTYtMTFlZC04NTRmLTBhNThhOWZlYWMwMiJ9.eVrBzEBbjHxDcg6xnZXfXy0ZoNoj_seaZwaja_WDwuc"
             }
    end

    test "collects and aggregates alternative subtitle rendition" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:3
      #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",NAME="German (Germany)",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,LANGUAGE="de-DE",URI="subtitles.m3u8?t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc5MTY0MjYsImlhdCI6MTY1Nzg3MzIyNiwiaXNzIjoiY2RwIiwia2VlcF9zZWdtZW50cyI6bnVsbCwia2luZCI6ImNoaWxkIiwicGFyZW50IjoiNmhReUhyUGRhRTNuL3N0cmVhbS5tM3U4Iiwic3ViIjoiNmhReUhyUGRhRTNuL3N1YnRpdGxlcy5tM3U4IiwidHJpbV9mcm9tIjo1MjEsInRyaW1fdG8iOm51bGwsInVzZXJfaWQiOiIzMDYiLCJ1dWlkIjpudWxsLCJ2aXNpdG9yX2lkIjoiZmI0NDRlYjgtMDQxNi0xMWVkLTgxODAtMGE1OGE5ZmVhYzAyIn0.hZBdfremVP_T7XRcVLz-vmDfgyP_sXZhyK_liv4ekho"
      #EXT-X-STREAM-INF:BANDWIDTH=299147,AVERAGE-BANDWIDTH=290400,CODECS="avc1.66.30,mp4a.40.2",RESOLUTION=416x234,FRAME-RATE=14.985,AUDIO="PROGRAM_AUDIO",SUBTITLES="subtitles"
      stream_854x480.m3u8
      """

      manifest = Playlist.unmarshal(content, Master)
      stream = List.first(Master.variant_streams(manifest))

      assert [%AlternativeRendition{} = rendition] =
               VariantStream.alternative_renditions(stream, :subtitles)

      [
        group_id: "subtitles",
        name: "German (Germany)",
        default: false,
        autoselect: false,
        forced: false,
        language: "de-DE",
        uri: %URI{
          path: "subtitles.m3u8",
          query:
            "t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc5MTY0MjYsImlhdCI6MTY1Nzg3MzIyNiwiaXNzIjoiY2RwIiwia2VlcF9zZWdtZW50cyI6bnVsbCwia2luZCI6ImNoaWxkIiwicGFyZW50IjoiNmhReUhyUGRhRTNuL3N0cmVhbS5tM3U4Iiwic3ViIjoiNmhReUhyUGRhRTNuL3N1YnRpdGxlcy5tM3U4IiwidHJpbV9mcm9tIjo1MjEsInRyaW1fdG8iOm51bGwsInVzZXJfaWQiOiIzMDYiLCJ1dWlkIjpudWxsLCJ2aXNpdG9yX2lkIjoiZmI0NDRlYjgtMDQxNi0xMWVkLTgxODAtMGE1OGE5ZmVhYzAyIn0.hZBdfremVP_T7XRcVLz-vmDfgyP_sXZhyK_liv4ekho"
        }
      ]
      |> Enum.each(fn {key, val} ->
        assert Map.get(rendition.attributes, key, val) == val
      end)
    end
  end
end
