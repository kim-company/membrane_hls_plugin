defmodule Membrane.HLS.SinkBinVODTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Support.Builder

  @tag :tmp_dir
  test "on a new stream, CMAF", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage)
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_cmaf_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    # Validate the generated HLS output
    Builder.assert_hls_output(manifest_uri)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage)
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    # Validate the generated HLS output
    Builder.assert_hls_output(manifest_uri)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS with AAC", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage)
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_full_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    # Validate the generated HLS output
    Builder.assert_hls_output(manifest_uri)
  end
end
