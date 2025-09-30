defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF/TS/AAC
  muxing to eventually store them using provided storage configuration.

  ## Experimental Features

  **AAC over TS support is experimental** - Packing audio streams directly into Transport Stream
  containers may not be fully stable and could have compatibility issues with some players.
  """
  use Membrane.Bin
  alias HLS.Packager

  require Membrane.Logger

  def_options(
    packager: [
      spec: pid(),
      description: """
      PID of a `HLS.Packager`. If the packager is configured with max_segments,
      the playlist will be offered with sliding windows. In case of restarts, a
      discontinuity indicator is added.

      In the other case, when the playlist does not have sliding windows, the
      sink will shift the timing of each segment in case of restarts to ensure
      PTS strictly increasing monotonicity.
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
      in the media playlist each target_segment_duration.
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
      ],
      audio_offset: [
        spec: Membrane.Time.t(),
        default: 0,
        description: """
        Initial AAC offset w.r.t the video.

        The very first segment of the audio can be used to re-align audio/video streams. Usually when
        an encoder starts producing audio and video data, the initial video PTS/DTS might start with a difference due to the presence of B frames (e.g. DTS 2.67, PTS 2.7).
        Setting the offset to that difference (which is usually deterministic based on encoder's settings)
        will make the subsequent segments align.
        """
      ]
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    true =
      opts.packager
      |> GenServer.whereis()
      |> Process.link()

    discontinue? =
      opts.packager
      |> Packager.tracks()
      |> Enum.any?()

    if discontinue?, do: Packager.discontinue(opts.packager)

    {[],
     %{
       opts: opts,
       flush: opts.flush_on_end,
       ended_sinks: MapSet.new(),
       live_state: nil,
       live_playlist?: HLS.Packager.sliding_window_enabled?(opts.packager)
     }}
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
      |> maybe_add_shifter(track_id, state)
      |> child({:aggregator, track_id}, %Membrane.HLS.AAC.Aggregator{
        target_duration: pad_opts.segment_duration,
        offset: pad_opts.audio_offset
      })
      |> child({:sink, track_id}, %Membrane.HLS.PackedAACSink{
        packager: state.opts.packager,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], state}
  end

  # EXPERIMENTAL: AAC over TS support is experimental and may have compatibility issues
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC, container: :TS} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> maybe_add_shifter(track_id, state)
      |> via_in(:input, options: [stream_type: :AAC_ADTS])
      |> child({:muxer, track_id}, Membrane.MPEG.TS.Muxer)
      |> child({:aggregator, track_id}, %Membrane.HLS.MPEG.TS.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.TSSink{
        packager: state.opts.packager,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> maybe_add_shifter(track_id, state)
      |> via_in(Pad.ref(:input, track_id))
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> via_out(Pad.ref(:output), options: [tracks: [track_id]])
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        packager: state.opts.packager,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264, container: :TS} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> maybe_add_shifter(track_id, state)
      |> via_in(:input, options: [stream_type: :H264_AVC])
      |> child({:muxer, track_id}, Membrane.MPEG.TS.Muxer)
      |> child({:aggregator, track_id}, %Membrane.HLS.MPEG.TS.Aggregator{
        target_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.TSSink{
        packager: state.opts.packager,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> maybe_add_shifter(track_id, state)
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        packager: state.opts.packager,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], state}
  end

  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :TEXT} = pad_opts},
        state
      ) do
    spec =
      bin_input(pad)
      |> maybe_add_shifter(track_id, state)
      |> child({:cues, track_id}, %Membrane.Subtitles.Builder{
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
        packager: state.opts.packager,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

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

      if state.flush, do: Packager.flush(state.opts.packager)

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
      Packager.flush(state.opts.packager)
      {[notify_parent: {:end_of_stream, true}], %{state | flush: true}}
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
      "Deadline reset. Restoring playlist syncronization in #{Float.round(timeout / 1.0e3, 3)}s"
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

    Packager.sync(state.opts.packager, state.live_state.next_sync_point)

    {[], live_schedule_next_sync(state)}
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

    Membrane.Time.as_milliseconds(safety_delay, :round) + target_segment_duration_ms * 3
  end

  defp live_init_state(state) do
    # Tells where in the playlist we should start issuing segments.
    next_sync_point = Packager.next_sync_point(state.opts.packager)
    now = :erlang.monotonic_time(:millisecond)
    timeout = sync_timeout(state)
    deadline = now + timeout

    Membrane.Logger.info(
      "Deadline reset. Starting playlist syncronization in #{Float.round(timeout / 1.0e3, 3)}s"
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
    child(spec, {:shifter, track_id}, %Membrane.HLS.Shifter{
      duration: track_pts(state.opts.packager, track_id)
    })
  end

  defp track_pts(packager, track_id) do
    case HLS.Packager.track_duration(packager, track_id) do
      {:ok, duration} ->
        duration
        |> Ratio.new()
        |> Membrane.Time.seconds()

      {:error, :not_found} ->
        0
    end
  end
end
