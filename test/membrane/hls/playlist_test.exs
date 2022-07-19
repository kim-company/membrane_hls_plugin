defmodule Membrane.HLS.PlaylistTest do
  use ExUnit.Case

  alias Membrane.HLS.Playlist
  alias Membrane.HLS.Playlist.{Master, Media}
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
        resolution: {854, 480},
        frame_rate: 30.0
      ]
      |> Enum.each(fn {key, val} ->
        assert Map.get(stream, key) == val, "expected #{inspect val} on key #{inspect key}"
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

      assert stream.uri == %URI{
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
        assert Map.get(rendition, key) == val, "expected #{inspect val} on key #{inspect key}"
      end)
    end
  end

  describe "Unmarshal Media Playlist" do
    test "fails with empty content" do
      [
        fn -> Playlist.unmarshal("", Media) end,
        fn -> Playlist.unmarshal("some invalid content", Media) end
      ]
      |> Enum.each(fn t -> assert_raise ArgumentError, t end)
    end

    test "collects manifest header" do
      version = 3
      duration = 7
      sequence = 662

      content = """
      #EXTM3U
      #EXT-X-VERSION:#{version}
      #EXT-X-TARGETDURATION:#{duration}
      #EXT-X-MEDIA-SEQUENCE:#{sequence}
      #EXTINF:6.00000,
      a/stream_1280x720/00000/stream_1280x720_00662.ts?t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTgwMjYwMjIsImlhdCI6MTY1Nzk2NzgyMiwiaXNzIjoiY2RwIiwic3ViIjoiZzM5azZLSjNLZ1UwL2Evc3RyZWFtXzEyODB4NzIwIiwidXNlcl9pZCI6IjEiLCJ2aXNpdG9yX2lkIjoiM2FhNjY1MGEtMDRmMy0xMWVkLWIzOGYtMGE1OGE5ZmVhYzAyIn0.DNMBbZPLE0yc0GnGjV5hG_eX_uQ5hzriLk0ZPe8w2AI
      #EXTINF:6.00000,
      a/stream_1280x720/00000/stream_1280x720_00663.ts?t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTgwMjYwMjIsImlhdCI6MTY1Nzk2NzgyMiwiaXNzIjoiY2RwIiwic3ViIjoiZzM5azZLSjNLZ1UwL2Evc3RyZWFtXzEyODB4NzIwIiwidXNlcl9pZCI6IjEiLCJ2aXNpdG9yX2lkIjoiM2FhNjY1MGEtMDRmMy0xMWVkLWIzOGYtMGE1OGE5ZmVhYzAyIn0.DNMBbZPLE0yc0GnGjV5hG_eX_uQ5hzriLk0ZPe8w2AI
      """

      manifest = Playlist.unmarshal(content, Media)
      assert manifest.version == version
      assert manifest.target_segment_duration == duration
      assert manifest.media_sequence_number == sequence
      refute manifest.finished
    end

    test "collects segments" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-TARGETDURATION:3
      #EXT-X-MEDIA-SEQUENCE:0
      #EXTINF:2.020136054,
      audio_segment_0_audio_track.m4s
      #EXTINF:2.020136054,
      audio_segment_1_audio_track.m4s
      #EXTINF:2.020136054,
      audio_segment_2_audio_track.m4s
      #EXTINF:2.020136054,
      audio_segment_3_audio_track.m4s
      #EXTINF:1.95047619,
      audio_segment_4_audio_track.m4s
      """

      manifest = Playlist.unmarshal(content, Media)
      assert Enum.count(Media.segments(manifest)) == 5
    end

    test "detects when track is finished" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-TARGETDURATION:10
      #EXT-X-MEDIA-SEQUENCE:0
      #EXTINF:10.0,
      video_segment_0_video_track.ts
      #EXTINF:2.0,
      video_segment_1_video_track.ts
      #EXT-X-ENDLIST
      """

      manifest = Playlist.unmarshal(content, Media)
      assert manifest.finished
    end

    test "collects segment tags" do
      content = """
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-TARGETDURATION:10
      #EXT-X-MEDIA-SEQUENCE:0
      #EXTINF:9.56,
      video_segment_0_video_track.ts
      #EXTINF:2.020136054,
      a/stream_1280x720_3300k/00000/stream_1280x720_3300k_00522.ts?t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc5MTYzMDEsImlhdCI6MTY1Nzg3MzEwMSwiaXNzIjoiY2RwIiwic3ViIjoiNmhReUhyUGRhRTNuL2Evc3RyZWFtXzEyODB4NzIwXzMzMDBrIiwidXNlcl9pZCI6IjMwNiIsInZpc2l0b3JfaWQiOiJiMGMyMGVkZS0wNDE2LTExZWQtYTYyMS0wYTU4YTlmZWFjMDIifQ.Fj7CADyZeoWtpaqiZLPodNHMWhlGeKjxLwpMR7lygqk
      """

      manifest = Playlist.unmarshal(content, Media)
      last = List.last(Media.segments(manifest))
      assert last.duration == 2.020136054
      assert last.uri.path == "a/stream_1280x720_3300k/00000/stream_1280x720_3300k_00522.ts"
      assert last.uri.query == "t=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2NTc5MTYzMDEsImlhdCI6MTY1Nzg3MzEwMSwiaXNzIjoiY2RwIiwic3ViIjoiNmhReUhyUGRhRTNuL2Evc3RyZWFtXzEyODB4NzIwXzMzMDBrIiwidXNlcl9pZCI6IjMwNiIsInZpc2l0b3JfaWQiOiJiMGMyMGVkZS0wNDE2LTExZWQtYTYyMS0wYTU4YTlmZWFjMDIifQ.Fj7CADyZeoWtpaqiZLPodNHMWhlGeKjxLwpMR7lygqk"
    end
  end
end
