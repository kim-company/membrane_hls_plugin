defmodule Membrane.HLS.SinkBinGuardrailsTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  @tag :tmp_dir
  test "starts even when no time reference candidates are available", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(6),
        playlist_mode: :vod
      })
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    assert Process.alive?(pipeline)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "ignores sync in VOD mode", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(6),
        playlist_mode: :vod
      })
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    sink_pid = Membrane.Testing.Pipeline.get_child_pid!(pipeline, :sink)
    ref = Process.monitor(sink_pid)

    send(sink_pid, :sync)

    refute_receive {:DOWN, ^ref, :process, ^sink_pid, _reason}, 200

    Process.demonitor(ref, [:flush])
    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  defp build_storage(tmp_dir) do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")
    {manifest_uri, storage}
  end
end
