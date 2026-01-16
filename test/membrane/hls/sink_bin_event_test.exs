defmodule Membrane.HLS.SinkBinEventTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Support.Builder
  alias Membrane.Pad

  require Pad

  defp event_mode do
    {:event, Membrane.Time.seconds(1)}
  end

  @tag :tmp_dir
  test "on a new stream, CMAF", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage, playlist_mode: event_mode())
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_cmaf_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage, playlist_mode: event_mode())
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)
  end

  @tag :tmp_dir
  test "on a new stream, MPEG-TS with AAC", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)

    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    spec =
      manifest_uri
      |> Builder.build_base_spec(storage, playlist_mode: event_mode())
      |> Enum.concat(Builder.build_subtitles_spec())
      |> Enum.concat(Builder.build_full_mpeg_ts_spec())

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)
  end

  @tag :tmp_dir
  test "adds discontinuity after a timing error and keeps program date time", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    buffers = [
      aac_buffer("a", 0),
      aac_buffer("b", 10_000),
      aac_buffer("c", 11_000),
      aac_buffer("d", 11_500)
    ]

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
        target_segment_duration: Membrane.Time.seconds(2),
        playlist_mode: event_mode()
      }),
      child(:source, %Membrane.Testing.Source{
        stream_format: format,
        output: buffers
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
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)

    media_playlists = Builder.load_media_playlists(manifest_uri)

    discontinuity_sequences =
      Enum.map(media_playlists, fn media ->
        segments = Enum.filter(media.segments, & &1.discontinuity)

        assert length(segments) == 1,
               "Each media playlist should contain exactly one EXT-X-DISCONTINUITY"

        hd(segments).absolute_sequence
      end)

    assert Enum.uniq(discontinuity_sequences) |> length() == 1,
           "EXT-X-DISCONTINUITY should be synchronized across media playlists"
  end

  @tag :tmp_dir
  test "skips overlong segments and keeps playlists valid", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    buffers = [
      aac_buffer("a", 0),
      aac_buffer("b", 10_000),
      aac_buffer("c", 11_000),
      aac_buffer("d", 12_000),
      aac_buffer("e", 13_000)
    ]

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
        playlist_mode: event_mode()
      }),
      child(:source, %Membrane.Testing.Source{
        stream_format: format,
        output: buffers
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
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 10_000)
    :ok = Membrane.Pipeline.terminate(pipeline)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    media_playlists = Builder.load_media_playlists(manifest_uri)

    Enum.each(media_playlists, fn media ->
      segments = Enum.filter(media.segments, & &1.discontinuity)
      assert length(segments) >= 1
    end)
  end

  @tag :tmp_dir
  test "writes EVENT playlists while live and only after sync", %{tmp_dir: tmp_dir} do
    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    buffers = [
      aac_buffer("a", 0),
      aac_buffer("b", 1_000),
      aac_buffer("c", 2_000),
      aac_buffer("d", 3_000)
    ]

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
        playlist_mode: event_mode(),
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
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Audio (EN)",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: "2",
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink)
    ]

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)

    refute media_playlist_exists?(tmp_dir),
           "Media playlists should not be written before sync"

    wait_for_segments(tmp_dir, 3, 5_000)

    sink_pid = Membrane.Testing.Pipeline.get_child_pid!(pipeline, :sink)
    send(sink_pid, :sync)
    send(sink_pid, :sync)
    send(sink_pid, :sync)

    wait_for_media_playlist(tmp_dir, 5_000)
    wait_for_master_playlist(tmp_dir, 5_000)
    Builder.assert_event_output(manifest_uri)
    Builder.assert_program_date_time_alignment(manifest_uri, 500)

    :ok = Membrane.Pipeline.terminate(pipeline)
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

  defp media_playlist_exists?(tmp_dir) do
    tmp_dir
    |> Path.join("**/stream_audio_128k.m3u8")
    |> Path.wildcard()
    |> Enum.any?()
  end

  defp wait_for_segments(tmp_dir, count, timeout_ms) do
    wait_until(timeout_ms, fn ->
      tmp_dir
      |> Path.join("**/*.aac")
      |> Path.wildcard()
      |> length()
      |> Kernel.>=(count)
    end)
  end

  defp wait_for_media_playlist(tmp_dir, timeout_ms) do
    wait_until(timeout_ms, fn -> media_playlist_exists?(tmp_dir) end)
  end

  defp wait_for_master_playlist(tmp_dir, timeout_ms) do
    wait_until(timeout_ms, fn ->
      tmp_dir
      |> Path.join("stream.m3u8")
      |> File.exists?()
    end)
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
