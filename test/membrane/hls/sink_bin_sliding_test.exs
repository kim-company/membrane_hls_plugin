defmodule Membrane.HLS.SinkBinSlidingTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.Pad
  alias Support.Builder

  require Pad

  defp sliding_mode do
    {:sliding, 2, Membrane.Time.seconds(1)}
  end

  defp send_syncs(pipeline, count) do
    sink_pid = Membrane.Testing.Pipeline.get_child_pid!(pipeline, :sink)
    Enum.each(1..count, fn _ -> send(sink_pid, :sync) end)
  end

  @tag :tmp_dir
  test "on a new stream, CMAF", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage,
        playlist_mode: sliding_mode(),
        target_segment_duration: Membrane.Time.seconds(8),
        flush_on_end: false
      )
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_cmaf_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, false}, 10_000)
    wait_for_segments(tmp_dir, 3, [".m4s"], 5_000)
    send_syncs(pipeline, 3)
    wait_for_master_playlist(tmp_dir, 5_000)

    Builder.assert_hls_output(manifest_uri)
    Builder.assert_program_date_time_alignment(manifest_uri, 2_500)
    assert_sliding_window(manifest_uri, 2)

    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage,
        playlist_mode: sliding_mode(),
        target_segment_duration: Membrane.Time.seconds(8),
        flush_on_end: false
      )
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, false}, 10_000)
    wait_for_segments(tmp_dir, 3, [".ts", ".aac"], 5_000)
    send_syncs(pipeline, 3)
    wait_for_master_playlist(tmp_dir, 5_000)

    Builder.assert_hls_output(manifest_uri)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)
    assert_sliding_window(manifest_uri, 2)

    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS with AAC", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage,
        playlist_mode: sliding_mode(),
        target_segment_duration: Membrane.Time.seconds(8),
        flush_on_end: false
      )
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_full_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, false}, 10_000)
    wait_for_segments(tmp_dir, 3, [".ts"], 5_000)
    send_syncs(pipeline, 3)
    wait_for_master_playlist(tmp_dir, 5_000)

    Builder.assert_hls_output(manifest_uri)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)
    assert_sliding_window(manifest_uri, 2)

    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  @tag :tmp_dir
  test "keeps a rolling window for audio-only stream", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    buffers =
      for idx <- 0..5 do
        aac_buffer("chunk#{idx}", idx * 1_000)
      end

    format = %Membrane.AAC{
      profile: :LC,
      sample_rate: 48_000,
      channels: 2,
      mpeg_version: 4
    }

    spec = [
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(1),
        playlist_mode: sliding_mode(),
        flush_on_end: false
      }),
      child(:source, %Membrane.Testing.Source{
        stream_format: format,
        output: {buffers, &stream_without_eos/2}
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          container: :PACKED_AAC,
          segment_duration: Membrane.Time.seconds(1),
          build_stream: fn _format ->
            %HLS.VariantStream{
              uri: nil,
              bandwidth: 128_000,
              codecs: ["mp4a.40.2"]
            }
          end
        ]
      )
      |> get_child(:sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    wait_for_segments(tmp_dir, 3, [".aac"], 5_000)

    sink_pid = Membrane.Testing.Pipeline.get_child_pid!(pipeline, :sink)
    send(sink_pid, :sync)
    send(sink_pid, :sync)
    send(sink_pid, :sync)

    wait_for_media_playlist(tmp_dir, 5_000)
    wait_for_master_playlist(tmp_dir, 5_000)

    [media] = Builder.load_media_playlists(manifest_uri)

    assert length(media.segments) <= 2, "Media playlist should keep rolling window"

    Enum.each(media.segments, fn segment ->
      assert segment.program_date_time != nil,
             "Segment should include EXT-X-PROGRAM-DATE-TIME"

      assert segment_file_exists?(tmp_dir, segment.uri),
             "Segment file should exist for #{inspect(segment.uri)}"
    end)

    Builder.assert_program_date_time_alignment(manifest_uri, 500)
    assert_sliding_window(manifest_uri, 2)

    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  defp assert_sliding_window(manifest_uri, max_segments) do
    Builder.load_media_playlists(manifest_uri)
    |> Enum.each(fn media ->
      assert media.finished == false, "Sliding playlists should not be finished"
      assert length(media.segments) <= max_segments, "Sliding window exceeded max segments"

      case media.segments do
        [] ->
          :ok

        [first | rest] ->
          last_sequence = media.media_sequence_number + length(media.segments) - 1
          assert first.absolute_sequence == media.media_sequence_number

          Enum.reduce(rest, first.absolute_sequence, fn segment, prev ->
            assert segment.absolute_sequence == prev + 1
            segment.absolute_sequence
          end)

          assert media.media_sequence_number <= last_sequence
      end
    end)
  end

  defp aac_buffer(payload, pts_ms) do
    %Membrane.Buffer{
      payload: payload,
      pts: Membrane.Time.milliseconds(pts_ms)
    }
  end

  defp stream_without_eos(state, size) do
    {buffers, rest} = Enum.split(state, size)
    actions = if buffers == [], do: [], else: [buffer: {:output, buffers}]
    {actions, rest}
  end

  defp wait_for_segments(tmp_dir, count, extensions, timeout_ms) do
    wait_until(timeout_ms, fn -> count_segment_files(tmp_dir, extensions) >= count end)
  end

  defp wait_for_media_playlist(tmp_dir, timeout_ms) do
    wait_until(timeout_ms, fn ->
      tmp_dir
      |> Path.join("**/stream_audio_128k.m3u8")
      |> Path.wildcard()
      |> Enum.any?()
    end)
  end

  defp wait_for_master_playlist(tmp_dir, timeout_ms) do
    wait_until(timeout_ms, fn ->
      tmp_dir
      |> Path.join("stream.m3u8")
      |> File.exists?()
    end)
  end

  defp count_segment_files(tmp_dir, extensions) do
    extensions
    |> Enum.flat_map(fn ext ->
      trimmed = String.trim_leading(ext, ".")
      Path.wildcard(Path.join(tmp_dir, "**/*.#{trimmed}"))
    end)
    |> length()
  end

  defp segment_file_exists?(tmp_dir, uri) do
    path =
      case uri do
        %URI{path: uri_path} -> uri_path
        uri_path when is_binary(uri_path) -> uri_path
      end

    full_path =
      if String.starts_with?(path, "/") do
        path
      else
        Path.join(tmp_dir, path)
      end

    File.exists?(full_path)
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.reduce_while(:timeout, fn ready?, _acc ->
      cond do
        ready? -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> {:halt, :timeout}
        true ->
          Process.sleep(50)
          {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Timed out waiting for condition")
    end
  end
end
