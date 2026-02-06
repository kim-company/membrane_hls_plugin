defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio/video/text tracks, packaging them into CMAF/TS/AAC,
  and writing playlists/segments via the provided storage.

  ## Timing contract
  - Upstream must provide monotonic, accurate PTS/DTS per track.
  - Tracks that produce segments at a given sync point must be aligned in time
    (minor AAC/H264 cut differences are tolerated within packager tolerance).
  - By default, the sink does not shift or trim timestamps.
  - Optional startup alignment trimming can be enabled with `:trim_align?`.

  ## Operational modes
  - `:vod` syncs whenever the next segment group is ready and is strict about timing.
  - `{:event, safety_delay}` syncs on a target-duration cadence.
  - `{:sliding, max_segments, safety_delay}` syncs on cadence and keeps a rolling window.

  ## Policy and error handling
  - All outputs are RFC-compliant.
  - `:vod` is strict: any packager error fails fast.
  - `:event`/`:sliding` are tolerant to recoverable timing issues by inserting
    discontinuities, but fail fast on missing mandatory track segments to avoid
    silent stalls.
  """
  use Membrane.Bin
  alias HLS.Packager

  require Membrane.Logger

  def_options(
    storage: [
      spec: HLS.Storage.t(),
      description: """
      Storage implementation used to write segments and playlists.
      """
    ],
    manifest_uri: [
      spec: URI.t(),
      description: """
      URI of the master playlist written by the packager.
      """
    ],
    target_segment_duration: [
      spec: Membrane.Time.t(),
      description: """
      Target duration for each HLS segment.
      """
    ],
    playlist_mode: [
      spec: :vod | {:event, Membrane.Time.t()} | {:sliding, pos_integer(), Membrane.Time.t()},
      default: :vod,
      description: """
      * :vod -> Segments are synced as soon as the next segment group is ready.
      * {:event, safety_delay} -> Live event playlist, synced each target segment duration.
      * {:sliding, max_segments, safety_delay} -> Live playlist with rolling window.
      """
    ],
    resume?: [
      spec: boolean(),
      default: false,
      description: """
      When true, attempt to resume from an existing master and media playlists in storage.
      """
    ],
    resume_on_error: [
      spec: :start_new | :raise,
      default: :start_new,
      description: """
      Policy for broken or missing initial playlists when resuming.
      """
    ],
    flush_on_end: [
      spec: boolean(),
      default: true,
      description: """
      Automatically flush the packager when all streams ended.
      Set to `false` if flushing manually (via `:flush` notification).
      """
    ],
    trim_align?: [
      spec: boolean(),
      default: false,
      description: """
      When enabled, trims leading content on startup so all input tracks start in tighter temporal
      alignment before segmentation.

      For H264 tracks this requires parsed AU-aligned input with keyframe metadata
      (typically from `Membrane.H264.Parser`).
      """
    ],
    trim_align_max_leading_trim: [
      spec: Membrane.Time.t(),
      default: Membrane.Time.seconds(3),
      description: """
      Maximum amount of leading media that can be removed from a single track while aligning.
      """
    ],
    trim_align_max_queued_buffers: [
      spec: pos_integer(),
      default: 2_000,
      description: """
      Maximum number of buffers queued per track while waiting for startup alignment.
      """
    ]
  )

  @type track :: Membrane.CMAF.Track.t() | map()

  def_input_pad(:input,
    accepted_format: any_of(Membrane.H264, Membrane.AAC, Membrane.Text, Membrane.RemoteStream),
    availability: :on_request,
    options: [
      container: [
        spec: :CMAF | :TS | :PACKED_AAC,
        default: :CMAF,
        description: """
        How A/V tracks are packaged.
        """
      ],
      encoding: [
        spec: :AAC | :H264 | :TEXT,
        description: """
        Encoding type determining which parser will be used for the given stream.
        """
      ],
      omit_subtitle_repetition: [
        spec: boolean(),
        default: false,
        description: """
        When writing subtitle playlists, subtitles that span over multiple segments are repeated
        in both segments. When this flag is turned on, subtitles appear only in the segment in
        which they start.
        """
      ],
      subtitle_min_duration: [
        spec: Membrane.Time.t(),
        default: Membrane.Time.milliseconds(1500),
        description: """
        Forces subtitles to last at list the specified amount of time. If omitted, subtitles will
        last the duration of their content.
        """
      ],
      relative_mpeg_ts_timestamps: [
        spec: boolean(),
        default: false,
        description:
          "If true, each subtitle segment will have a X-TIMESTAMP-MAP header and its contents will be relative to that timing."
      ],
      build_stream: [
        spec: (track() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
        description:
          "Build either a `HLS.VariantStream` or a `HLS.AlternativeRendition`. `VariantStream.bandwidth` and `VariantStream.codecs` are deprecated and are now computed automatically when possible."
      ],
      segment_duration: [
        spec: Membrane.Time.t(),
        description: """
        Duration for a HLS segment.
        """
      ]
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    actions =
      if opts.trim_align? do
        [
          spec:
            child(:trim_aligner, %Membrane.HLS.TrimAlign{
              max_leading_trim: opts.trim_align_max_leading_trim,
              max_queued_buffers: opts.trim_align_max_queued_buffers
            })
        ]
      else
        []
      end

    {actions,
     %{
       opts: opts,
       packager: nil,
       storage: opts.storage,
       flush: opts.flush_on_end,
       ended_sinks: MapSet.new(),
       mode: build_mode(opts),
       expected_tracks: MapSet.new(),
       time_discovery: %{}
     }}
  end

  @impl true
  def handle_setup(_ctx, state) do
    {packager, events} = init_packager(state.opts, state.storage)

    actions = Enum.map(events, &{:notify_parent, &1})

    state = %{
      state
      | packager: packager,
        mode: update_mode_after_setup(state.mode, packager)
    }

    {actions, state}
  end

  def handle_child_notification({:packager_add_track, track_id, opts}, _child, _ctx, state) do
    {packager, []} = Packager.add_track(state.packager, track_id, opts)

    state =
      state
      |> Map.put(:packager, packager)
      |> update_in([:expected_tracks], &MapSet.delete(&1, track_id))

    {[
       notify_parent:
         {:packager_updated, :track_added, packager, %{track_id: track_id, opts: opts}}
     ], state}
  end

  def handle_child_notification(
        {:packager_put_init_section, track_id, payload},
        _child,
        _ctx,
        state
      ) do
    {packager, actions} = Packager.put_init_section(state.packager, track_id)

    state =
      %{state | packager: packager}
      |> execute_upload_actions(actions, payload)

    {[], state}
  end

  def handle_child_notification(
        {:packager_put_segment, track_id, payload, duration, pts, dts},
        _child,
        _ctx,
        state
      ) do
    {[], handle_packager_put_segment(state, track_id, payload, duration, pts, dts)}
  end

  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_start_of_stream(child, _pad, _ctx, state = %{mode: mode}) do
    if live_mode?(mode) and is_nil(mode_sync_state(mode)) do
      Membrane.Logger.debug("Initializing live state: triggering child: #{inspect(child)}")
      {[], live_init_state(state)}
    else
      {[], state}
    end
  end

  @impl true
  def handle_pad_added(_pad, ctx, _state) when ctx.playback == :playing,
    do:
      raise(
        "New pads can be added to #{inspect(__MODULE__)} only before playback transition to :playing"
      )

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC, container: :PACKED_AAC} = pad_opts},
        state
      ) do
    spec =
      input_with_optional_trim(pad, track_id, state, :AAC)
      |> child({:aggregator, track_id}, %Membrane.HLS.AAC.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.PackedAACSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state = register_track(state, track_id)

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC, container: :TS} = pad_opts},
        state
      ) do
    spec =
      input_with_optional_trim(pad, track_id, state, :AAC)
      |> via_in(:input, options: [stream_type: :AAC_ADTS])
      |> child({:muxer, track_id}, Membrane.MPEG.TS.Muxer)
      |> child({:aggregator, track_id}, %Membrane.HLS.MPEG.TS.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.TSSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state = register_track(state, track_id)

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC} = pad_opts},
        state
      ) do
    spec =
      input_with_optional_trim(pad, track_id, state, :AAC)
      |> via_in(Pad.ref(:input, track_id))
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> via_out(Pad.ref(:output, track_id), options: [tracks: [track_id]])
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state = register_track(state, track_id)

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264, container: :TS} = pad_opts},
        state
      ) do
    spec =
      input_with_optional_trim(pad, track_id, state, :H264)
      |> via_in(:input, options: [stream_type: :H264_AVC])
      |> child({:muxer, track_id}, Membrane.MPEG.TS.Muxer)
      |> child({:aggregator, track_id}, %Membrane.HLS.MPEG.TS.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.TSSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state = register_track(state, track_id)

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264} = pad_opts},
        state
      ) do
    spec =
      input_with_optional_trim(pad, track_id, state, :H264)
      |> child({:duration_estimator, track_id}, Membrane.HLS.NALU.DurationEstimator)
      |> via_in(Pad.ref(:input, track_id))
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> via_out(Pad.ref(:output, track_id), options: [tracks: [track_id]])
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state = register_track(state, track_id)

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :TEXT} = pad_opts},
        state
      ) do
    spec =
      input_with_optional_trim(pad, track_id, state, :TEXT)
      |> child({:cues, track_id}, %Membrane.WebVTT.Filter{
        min_duration: pad_opts.subtitle_min_duration
      })
      |> child({:segments, track_id}, %Membrane.HLS.WebVTT.Aggregator{
        segment_duration: pad_opts.segment_duration,
        omit_repetition: pad_opts.omit_subtitle_repetition,
        relative_mpeg_ts_timestamps: pad_opts.relative_mpeg_ts_timestamps,
        headers: [
          %Subtitle.WebVTT.HeaderLine{key: :description, original: "WEBVTT"}
        ]
      })
      |> child({:sink, track_id}, %Membrane.HLS.WebVTTSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state = register_track(state, track_id)

    {[spec: spec], state}
  end

  @impl true
  def handle_element_end_of_stream({:sink, _track_id} = sink, _pad, ctx, state) do
    ended_sinks = MapSet.put(state.ended_sinks, sink)

    if all_streams_ended?(ctx, ended_sinks) do
      state =
        state
        |> drain_sync_on_end()
        |> maybe_stop_sync_on_end()
        |> put_in([:ended_sinks], ended_sinks)

      state = if state.flush, do: flush_packager(state), else: state

      {[notify_parent: {:end_of_stream, state.flush}], state}
    else
      {[], %{state | ended_sinks: ended_sinks}}
    end
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  defp maybe_stop_sync_on_end(state) do
    case mode_sync_state(state.mode) do
      nil ->
        state

      sync_state ->
        if live_mode?(state.mode) do
          if sync_state.timer_ref do
            Process.cancel_timer(sync_state.timer_ref)
          end

          update_state_sync_state(state, %{sync_state | stop: true, timer_ref: nil})
        else
          state
        end
    end
  end

  defp drain_sync_on_end(state) do
    if live_mode?(state.mode) and not state.flush do
      drain_sync(state)
    else
      state
    end
  end

  defp drain_sync(state) do
    sync_point = Packager.next_sync_point(state.packager)
    {ready?, _lagging} = Packager.sync_ready?(state.packager, sync_point)

    if ready? do
      state = sync_packager(state, sync_point)

      if Packager.next_sync_point(state.packager) == sync_point do
        state
      else
        drain_sync(state)
      end
    else
      state
    end
  end

  @impl true
  def handle_parent_notification(:flush, ctx, state) do
    if (not state.flush and all_streams_ended?(ctx, state.ended_sinks)) or
         is_nil(mode_sync_state(state.mode)) do
      state =
        state
        |> Map.put(:flush, true)
        |> flush_packager()

      {[notify_parent: {:end_of_stream, true}], state}
    else
      {[], %{state | flush: true}}
    end
  end

  def handle_parent_notification(_, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info(:sync, _ctx, state) do
    case mode_sync_state(state.mode) do
      nil ->
        {[], state}

      sync_state ->
        if sync_state_stopped?(state.mode) do
          {[], state}
        else
          Membrane.Logger.debug("Packager: syncing playlists up to #{sync_state.next_sync_point}")

          state = sync_packager(state, sync_state.next_sync_point)

          {[], live_schedule_next_sync(state)}
        end
    end
  end

  defp all_streams_ended?(ctx, ended_sinks) do
    ctx.children
    |> Map.keys()
    |> Enum.filter(&match?({:sink, _}, &1))
    |> MapSet.new()
    |> MapSet.equal?(ended_sinks)
  end

  defp init_packager(opts, storage) do
    max_segments = mode_max_segments(opts.playlist_mode)

    if opts.resume? do
      case resume_packager(opts, storage, max_segments) do
        {:ok, packager} ->
          {packager, [{:packager_updated, :resumed, packager}]}

        {:error, error} ->
          case opts.resume_on_error do
            :raise ->
              raise "Failed to resume packager: #{inspect(error)}"

            :start_new ->
              {packager, events} = new_packager(opts, max_segments)
              {packager, [{:packager_updated, :resume_failed, error} | events]}
          end
      end
    else
      new_packager(opts, max_segments)
    end
  end

  defp new_packager(opts, max_segments) do
    case Packager.new(manifest_uri: opts.manifest_uri, max_segments: max_segments) do
      {:ok, packager} ->
        {packager, [{:packager_updated, :new, packager}]}

      {:error, error} ->
        raise "Failed to initialize packager: #{inspect(error)}"
    end
  end

  defp resume_packager(opts, storage, max_segments) do
    with {:ok, master_body} <- HLS.Storage.get(storage, opts.manifest_uri),
         {:ok, master} <- unmarshal_master(master_body, opts.manifest_uri),
         {:ok, media_playlists} <- load_media_playlists(master, storage),
         {:ok, packager} <-
           Packager.resume(
             master_playlist: master,
             media_playlists: media_playlists,
             max_segments: max_segments
           ) do
      {:ok, packager}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp unmarshal_master(payload, manifest_uri) do
    try do
      master = HLS.Playlist.unmarshal(payload, %HLS.Playlist.Master{uri: manifest_uri})
      {:ok, master}
    rescue
      error -> {:error, error}
    end
  end

  defp load_media_playlists(master, storage) do
    streams = master.streams ++ master.alternative_renditions

    Enum.reduce_while(streams, {:ok, %{}}, fn stream, {:ok, acc} ->
      case Map.get(stream, :uri) do
        nil ->
          {:cont, {:ok, acc}}

        uri ->
          key = to_string(uri)

          if Map.has_key?(acc, key) do
            {:cont, {:ok, acc}}
          else
            absolute_uri = HLS.Playlist.build_absolute_uri(master.uri, uri)

            case HLS.Storage.get(storage, absolute_uri) do
              {:ok, payload} ->
                case unmarshal_media(payload, uri) do
                  {:ok, media} -> {:cont, {:ok, Map.put(acc, key, media)}}
                  {:error, error} -> {:halt, {:error, error}}
                end

              {:error, :not_found} ->
                {:cont, {:ok, acc}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end
      end
    end)
    |> case do
      {:ok, medias} -> {:ok, Map.values(medias)}
      {:error, _} = error -> error
    end
  end

  defp unmarshal_media(payload, media_uri) do
    try do
      media = HLS.Playlist.unmarshal(payload, %HLS.Playlist.Media{uri: media_uri})
      {:ok, media}
    rescue
      error -> {:error, error}
    end
  end

  defp build_mode(opts) do
    case opts.playlist_mode do
      :vod ->
        {:vod, %{}}

      {:event, safety_delay} ->
        {:event, %{safety_delay: safety_delay, sync_state: nil}}

      {:sliding, max_segments, safety_delay} ->
        {:sliding, %{max_segments: max_segments, safety_delay: safety_delay, sync_state: nil}}
    end
  end

  defp update_mode_after_setup({:sliding, state}, packager) do
    {:sliding, Map.put(state, :max_segments, packager.max_segments)}
  end

  defp update_mode_after_setup(mode, _packager), do: mode

  defp mode_max_segments(:vod), do: nil
  defp mode_max_segments({:event, _safety_delay}), do: nil
  defp mode_max_segments({:sliding, max_segments, _safety_delay}), do: max_segments

  defp mode_sync_state({:event, state}), do: state.sync_state
  defp mode_sync_state({:sliding, state}), do: state.sync_state
  defp mode_sync_state({:vod, _state}), do: nil

  defp sync_state_stopped?(mode) do
    case mode_sync_state(mode) do
      %{stop: true} -> true
      _ -> false
    end
  end

  defp update_state_sync_state(state, sync_state) do
    %{state | mode: update_mode_sync_state(state.mode, sync_state)}
  end

  defp update_mode_sync_state({:event, state}, sync_state) do
    {:event, %{state | sync_state: sync_state}}
  end

  defp update_mode_sync_state({:sliding, state}, sync_state) do
    {:sliding, %{state | sync_state: sync_state}}
  end

  defp update_mode_sync_state(mode, _sync_state), do: mode

  defp live_mode?({:vod, _state}), do: false
  defp live_mode?({:event, _state}), do: true
  defp live_mode?({:sliding, _state}), do: true

  defp live_safety_delay({:event, state}), do: state.safety_delay
  defp live_safety_delay({:sliding, state}), do: state.safety_delay

  defp live_schedule_next_sync(state) do
    update_in(state, [:mode], fn mode ->
      sync_state = mode_sync_state(mode)

      next_sync_point =
        max(sync_state.next_sync_point + 1, Packager.next_sync_point(state.packager))

      next_deadline =
        sync_state.next_deadline +
          Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round)

      timer_ref = Process.send_after(self(), :sync, next_deadline, abs: true)

      update_mode_sync_state(mode, %{
        sync_state
        | next_sync_point: next_sync_point,
          next_deadline: next_deadline,
          timer_ref: timer_ref
      })
    end)
  end

  defp sync_timeout(state) do
    # We wait until we have at least 3 segments before starting the initial sync process.
    # This ensures a stable, interruption free playback for the clients.
    safety_delay = live_safety_delay(state.mode)

    target_segment_duration_ms =
      Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round)

    # TODO(optimization): we have a double safety_delay situation: packager
    # waits three segments to write the master playlist down, and the timer
    # there waits three iterations before ticking.
    Membrane.Time.as_milliseconds(safety_delay, :round) + target_segment_duration_ms * 3
  end

  defp live_init_state(state) do
    # Tells where in the playlist we should start issuing segments.
    next_sync_point = Packager.next_sync_point(state.packager)
    now = :erlang.monotonic_time(:millisecond)
    timeout = sync_timeout(state)
    deadline = now + timeout

    Membrane.Logger.info(
      "Deadline reset. Starting playlist syncronization in #{inspect_timing(Membrane.Time.milliseconds(timeout))}"
    )

    sync_state = %{
      next_sync_point: next_sync_point,
      next_deadline: deadline,
      stop: false,
      timer_ref: Process.send_after(self(), :sync, deadline, abs: true)
    }

    update_state_sync_state(state, sync_state)
  end

  defp input_with_optional_trim(pad, _track_id, state, _encoding)
       when not state.opts.trim_align? do
    bin_input(pad)
  end

  defp input_with_optional_trim(pad, track_id, _state, encoding) do
    bin_input(pad)
    |> via_in(Pad.ref(:input, track_id), options: [cut_strategy: trim_cut_strategy(encoding)])
    |> get_child(:trim_aligner)
    |> via_out(Pad.ref(:output, track_id))
  end

  defp trim_cut_strategy(:H264), do: :h264_keyframe
  defp trim_cut_strategy(_encoding), do: :any

  defp register_track(state, track_id) do
    update_in(state, [:expected_tracks], &MapSet.put(&1, track_id))
  end

  defp handle_packager_put_segment(state, track_id, payload, duration, pts, dts) do
    if is_nil(pts) do
      Membrane.Logger.error("Packager segment missing PTS for track #{inspect(track_id)}")
      state
    else
      case Packager.put_segment(state.packager, track_id,
             duration: duration,
             pts: pts,
             dts: dts,
             size_bytes: IO.iodata_length(payload)
           ) do
        {packager, actions} ->
          state
          |> Map.put(:packager, packager)
          |> execute_upload_actions(actions, payload)

        {:warning, warning, packager} ->
          Membrane.Logger.warning(
            "Packager warning on track #{inspect(track_id)}: #{inspect(warning)}"
          )

          %{state | packager: packager}

        {:error, error, packager} ->
          Membrane.Logger.error(
            "Packager rejected segment on track #{inspect(track_id)}: #{inspect(error)}"
          )

          state
          |> Map.put(:packager, packager)
          |> handle_packager_error(error)
      end
    end
  end

  defp execute_upload_actions(state, actions, payload) do
    Enum.reduce(actions, state, fn action, acc ->
      case action do
        %Packager.Action.UploadSegment{} ->
          upload_segment(acc, action, payload)

        %Packager.Action.UploadInitSection{} ->
          upload_init_section(acc, action, payload)

        _ ->
          execute_action(action, acc)
      end
    end)
  end

  defp upload_segment(state, action, payload) do
    case HLS.Storage.put(state.storage, action.uri, payload) do
      :ok ->
        case Packager.confirm_upload(state.packager, action.id) do
          {packager, actions} ->
            state
            |> Map.put(:packager, packager)
            |> execute_actions(actions)
            |> maybe_sync_on_segment()

          {:warning, warning, packager} ->
            Membrane.Logger.warning("Packager upload confirmation warning: #{inspect(warning)}")

            %{state | packager: packager}
            |> maybe_sync_on_segment()
        end

      {:error, reason} ->
        Membrane.Logger.error(
          "Failed to upload segment #{to_string(action.uri)}: #{inspect(reason)}"
        )

        state
    end
  end

  defp upload_init_section(state, action, payload) do
    case HLS.Storage.put(state.storage, action.uri, payload) do
      :ok ->
        {packager, []} = Packager.confirm_init_upload(state.packager, action.id)
        %{state | packager: packager}

      {:error, reason} ->
        Membrane.Logger.error(
          "Failed to upload init section #{to_string(action.uri)}: #{inspect(reason)}"
        )

        state
    end
  end

  defp execute_actions(state, actions) do
    Enum.reduce(actions, state, &execute_action/2)
  end

  defp execute_action(action, state) do
    case action do
      %Packager.Action.WritePlaylist{uri: uri, content: content} ->
        case HLS.Storage.put(state.storage, uri, content) do
          :ok ->
            state

          {:error, reason} ->
            Membrane.Logger.error(
              "Failed to write playlist #{to_string(uri)}: #{inspect(reason)}"
            )

            state
        end

      %Packager.Action.DeleteSegment{uri: uri} ->
        case HLS.Storage.delete(state.storage, uri) do
          :ok ->
            state

          {:error, reason} ->
            Membrane.Logger.error(
              "Failed to delete segment #{to_string(uri)}: #{inspect(reason)}"
            )

            state
        end

      %Packager.Action.DeleteInitSection{uri: uri} ->
        case HLS.Storage.delete(state.storage, uri) do
          :ok ->
            state

          {:error, reason} ->
            Membrane.Logger.error(
              "Failed to delete init section #{to_string(uri)}: #{inspect(reason)}"
            )

            state
        end

      %Packager.Action.DeletePlaylist{uri: uri} ->
        case HLS.Storage.delete(state.storage, uri) do
          :ok ->
            state

          {:error, reason} ->
            Membrane.Logger.error(
              "Failed to delete playlist #{to_string(uri)}: #{inspect(reason)}"
            )

            state
        end

      _ ->
        Membrane.Logger.warning("Unhandled packager action: #{inspect(action)}")
        state
    end
  end

  defp maybe_sync_on_segment(%{mode: {:vod, _state}, expected_tracks: expected} = state) do
    if MapSet.size(expected) > 0 do
      state
    else
      sync_point = Packager.next_sync_point(state.packager)
      {ready?, _lagging} = Packager.sync_ready?(state.packager, sync_point)

      if ready? do
        sync_packager(state, sync_point)
      else
        state
      end
    end
  end

  defp maybe_sync_on_segment(state), do: state

  defp sync_packager(state, sync_point) do
    case Packager.sync(state.packager, sync_point) do
      {packager, actions} ->
        state
        |> Map.put(:packager, packager)
        |> execute_actions(actions)

      {:warning, warnings, packager} ->
        state
        |> Map.put(:packager, packager)
        |> handle_packager_warnings(warnings)

      {:error, error, packager} ->
        Membrane.Logger.error("Packager sync failed: #{inspect(error)}")

        state
        |> Map.put(:packager, packager)
        |> handle_packager_error(error)
    end
  end

  defp flush_packager(state) do
    {packager, actions} = Packager.flush(state.packager)

    state
    |> Map.put(:packager, packager)
    |> execute_actions(actions)
  end

  defp handle_packager_error(state, %Packager.Error{code: code} = error) do
    if strict_policy?(state.mode) do
      raise "Packager error (strict mode): #{inspect(error)}"
    else
      case code do
        :mandatory_track_missing_segment_at_sync ->
          raise "Packager error (mandatory track missing): #{inspect(error)}"

        :segment_duration_over_target ->
          skip_sync_point_or_raise(state, error, :segment_index)

        :timing_drift ->
          skip_sync_point_or_raise(state, error, :segment_index)

        :track_timing_mismatch_at_sync ->
          skip_sync_point_or_raise(state, error, :sync_point)

        :discontinuity_point_missed ->
          raise "Packager error (discontinuity missed): #{inspect(error)}"

        _ ->
          raise "Packager error (unhandled): #{inspect(error)}"
      end
    end
  end

  defp handle_packager_warnings(state, warnings) do
    case Enum.find(warnings, &(&1.code == :mandatory_track_missing_segment_at_sync)) do
      nil ->
        Enum.each(warnings, fn warning ->
          Membrane.Logger.warning("Packager sync warning: #{inspect(warning)}")
        end)

        state

      warning ->
        raise "Packager warning (mandatory track missing): #{inspect(warning)}"
    end
  end

  defp skip_sync_point_or_raise(state, %Packager.Error{details: details} = error, key) do
    case Map.get(details, key) do
      sync_point when is_integer(sync_point) and sync_point > 0 ->
        skip_sync_point(state, sync_point)

      _ ->
        raise "Packager error missing sync point metadata: #{inspect(error)}"
    end
  end

  defp skip_sync_point(state, sync_point) when is_integer(sync_point) and sync_point > 0 do
    case Packager.skip_sync_point(state.packager, sync_point) do
      {packager, _actions} ->
        %{state | packager: packager}

      {:error, error, packager} ->
        Membrane.Logger.error("Packager failed to skip sync point: #{inspect(error)}")
        %{state | packager: packager}
    end
  end

  defp skip_sync_point(state, _sync_point), do: state

  defp strict_policy?(mode), do: match?({:vod, _}, mode)

  defp inspect_timing(t), do: "#{Float.round(t / 1.0e9, 2)}s"
end
