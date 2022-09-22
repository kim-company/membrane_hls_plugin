defmodule HLS.Playlist.Media.TrackerTest do
  use ExUnit.Case

  alias HLS.Playlist.Media.Tracker
  alias HLS.Segment
  alias HLS.Storage
  alias HLS.Storage.FS

  @master_playlist_path "./fixtures/mpeg-ts/stream.m3u8"
  @store Storage.new(%FS{location: @master_playlist_path})

  defmodule OneMoreMediaStorage do
    @behaviour HLS.Storage

    @media_track_path "one_more.m3u8"

    defstruct [:initial, max: 1, target_duration: 1]

    @impl true
    def init(config) do
      {:ok, pid} =
        Agent.start(fn ->
          %{
            initial: config.initial,
            max: config.max,
            calls: 0,
            target_duration: config.target_duration
          }
        end)

      pid
    end

    @impl true
    def get(_) do
      {:ok,
       """
       #EXTM3U
       #EXT-X-VERSION:7
       #EXT-X-INDEPENDENT-SEGMENTS
       #EXT-X-STREAM-INF:BANDWIDTH=725435,CODECS="avc1.42e00a"
       #{@media_track_path}
       """}
    end

    @impl true
    def get(pid, %URI{path: @media_track_path}) do
      config =
        Agent.get_and_update(pid, fn state ->
          {state, %{state | calls: state.calls + 1}}
        end)

      header = """
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-TARGETDURATION:#{config.target_duration}
      #EXT-X-MEDIA-SEQUENCE:0
      """

      calls = config.calls

      segs =
        Enum.map(Range.new(0, calls + config.initial), fn seq ->
          """
          #EXTINF:0.89,
          video_segment_#{seq}_video_720x480.ts
          """
        end)

      tail =
        if calls == config.max do
          "#EXT-X-ENDLIST"
        else
          ""
        end

      {:ok, Enum.join([header] ++ segs ++ [tail], "\n")}
    end
  end

  describe "tracker process" do
    test "starts and exits on demand" do
      assert {:ok, pid} = Tracker.start_link(@store)
      assert Process.alive?(pid)
      assert :ok = Tracker.stop(pid)
    end

    test "sends one message for each segment in a static track" do
      {:ok, pid} = Tracker.start_link(@store)
      ref = Tracker.follow(pid, URI.parse("stream_416x234.m3u8"))

      # sequence goes from 1 to 5 as the target playlist starts with a media
      # sequence number of 1.
      Enum.each(1..5, fn seq ->
        assert_receive {:segment, ^ref, %Segment{absolute_sequence: ^seq}}, 1000
      end)

      refute_received {:segment, ^ref, _}, 1000

      :ok = Tracker.stop(pid)
    end

    #
    test "sends start of track message identifing first sequence number" do
      {:ok, pid} = Tracker.start_link(@store)
      ref = Tracker.follow(pid, URI.parse("stream_416x234.m3u8"))

      assert_receive {:start_of_track, ^ref, 1}, 1000

      :ok = Tracker.stop(pid)
    end

    test "sends track termination message when track is finished" do
      {:ok, pid} = Tracker.start_link(@store)
      ref = Tracker.follow(pid, URI.parse("stream_416x234.m3u8"))

      assert_receive {:end_of_track, ^ref}, 1000

      :ok = Tracker.stop(pid)
    end

    test "keeps on sending updates when the playlist does" do
      store = Storage.new(%OneMoreMediaStorage{initial: 1, target_duration: 1})
      {:ok, pid} = Tracker.start_link(store)
      ref = Tracker.follow(pid, URI.parse("one_more.m3u8"))

      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 0}}, 200
      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 1}}, 200

      # The tracker should wait `target_duration` seconds, reload the track
      # afterwards and detect that one more segment has been provied, together
      # with the termination tag.

      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 2}}, 2000
      refute_received {:segment, ^ref, _}, 2000
      assert_receive {:end_of_track, ^ref}, 2000

      :ok = Tracker.stop(pid)
    end

    test "when the playlist is not finished, it does not deliver more than 3 packets at first" do
      store = Storage.new(%OneMoreMediaStorage{initial: 4, target_duration: 1})
      {:ok, pid} = Tracker.start_link(store)
      ref = Tracker.follow(pid, URI.parse("one_more.m3u8"))

      assert_receive {:start_of_track, ^ref, 2}, 200

      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 2}}, 200
      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 3}}, 200
      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 4}}, 200

      assert_receive {:segment, ^ref, %Segment{absolute_sequence: 5}}, 2000

      refute_received {:segment, ^ref, _}, 2000
      assert_receive {:end_of_track, ^ref}, 2000

      :ok = Tracker.stop(pid)
    end

    test "when playlist adds multiple segments, they are retriven in order" do
    end
  end
end
