defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF/TS/AAC
  muxing to eventually store them as HLS segments.

  ## Features

  - **Multiple Container Formats**: CMAF, MPEG-TS, Packed AAC, WebVTT
  - **Live & VOD Modes**: Sliding window playlists for live streaming, complete playlists for VOD
  - **Multi-track Support**: Audio, video, and subtitle tracks with automatic synchronization
  - **RFC 8216 Compliance**: Automatic validation with warning logging
  - **Async Uploads**: Concurrent segment uploads using Task.Supervisor

  ## Track Synchronization

  The SinkBin ensures spec-compliant HLS output where segments of the same index:
  - Start roughly at the same time (AAC and H264 cannot be cut at the exact same time)
  - Have the same duration

  The following measures are implemented:
  - **Audio/Subtitle Fillers**: Add silence if video starts earlier
  - **Audio/Subtitle Trimmers**: Trim leading content if video starts later
  - **Shifter** (VOD mode): Maintain monotonic PTS/DTS across stream restarts

  ## Streaming Modes

  ### VOD Mode (default)
  Playlists are written when all streams end. The Shifter element maintains monotonic
  timestamps across restarts by shifting PTS/DTS based on accumulated track duration.

  ### Live Mode
  - Discontinuities are added when streams restart
  - Periodic playlist synchronization based on segment duration
  - Sliding window playlists when `max_segments` is configured
  - Safety delays ensure stable playback

  ## Example

      child(:sink, %Membrane.HLS.SinkBin{
        storage: HLS.Storage.File.new(),
        manifest_uri: URI.new!("file:///tmp/stream.m3u8"),
        target_segment_duration: Membrane.Time.seconds(6),
        mode: {:live, Membrane.Time.seconds(18)},  # Optional: live mode
        max_segments: 10  # Optional: sliding window
      })

  ## Options

  - `storage` - (required) HLS.Storage implementation for storing segments and playlists
  - `manifest_uri` - (required) Base URI for the HLS manifest (master playlist)
  - `target_segment_duration` - (required) Target duration for each HLS segment
  - `max_segments` - (optional) Maximum segments in playlist; enables sliding window for live streaming
  - `mode` - (optional) `:vod` (default) or `{:live, safety_delay}` for live streaming
  - `resume_finished_tracks` - (optional, default: true) Allow adding segments to finished tracks
  - `restore_pending_segments` - (optional, default: false) Restore pending segments on resume
  - `flush_on_end` - (optional, default: true) Automatically flush when all streams end
  """
  use Membrane.Bin
  alias HLS.Packager

  require Membrane.Logger

  def_options(
    storage: [
      spec: HLS.Storage.t(),
      description: """
      HLS.Storage implementation for storing segments and playlists.
      Examples: `HLS.Storage.File.new()`, `HLS.Storage.S3.new(bucket: "my-bucket")`
      """
    ],
    manifest_uri: [
      spec: URI.t(),
      description: """
      Base URI for the HLS manifest (master playlist).
      Example: `URI.new!("file:///tmp/stream.m3u8")` or `URI.new!("s3://bucket/stream.m3u8")`
      """
    ],
    max_segments: [
      spec: pos_integer() | nil,
      default: nil,
      description: """
      Maximum number of segments to keep in the playlist. When set, the playlist will use
      a sliding window (live streaming). When `nil`, all segments are kept (VOD mode).
      In case of restarts with sliding window, a discontinuity indicator is added.

      Without sliding windows, the sink will shift the timing of each segment in case of
      restarts to ensure PTS strictly increasing monotonicity.
      """
    ],
    resume_finished_tracks: [
      spec: boolean(),
      default: true,
      description: """
      When resuming from existing playlists, allow adding segments to tracks marked as finished.
      Set to `false` to prevent modifications to completed tracks.
      """
    ],
    restore_pending_segments: [
      spec: boolean(),
      default: false,
      description: """
      When resuming from existing playlists, restore pending segments that weren't confirmed.
      Useful for crash recovery but may lead to duplicate segments if not handled carefully.
      """
    ],
    target_segment_duration: [
      spec: Membrane.Time.t(),
      description: """
      Target duration for each HLS segment.
      """
    ],
    mode: [
      spec: {:live, Membrane.Time.t()} | :vod,
      default: :vod,
      description: """
      * {:live, safety_delay} -> This element will include the provided segments
      in the media playlist each target_segment_duration. You're responsible for
      providing data for the segments in time.
      * :vod -> At the end of the segment production, playlists are written down.
      """
    ],
    flush_on_end: [
      spec: boolean(),
      default: true,
      description: """
      Automatically flush the packager when all streams ended.
      Set to `false` if flushing manually (via `:flush` notification).
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
        description: "Build either a `HLS.VariantStream` or a `HLS.AlternativeRendition`."
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
    # Initialize packager state
    {:ok, packager} =
      Packager.new(
        manifest_uri: opts.manifest_uri,
        max_segments: opts.max_segments,
        resume_finished_tracks: opts.resume_finished_tracks,
        restore_pending_segments: opts.restore_pending_segments
      )

    # Check for existing tracks and add discontinuity if resuming
    existing_tracks = Map.keys(packager.tracks)
    discontinue? = length(existing_tracks) > 0

    {packager, actions} =
      if discontinue? do
        Membrane.Logger.info("Resuming HLS stream with existing tracks, adding discontinuity")
        Packager.discontinue(packager)
      else
        {packager, []}
      end

    # Determine if we're in sliding window mode (live playlist)
    live_playlist? = not is_nil(opts.max_segments)

    # Initialize state
    state = %{
      packager: packager,
      storage: opts.storage,
      pending_tasks: %{},
      pending_data: %{},
      opts: opts,
      flush: opts.flush_on_end,
      ended_sinks: MapSet.new(),
      live_state: nil,
      live_playlist?: live_playlist?,
      time_discovery: %{
        candidates: %{},
        target_track: nil
      }
    }

    # Execute any initial actions from discontinuity
    state = execute_actions(state, actions)

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # We need to discover the time we're going to use as reference. If we have video,
    # we're using it. If only audio/subtitles tracks are present, we're using one of those.
    {track_id, _} =
      state.time_discovery.candidates
      |> Enum.sort(fn {_, left}, {_, right} -> left > right end)
      |> List.first()

    Membrane.Logger.info("Time reference will be obtained from track #{inspect(track_id)}")
    state = put_in(state, [:time_discovery, :target_track], track_id)
    {[], state}
  end

  @impl true
  def handle_child_notification({:observed_time, t}, {:time_checker, track_id}, _ctx, state) do
    Membrane.Logger.info(
      "Observed time #{inspect_timing(t)} on track #{inspect(track_id)} after guardrails"
    )

    {[], state}
  end

  def handle_child_notification(
        {:observed_time, t},
        {:time_observer, track_id},
        ctx,
        state = %{time_discovery: %{target_track: track_id}}
      ) do
    Membrane.Logger.info(
      "Discovered reference time #{inspect_timing(t)} on track #{inspect(track_id)}}"
    )

    actions =
      ctx.children
      |> Enum.filter(fn
        {{x, _track_id}, _info} when x in [:trimmer, :filler] -> true
        _ -> false
      end)
      |> Enum.map(fn {k, _} -> {:notify_child, {k, {:time_reference, t}}} end)

    {actions, state}
  end

  def handle_child_notification({:observed_time, t}, {:time_observer, track_id}, _ctx, state) do
    Membrane.Logger.info(
      "Observed time #{inspect_timing(t)} on track #{inspect(track_id)} before railguards"
    )

    {[], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_start_of_stream(
        child = {:muxer, _},
        _pad,
        _ctx,
        state = %{live_state: nil, opts: %{mode: {:live, _}}}
      ) do
    Membrane.Logger.debug("Initializing live state: triggering child: #{inspect(child)}")
    {[], live_init_state(state)}
  end

  def handle_element_start_of_stream(_child, _pad, _ctx, state) do
    {[], state}
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
      bin_input(pad)
      |> add_track_guardrails(track_id, state, Membrane.HLS.Filler.AAC)
      |> child({:aggregator, track_id}, %Membrane.HLS.AAC.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.PackedAACSink{
        parent: self(),
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], register_time_observer(state, track_id, 1)}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC, container: :TS} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> add_track_guardrails(track_id, state, Membrane.HLS.Filler.AAC)
      |> via_in(:input, options: [stream_type: :AAC_ADTS])
      |> child({:muxer, track_id}, Membrane.MPEG.TS.Muxer)
      |> child({:aggregator, track_id}, %Membrane.HLS.MPEG.TS.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.TSSink{
        parent: self(),
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], register_time_observer(state, track_id, 1)}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> add_track_guardrails(track_id, state, Membrane.HLS.Filler.AAC)
      |> via_in(Pad.ref(:input, track_id))
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> via_out(Pad.ref(:output), options: [tracks: [track_id]])
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        parent: self(),
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], register_time_observer(state, track_id, 1)}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264, container: :TS} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> add_track_guardrails(track_id, state)
      |> via_in(:input, options: [stream_type: :H264_AVC])
      |> child({:muxer, track_id}, Membrane.MPEG.TS.Muxer)
      |> child({:aggregator, track_id}, %Membrane.HLS.MPEG.TS.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.TSSink{
        parent: self(),
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], register_time_observer(state, track_id, 2)}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> add_track_guardrails(track_id, state)
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        parent: self(),
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], register_time_observer(state, track_id, 2)}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :TEXT} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> add_track_guardrails(track_id, state, Membrane.HLS.Filler.Text)
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
        parent: self(),
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], register_time_observer(state, track_id)}
  end

  @impl true
  def handle_element_end_of_stream({:sink, _track_id} = sink, _pad, ctx, state) do
    ended_sinks = MapSet.put(state.ended_sinks, sink)

    if all_streams_ended?(ctx, ended_sinks) do
      state =
        state
        |> put_in([:live_state], %{stop: true})
        |> put_in([:ended_sinks], ended_sinks)

      state =
        if state.flush do
          {packager, actions} = Packager.flush(state.packager)
          state = %{state | packager: packager}
          execute_actions(state, actions)
        else
          state
        end

      # Wait for pending tasks to complete before finalizing
      if map_size(state.pending_tasks) > 0 do
        Membrane.Logger.info(
          "Waiting for #{map_size(state.pending_tasks)} pending tasks before finalizing"
        )

        state = Map.put(state, :awaiting_completion, true)
        {[], state}
      else
        {[notify_parent: {:end_of_stream, state.flush}], state}
      end
    else
      {[], %{state | ended_sinks: ended_sinks}}
    end
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification(:flush, ctx, state) do
    if (not state.flush and all_streams_ended?(ctx, state.ended_sinks)) or
         is_nil(state.live_state) do
      {packager, actions} = Packager.flush(state.packager)
      state = %{state | packager: packager, flush: true}
      state = execute_actions(state, actions)

      # Wait for pending tasks before notifying
      if map_size(state.pending_tasks) > 0 do
        state = Map.put(state, :awaiting_completion, true)
        {[], state}
      else
        {[notify_parent: {:end_of_stream, true}], state}
      end
    else
      {[], %{state | flush: true}}
    end
  end

  # TODO: shall we check that this notification is only delivered for live playlists?
  def handle_parent_notification({:reset_deadline, _downtime}, _ctx, state = %{live_state: nil}) do
    Membrane.Logger.debug("Initializing live state from :reset_deadline notification")
    {[], live_init_state(state)}
  end

  def handle_parent_notification({:reset_deadline, downtime}, _ctx, state) do
    # In case of input drops, this notification can be used to make the sink
    # wait again as if the pipeline just restarted before trying to syncronize
    # new playlists.
    downtime_ms = Membrane.Time.as_milliseconds(downtime, :round)
    sync_timeout_ms = sync_timeout(state)

    timeout =
      if downtime_ms < sync_timeout_ms do
        # We just have to wait for the duration of the downtime to get
        # back to the state we were before.
        downtime_ms
      else
        sync_timeout_ms
      end

    Membrane.Logger.info(
      "Deadline reset. Restoring playlist syncronization in #{inspect_timing(timeout)}"
    )

    state = update_in(state, [:live_state, :next_deadline], fn x -> x + timeout end)

    state =
      update_in(
        state,
        [:live_state, :timer_ref],
        fn old_ref ->
          Process.cancel_timer(old_ref)
          Process.send_after(self(), :sync, state.live_state.next_deadline, abs: true)
        end
      )

    {[], state}
  end

  def handle_parent_notification(_, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info(:sync, _ctx, state = %{live_state: %{stop: true}}) do
    {[], state}
  end

  def handle_info(:sync, _ctx, state) do
    Membrane.Logger.debug("Packager: syncing playlists up to #{state.live_state.next_sync_point}")

    {packager, actions} = Packager.sync(state.packager, state.live_state.next_sync_point)
    state = %{state | packager: packager}
    state = execute_actions(state, actions)

    {[], live_schedule_next_sync(state)}
  end

  # Task completion handlers
  def handle_info({ref, result}, _ctx, state) when is_reference(ref) do
    case pop_in(state, [:pending_tasks, ref]) do
      {nil, state} ->
        # Unknown task ref, ignore
        {[], state}

      {%{type: :upload_segment}, state} ->
        Process.demonitor(ref, [:flush])
        {:uploaded, upload_id} = result

        Membrane.Logger.debug("Segment upload completed: #{upload_id}")

        # Confirm upload to packager
        {packager, actions} = Packager.confirm_upload(state.packager, upload_id)
        state = %{state | packager: packager}
        state = execute_actions(state, actions)

        # Check if we're awaiting completion (during shutdown)
        check_awaiting_completion({[], state})

      {%{type: :upload_init}, state} ->
        Process.demonitor(ref, [:flush])
        {:uploaded_init, upload_id} = result

        Membrane.Logger.debug("Init section upload completed: #{upload_id}")

        # Confirm init upload to packager
        {packager, actions} = Packager.confirm_init_upload(state.packager, upload_id)
        state = %{state | packager: packager}
        state = execute_actions(state, actions)

        check_awaiting_completion({[], state})

      {%{type: type}, state} when type in [:write_playlist, :delete] ->
        Process.demonitor(ref, [:flush])
        Membrane.Logger.debug("#{type} task completed")

        # No confirmation needed for writes/deletes
        check_awaiting_completion({[], state})
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, _ctx, state) do
    case pop_in(state, [:pending_tasks, ref]) do
      {nil, state} ->
        {[], state}

      {%{type: type, action: action}, state} ->
        Membrane.Logger.error("HLS task failed: #{type}",
          reason: inspect(reason),
          action: inspect(action)
        )

        # TODO: Consider retry logic or failure handling
        # For now, we continue without the failed operation
        check_awaiting_completion({[], state})
    end
  end

  # Sink message handlers
  def handle_info({:hls_add_track, track_id, opts}, _ctx, state) do
    Membrane.Logger.debug("Adding HLS track: #{track_id}")

    {packager, actions} = Packager.add_track(state.packager, track_id, opts)
    state = %{state | packager: packager}
    state = execute_actions(state, actions)

    {[], state}
  end

  def handle_info({:hls_init_section, track_id, binary}, _ctx, state) do
    Membrane.Logger.debug("Received init section for track: #{track_id}")

    # Call packager to get upload action
    {packager, actions} = Packager.put_init_section(state.packager, track_id)

    # Store binaries for upload actions, indexed by action ID
    pending_data =
      Enum.reduce(actions, state.pending_data, fn
        %HLS.Packager.Action.UploadInitSection{id: id}, acc ->
          Map.put(acc, id, binary)

        _, acc ->
          acc
      end)

    state = %{state | packager: packager, pending_data: pending_data}
    state = execute_actions(state, actions)

    {[], state}
  end

  def handle_info({:hls_segment, track_id, binary, duration}, _ctx, state) do
    Membrane.Logger.debug("Received segment for track #{track_id}, duration: #{duration}s")

    # Call packager to get upload action
    {packager, actions} = Packager.put_segment(state.packager, track_id, duration: duration)

    # Store binaries for upload actions, indexed by action ID
    pending_data =
      Enum.reduce(actions, state.pending_data, fn
        %HLS.Packager.Action.UploadSegment{id: id}, acc ->
          Map.put(acc, id, binary)

        _, acc ->
          acc
      end)

    state = %{state | packager: packager, pending_data: pending_data}
    state = execute_actions(state, actions)

    {[], state}
  end

  defp all_streams_ended?(ctx, ended_sinks) do
    ctx.children
    |> Map.keys()
    |> Enum.filter(&match?({:sink, _}, &1))
    |> MapSet.new()
    |> MapSet.equal?(ended_sinks)
  end

  defp live_schedule_next_sync(state) do
    state =
      state
      |> update_in([:live_state, :next_sync_point], fn x -> x + 1 end)
      |> update_in([:live_state, :next_deadline], fn x ->
        x + Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round)
      end)

    state
    |> put_in(
      [:live_state, :timer_ref],
      Process.send_after(self(), :sync, state.live_state.next_deadline, abs: true)
    )
  end

  defp sync_timeout(state) do
    # We wait until we have at least 3 segments before starting the initial sync process.
    # This ensures a stable, interruption free playback for the clients.
    {:live, safety_delay} = state.opts.mode

    target_segment_duration_ms =
      Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round)

    # TODO(optimization): we have a double safety_delay situation: packager
    # waits three segments to write the master playlist down, and the timer
    # there waits three iterations before ticking.
    Membrane.Time.as_milliseconds(safety_delay, :round) + target_segment_duration_ms * 3
  end

  defp live_init_state(state) do
    # Tells where in the playlist we should start issuing segments.
    # In the functional packager, next_sync_point is calculated based on the tracks' segment counts
    next_sync_point = Packager.next_sync_point(state.packager)

    now = :erlang.monotonic_time(:millisecond)
    timeout = sync_timeout(state)
    deadline = now + timeout

    Membrane.Logger.info(
      "Deadline reset. Starting playlist syncronization in #{inspect_timing(timeout)}"
    )

    live_state = %{
      # The next_sync_point is already rounded to the next segment. So we add two more segments to
      # reach the minimum of 3 segments.
      next_sync_point: next_sync_point,
      next_deadline: deadline,
      stop: false,
      timer_ref: Process.send_after(self(), :sync, deadline, abs: true)
    }

    %{state | live_state: live_state}
  end

  defp maybe_add_shifter(spec, _track_id, %{live_playlist?: true}), do: spec

  defp maybe_add_shifter(spec, track_id, state) do
    offset = track_pts(state.packager, track_id)

    Membrane.Logger.info(
      "Adding shifter for track #{inspect(track_id)} with offset #{inspect_timing(offset)}"
    )

    child(spec, {:shifter, track_id}, %Membrane.HLS.Shifter{
      duration: offset
    })
  end

  defp register_time_observer(state, track_id, prio \\ 0) do
    put_in(state, [:time_discovery, :candidates, track_id], prio)
  end

  defp add_track_guardrails(spec, track_id, state, filler \\ nil) do
    spec
    |> child({:time_observer, track_id}, Membrane.HLS.TimeObserver)
    |> child({:trimmer, track_id}, Membrane.HLS.Trimmer)
    |> then(fn spec ->
      if filler do
        child(spec, {:filler, track_id}, filler)
      else
        spec
      end
    end)
    |> maybe_add_shifter(track_id, state)
    |> child({:time_checker, track_id}, Membrane.HLS.TimeObserver)
  end

  defp track_pts(packager_state, track_id) do
    # In the functional packager, track_duration is accessed directly from the track
    case Map.get(packager_state.tracks, track_id) do
      nil ->
        0

      track ->
        # Sum of all segment durations
        Enum.reduce(track.segments, 0, fn segment, acc ->
          duration_seconds = segment.duration |> Ratio.new() |> Membrane.Time.seconds()
          acc + duration_seconds
        end)
    end
  end

  defp inspect_timing(t), do: "#{Float.round(t / 1.0e9, 2)}s"

  defp check_awaiting_completion({actions, state}) do
    if Map.get(state, :awaiting_completion, false) and map_size(state.pending_tasks) == 0 do
      Membrane.Logger.info("All pending tasks completed, finalizing stream")
      # All tasks done, send end_of_stream notification
      state = Map.delete(state, :awaiting_completion)
      {actions ++ [notify_parent: {:end_of_stream, state.flush}], state}
    else
      {actions, state}
    end
  end

  # Action execution functions

  defp execute_actions(state, actions) do
    Enum.reduce(actions, state, fn action, acc ->
      case action do
        %HLS.Packager.Action.Warning{} = warning ->
          log_warning(warning)
          acc

        %HLS.Packager.Action.UploadSegment{} = action ->
          start_async_task(acc, :upload_segment, action)

        %HLS.Packager.Action.UploadInitSection{} = action ->
          start_async_task(acc, :upload_init, action)

        %HLS.Packager.Action.WritePlaylist{} = action ->
          start_async_task(acc, :write_playlist, action)

        %HLS.Packager.Action.DeleteSegment{} = action ->
          start_async_task(acc, :delete, action)

        %HLS.Packager.Action.DeleteInitSection{} = action ->
          start_async_task(acc, :delete, action)

        %HLS.Packager.Action.DeletePlaylist{} = action ->
          start_async_task(acc, :delete, action)
      end
    end)
  end

  defp start_async_task(state, type, action) do
    # Retrieve binary data for upload actions
    {data, pending_data} =
      case action do
        %HLS.Packager.Action.UploadSegment{id: id} ->
          Map.pop(state.pending_data, id)

        %HLS.Packager.Action.UploadInitSection{id: id} ->
          Map.pop(state.pending_data, id)

        _ ->
          {nil, state.pending_data}
      end

    task =
      Task.Supervisor.async_nolink(
        Membrane.HLS.TaskSupervisor,
        fn -> execute_action(action, data, state.storage) end
      )

    metadata = %{type: type, action: action, track_id: Map.get(action, :track_id)}

    state
    |> put_in([:pending_data], pending_data)
    |> put_in([:pending_tasks, task.ref], metadata)
  end

  defp execute_action(%HLS.Packager.Action.UploadSegment{} = action, data, storage) do
    HLS.Storage.put(storage, action.uri, data)
    {:uploaded, action.id}
  end

  defp execute_action(%HLS.Packager.Action.UploadInitSection{} = action, data, storage) do
    HLS.Storage.put(storage, action.uri, data)
    {:uploaded_init, action.id}
  end

  defp execute_action(%HLS.Packager.Action.WritePlaylist{} = action, _data, storage) do
    # The action already has the marshaled content
    HLS.Storage.put(storage, action.uri, action.content)
    :written
  end

  defp execute_action(%HLS.Packager.Action.DeleteSegment{} = action, _data, storage) do
    HLS.Storage.delete(storage, action.uri)
    :deleted
  end

  defp execute_action(%HLS.Packager.Action.DeleteInitSection{} = action, _data, storage) do
    HLS.Storage.delete(storage, action.uri)
    :deleted
  end

  defp execute_action(%HLS.Packager.Action.DeletePlaylist{} = action, _data, storage) do
    HLS.Storage.delete(storage, action.uri)
    :deleted
  end

  # Warning logging

  defp log_warning(%HLS.Packager.Action.Warning{
         severity: :error,
         code: code,
         message: msg,
         details: details
       }) do
    Membrane.Logger.error("[HLS RFC8216 Violation] #{code}: #{msg}", details: details)
  end

  defp log_warning(%HLS.Packager.Action.Warning{
         severity: :warning,
         code: code,
         message: msg,
         details: details
       }) do
    Membrane.Logger.warning("[HLS] #{code}: #{msg}", details: details)
  end

  defp log_warning(%HLS.Packager.Action.Warning{
         severity: :info,
         code: code,
         message: msg,
         details: details
       }) do
    Membrane.Logger.info("[HLS] #{code}: #{msg}", details: details)
  end
end
