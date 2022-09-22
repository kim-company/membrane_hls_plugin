# This example tracks a playlist and logs a message each time a segment is
# received.
Mix.install([
  {:membrane_hls_plugin, path: "."}
])

defmodule Main do
  require Logger

  def logger(tracker, target) do
    ref = HLS.Playlist.Media.Tracker.follow(tracker, target)
    loop(ref)
  end

  def loop(ref) do
    receive do
      {:segment, ^ref, segment} ->
        Logger.info([segment: segment])
        loop(ref)
      other ->
        Logger.warn("Unrecognized message received: #{inspect other}")
        loop(ref)
    end
  end

  def run(playlist) do
    storage = HLS.Storage.new(playlist)

    rendition =
      storage
      |> HLS.Storage.get_master_playlist!()
      |> HLS.Playlist.Master.variant_streams()
      |> Enum.sort(fn left, right -> left.bandwidth < right.bandwidth end)
      |> List.first()

    {:ok, tracker} = HLS.Playlist.Media.Tracker.start_link(storage)
    logger = spawn_link(fn -> logger(tracker, rendition.uri) end)
    {:ok, tracker, logger}
  end
end

url = List.first(System.argv)
if url == nil do
  raise "Provide a valid m3u8 master playlist URI as first parameter"
end

Main.run(url)
Process.sleep(:infinity)
