defmodule Membrane.HLS.SinkBinEventTrimAlignTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Pad
  alias Support.Builder

  require Pad

  defmodule BufferDropper do
    use Membrane.Filter

    alias Membrane.Buffer

    def_options(
      drop_before: [spec: Membrane.Time.t(), default: 0],
      drop_first_keyframe?: [spec: boolean(), default: false]
    )

    def_input_pad(:input, accepted_format: _any, flow_control: :auto)
    def_output_pad(:output, accepted_format: _any, flow_control: :auto)

    @impl true
    def handle_init(_ctx, opts) do
      {[],
       %{
         drop_before: opts.drop_before,
         drop_first_keyframe?: opts.drop_first_keyframe?,
         dropped_keyframe?: false
       }}
    end

    @impl true
    def handle_stream_format(:input, format, _ctx, state) do
      {[stream_format: {:output, format}], state}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      ts = Buffer.get_dts_or_pts(buffer) || 0

      cond do
        ts < state.drop_before ->
          {[], state}

        state.drop_first_keyframe? and not state.dropped_keyframe? and keyframe?(buffer) ->
          {[], %{state | dropped_keyframe?: true}}

        true ->
          {[buffer: {:output, buffer}], state}
      end
    end

    defp keyframe?(%Buffer{metadata: %{h264: %{key_frame?: true}}}), do: true
    defp keyframe?(_buffer), do: false
  end

  @tag :tmp_dir
  test "event: audio+subtitles in sync, video comes late", %{tmp_dir: tmp_dir} do
    {manifest_uri, spec} =
      build_spec(tmp_dir,
        include_subtitles?: true,
        video_drop_before: Membrane.Time.seconds(2)
      )

    run_pipeline(spec)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 700)

    media_playlists = Builder.load_media_playlists(manifest_uri)
    assert length(media_playlists) == 3
    assert_first_segment_sequence_aligned(media_playlists)
  end

  @tag :tmp_dir
  test "event: video starts on non-keyframe, next keyframe is used and others align", %{
    tmp_dir: tmp_dir
  } do
    {manifest_uri, spec} =
      build_spec(tmp_dir,
        include_subtitles?: true,
        drop_first_video_keyframe?: true
      )

    run_pipeline(spec)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 700)

    media_playlists = Builder.load_media_playlists(manifest_uri)
    assert length(media_playlists) == 3
    assert_first_segment_sequence_aligned(media_playlists)
  end

  @tag :tmp_dir
  test "event: audio earlier than video", %{tmp_dir: tmp_dir} do
    {manifest_uri, spec} =
      build_spec(tmp_dir,
        include_subtitles?: false,
        video_drop_before: Membrane.Time.milliseconds(1_500)
      )

    run_pipeline(spec)

    Builder.assert_event_output(manifest_uri, allow_vod: true)
    Builder.assert_program_date_time_alignment(manifest_uri, 700)

    media_playlists = Builder.load_media_playlists(manifest_uri)
    assert length(media_playlists) == 2
    assert_first_segment_sequence_aligned(media_playlists)
  end

  defp build_spec(tmp_dir, opts) do
    include_subtitles? = Keyword.get(opts, :include_subtitles?, false)
    video_drop_before = Keyword.get(opts, :video_drop_before, 0)
    drop_first_video_keyframe? = Keyword.get(opts, :drop_first_video_keyframe?, false)

    storage = HLS.Storage.File.new(base_dir: tmp_dir)
    manifest_uri = URI.new!("file://#{tmp_dir}/stream.m3u8")

    sink =
      child(:sink, %Membrane.HLS.SinkBin{
        storage: storage,
        manifest_uri: manifest_uri,
        target_segment_duration: Membrane.Time.seconds(8),
        playlist_mode: {:event, Membrane.Time.seconds(1)},
        trim_align?: true,
        trim_align_max_leading_trim: Membrane.Time.seconds(12)
      })

    av_source =
      child(:source, %Membrane.File.Source{location: Builder.avsync_fixture()})
      |> child(:demuxer, Membrane.MPEG.TS.Demuxer)

    audio =
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :audio])
      |> child(:aac_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :esds
      })
      |> via_in(Pad.ref(:input, "audio_128k"),
        options: [
          encoding: :AAC,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            %HLS.AlternativeRendition{
              uri: nil,
              name: "Audio (EN)",
              type: :audio,
              group_id: "audio",
              language: "en",
              channels: to_string(format.codecs.mp4a.channels),
              default: true,
              autoselect: true
            }
          end
        ]
      )
      |> get_child(:sink)

    video =
      get_child(:demuxer)
      |> via_out(:output, options: [stream_category: :video])
      |> child(:h264_parser, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        output_alignment: :au,
        skip_until_keyframe: false
      })
      |> child(:video_dropper, %BufferDropper{
        drop_before: video_drop_before,
        drop_first_keyframe?: drop_first_video_keyframe?
      })
      |> via_in(Pad.ref(:input, "video_460x720"),
        options: [
          encoding: :H264,
          segment_duration: Membrane.Time.seconds(6),
          build_stream: fn %Membrane.CMAF.Track{} = format ->
            base_stream = %HLS.VariantStream{
              uri: nil,
              resolution: format.resolution,
              frame_rate: 30.0,
              audio: "audio"
            }

            if include_subtitles? do
              %{base_stream | subtitles: "subtitles"}
            else
              base_stream
            end
          end
        ]
      )
      |> get_child(:sink)

    subtitles =
      if include_subtitles? do
        [
          child(:text_source, %Membrane.Testing.Source{
            stream_format: %Membrane.Text{},
            output: text_buffers()
          })
          |> via_in(Pad.ref(:input, "subtitles"),
            options: [
              encoding: :TEXT,
              segment_duration: Membrane.Time.seconds(6),
              subtitle_min_duration: Membrane.Time.milliseconds(200),
              build_stream: fn %Membrane.Text{} ->
                %HLS.AlternativeRendition{
                  uri: nil,
                  name: "Subtitles (EN)",
                  type: :subtitles,
                  group_id: "subtitles",
                  language: "en",
                  default: true,
                  autoselect: true
                }
              end
            ]
          )
          |> get_child(:sink)
        ]
      else
        []
      end

    spec = [sink, av_source, audio, video] ++ subtitles

    {manifest_uri, spec}
  end

  defp run_pipeline(spec) do
    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :sink, {:end_of_stream, true}, 15_000)
    :ok = Membrane.Pipeline.terminate(pipeline)
  end

  defp text_buffers do
    0..40
    |> Enum.map(fn idx ->
      from = idx * 500
      to = from + 500

      %Membrane.Buffer{
        payload: "cue_#{idx}",
        pts: Membrane.Time.milliseconds(from),
        metadata: %{to: Membrane.Time.milliseconds(to)}
      }
    end)
  end

  defp assert_first_segment_sequence_aligned(media_playlists) do
    first_sequences =
      Enum.map(media_playlists, fn media ->
        assert media.segments != []
        hd(media.segments).absolute_sequence
      end)

    assert Enum.uniq(first_sequences) |> length() == 1
  end
end
