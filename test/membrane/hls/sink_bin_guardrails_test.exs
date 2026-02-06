defmodule Membrane.HLS.SinkBinGuardrailsTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  alias Membrane.Pad

  require Pad

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

  @tag :tmp_dir
  test "trim alignment requires parsed H264 input", %{tmp_dir: tmp_dir} do
    {manifest_uri, storage} = build_storage(tmp_dir)

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(1),
        playlist_mode: :vod,
        trim_align?: true
      }),
      child(:source, %Membrane.Testing.Source{
        stream_format: %Membrane.H264{alignment: :nalu, nalu_in_metadata?: false},
        output: [%Membrane.Buffer{payload: <<1, 2, 3>>, pts: Membrane.Time.seconds(0)}]
      })
      |> via_in(Pad.ref(:input, "video"),
        options: [
          encoding: :H264,
          container: :TS,
          segment_duration: Membrane.Time.seconds(1),
          build_stream: fn _format ->
            %HLS.VariantStream{uri: nil, bandwidth: 900_000, codecs: ["avc1.64001f"]}
          end
        ]
      )
      |> get_child(:sink)
    ]

    Process.flag(:trap_exit, true)
    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    assert_receive {:EXIT, ^pipeline, {:membrane_child_crash, :sink, _}}, 2_000
  end

  defp build_storage(tmp_dir) do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")
    {manifest_uri, storage}
  end
end
