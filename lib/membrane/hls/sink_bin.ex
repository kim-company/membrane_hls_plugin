defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF/TS/AAC
  muxing to eventually store them using provided storage configuration.

  As soon as a spec-compliant HLS stream which segments of the same index:
  - start roughly at the same time (AAC and H264 cannot be cut at the same exact time)
  - have the same duration

  The following measures have been implemented:
  - audio+subtitles fillers: if video starts earlier, we add the missing silence
  - audio+subtitles trimmers: if video starts later, we trim leading content

  Special cases for our companies internal requirements (might change in the future):
  - when in a sliding window setup, we use discontinuities when the stream restarts
  - when in a non-sliding window setup, playlists will contain a best-effort strictly
  monotonically increasing PTS/DTS timeline. Best effort because right after a restart
  audio and video will contain a small offset hole. This is **not** spec complaint and
  we're planning on using the discontinuity pattern there as well.
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
    {[],
     %{
       opts: opts,
        packager: nil,
        storage: opts.storage,
        flush: opts.flush_on_end,
        ended_sinks: MapSet.new(),
        live_state: nil,
        live_playlist?: false,
        playlist_mode: opts.playlist_mode,
        expected_tracks: MapSet.new(),
        time_discovery: %{
          candidates: %{},
          target_track: nil
        }
      }}
  end

  @impl true
  def handle_setup(_ctx, state) do
    {packager, events} = init_packager(state.opts, state.storage)

    actions = Enum.map(events, &{:notify_parent, &1})

    state = %{
      state
      | packager: packager,
        live_playlist?: not is_nil(packager.max_segments)
    }

    {actions, state}
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

  def handle_child_notification({:packager_add_track, track_id, opts}, _child, _ctx, state) do
    {packager, []} = Packager.add_track(state.packager, track_id, opts)
    state =
      state
      |> Map.put(:packager, packager)
      |> update_in([:expected_tracks], &MapSet.delete(&1, track_id))

    {[
       notify_parent: {:packager_updated, :track_added, packager, %{track_id: track_id, opts: opts}}
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
  def handle_element_start_of_stream(
        child = {:muxer, _},
        _pad,
        _ctx,
        state = %{live_state: nil, playlist_mode: playlist_mode}
      ) do
    if live_mode?(playlist_mode) do
      Membrane.Logger.debug("Initializing live state: triggering child: #{inspect(child)}")
      {[], live_init_state(state)}
    else
      {[], state}
    end
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
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state =
      state
      |> register_track(track_id)
      |> register_time_observer(track_id, 1)

    {[spec: spec], state}
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
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state =
      state
      |> register_track(track_id)
      |> register_time_observer(track_id, 1)

    {[spec: spec], state}
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
      |> via_out(Pad.ref(:output, track_id), options: [tracks: [track_id]])
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state =
      state
      |> register_track(track_id)
      |> register_time_observer(track_id, 1)

    {[spec: spec], state}
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
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state =
      state
      |> register_track(track_id)
      |> register_time_observer(track_id, 2)

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> add_track_guardrails(track_id, state)
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

    state =
      state
      |> register_track(track_id)
      |> register_time_observer(track_id, 2)

    {[spec: spec], state}
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
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    state =
      state
      |> register_track(track_id)
      |> register_time_observer(track_id)

    {[spec: spec], state}
  end

  @impl true
  def handle_element_end_of_stream({:sink, _track_id} = sink, _pad, ctx, state) do
    ended_sinks = MapSet.put(state.ended_sinks, sink)

    if all_streams_ended?(ctx, ended_sinks) do
      state =
        state
        |> put_in([:live_state], %{stop: true})
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

  @impl true
  def handle_parent_notification(:flush, ctx, state) do
    if (not state.flush and all_streams_ended?(ctx, state.ended_sinks)) or
         is_nil(state.live_state) do
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
  def handle_info(:sync, _ctx, state = %{live_state: %{stop: true}}) do
    {[], state}
  end

  def handle_info(:sync, _ctx, state) do
    Membrane.Logger.debug("Packager: syncing playlists up to #{state.live_state.next_sync_point}")

    state = sync_packager(state, state.live_state.next_sync_point)

    {[], live_schedule_next_sync(state)}
  end

  defp all_streams_ended?(ctx, ended_sinks) do
    ctx.children
    |> Map.keys()
    |> Enum.filter(&match?({:sink, _}, &1))
    |> MapSet.new()
    |> MapSet.equal?(ended_sinks)
  end

  defp init_packager(opts, storage) do
    max_segments =
      case opts.playlist_mode do
        :vod -> nil
        {:event, _safety_delay} -> nil
        {:sliding, max_segments, _safety_delay} -> max_segments
      end

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

  defp live_mode?(:vod), do: false
  defp live_mode?({:event, _safety_delay}), do: true
  defp live_mode?({:sliding, _max_segments, _safety_delay}), do: true

  defp live_safety_delay({:event, safety_delay}), do: safety_delay
  defp live_safety_delay({:sliding, _max_segments, safety_delay}), do: safety_delay

  defp live_schedule_next_sync(state) do
    state =
      state
      |> update_in([:live_state, :next_sync_point], fn x ->
        # If the HLS is writing down the chunks faster than realtime,
        # we might need to sync faster. Thats why we're calling next_syncpoint again.
        max(x + 1, Packager.next_sync_point(state.packager))
      end)
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
    safety_delay = live_safety_delay(state.playlist_mode)

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
      "Deadline reset. Starting playlist syncronization in #{inspect_timing(timeout)}"
    )

    live_state = %{
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

  defp register_track(state, track_id) do
    update_in(state, [:expected_tracks], &MapSet.put(&1, track_id))
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

  defp handle_packager_put_segment(state, track_id, payload, duration, pts, dts) do
    if is_nil(pts) do
      Membrane.Logger.error("Packager segment missing PTS for track #{inspect(track_id)}")
      state
    else
      case Packager.put_segment(state.packager, track_id,
             duration: duration,
             pts: pts,
             dts: dts
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

          %{state | packager: packager}
          |> maybe_skip_sync_point(error)
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

  defp maybe_sync_on_segment(%{playlist_mode: :vod, expected_tracks: expected} = state) do
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
        Enum.each(warnings, fn warning ->
          Membrane.Logger.warning("Packager sync warning: #{inspect(warning)}")
        end)

        %{state | packager: packager}

      {:error, error, packager} ->
        Membrane.Logger.error("Packager sync failed: #{inspect(error)}")
        %{state | packager: packager}
    end
  end

  defp flush_packager(state) do
    {packager, actions} = Packager.flush(state.packager)

    state
    |> Map.put(:packager, packager)
    |> execute_actions(actions)
  end

  defp maybe_skip_sync_point(state, %Packager.Error{code: code, details: details})
       when code in [:segment_duration_over_target, :timing_drift] do
    sync_point = Map.get(details, :segment_index) || Map.get(details, :sync_point)

    case Packager.skip_sync_point(state.packager, sync_point) do
      {packager, _actions} ->
        %{state | packager: packager}

      {:error, error, packager} ->
        Membrane.Logger.error("Packager failed to skip sync point: #{inspect(error)}")
        %{state | packager: packager}
    end
  end

  defp maybe_skip_sync_point(state, _error), do: state

  defp track_pts(packager, track_id) do
    case Map.fetch(packager.tracks, track_id) do
      {:ok, track} ->
        round(track.duration * 1.0e9)

      :error ->
        0
    end
  end

  defp inspect_timing(t), do: "#{Float.round(t / 1.0e9, 2)}s"
end
