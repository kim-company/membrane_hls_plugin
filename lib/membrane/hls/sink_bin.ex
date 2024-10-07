defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF
  muxing to eventually store them using provided storage configuration.
  """
  use Membrane.Bin
  alias HLS.Packager

  require Membrane.Logger

  def_options(
    manifest_uri: [
      spec: URI.t(),
      description: """
      Destination URI of the manifest.
      Example: file://output/stream.m3u8
      """
    ],
    storage: [
      spec: HLS.Storage,
      required: true,
      description: """
      Implementation of the storage.
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

  def_input_pad(:input,
    accepted_format: any_of(Membrane.H264, Membrane.AAC, Membrane.Text),
    availability: :on_request,
    options: [
      encoding: [
        spec: :AAC | :H264 | :TEXT,
        description: """
        Encoding type determining which parser will be used for the given stream.
        """
      ],
      build_stream: [
        spec:
          (URI.t(), Membrane.CMAF.Track.t() ->
             HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
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
       flush: opts.flush_on_end,
       packager_pid: nil,
       ended_sinks: MapSet.new(),
       live_state: nil
     }}
  end

  @impl true
  def handle_setup(_context, state) do
    {:ok, packager_pid} =
      Agent.start_link(fn ->
        Packager.new(
          storage: state.opts.storage,
          manifest_uri: state.opts.manifest_uri,
          resume_finished_tracks: true,
          restore_pending_segments: false
        )
      end)

    {[], %{state | packager_pid: packager_pid}}
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

  @impl true
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC} = pad_opts},
        state
      ) do
    {max_pts, _track_pts} = resume_info(state.packager_pid, track_id)

    spec =
      bin_input(pad)
      |> child({:shifter, track_id}, %Membrane.HLS.Shifter{duration: max_pts})
      |> via_in(Pad.ref(:input, track_id))
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> via_out(Pad.ref(:output), options: [tracks: [track_id]])
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        packager_pid: state.packager_pid,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264} = pad_opts},
        state
      ) do
    {max_pts, _track_pts} = resume_info(state.packager_pid, track_id)

    spec =
      bin_input(pad)
      |> child({:shifter, track_id}, %Membrane.HLS.Shifter{duration: max_pts})
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: pad_opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        packager_pid: state.packager_pid,
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
    {max_pts, track_pts} = resume_info(state.packager_pid, track_id)

    spec =
      bin_input(pad)
      |> child({:shifter, track_id}, %Membrane.HLS.Shifter{duration: max_pts})
      |> child({:filler, track_id}, %Membrane.HLS.TextFiller{from: track_pts})
      |> child({:cues, track_id}, %Membrane.WebVTT.CueBuilderFilter{
        min_duration: Membrane.Time.milliseconds(1500)
      })
      |> child({:segments, track_id}, %Membrane.WebVTT.SegmentFilter{
        segment_duration: pad_opts.segment_duration,
        headers: [
          %Subtitle.WebVTT.HeaderLine{key: :description, original: "WEBVTT"}
        ]
      })
      |> child({:sink, track_id}, %Membrane.HLS.WebVTTSink{
        packager_pid: state.packager_pid,
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

      if state.flush do
        Agent.update(state.packager_pid, &Packager.flush/1, :infinity)
        {[notify_parent: :end_of_stream], state}
      else
        {[], state}
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
    if not state.flush and all_streams_ended?(ctx, state.ended_sinks) do
      Agent.update(state.packager_pid, &Packager.flush/1, :infinity)
      {[notify_parent: :end_of_stream], %{state | flush: true}}
    else
      {[], %{state | flush: true}}
    end
  end

  @impl true
  def handle_info(:sync, _ctx, state = %{live_state: %{stop: true}}) do
    {[], state}
  end

  def handle_info(:sync, _ctx, state) do
    Membrane.Logger.debug(
      "Packager: syncing playlists up to #{state.live_state.next_sync_point}s"
    )

    Agent.update(
      state.packager_pid,
      fn p ->
        Packager.sync(p, state.live_state.next_sync_point)
      end,
      :infinity
    )

    {[], live_schedule_next_sync(state)}
  end

  defp all_streams_ended?(ctx, ended_sinks) do
    ctx.children
    |> Map.keys()
    |> Enum.filter(&match?({:sink, _}, &1))
    |> MapSet.new()
    |> MapSet.equal?(ended_sinks)
  end

  defp resume_info(packager_pid, track_id) do
    Agent.get(
      packager_pid,
      fn packager ->
        max_pts =
          Packager.max_track_duration(packager)
          |> Ratio.new()
          |> Membrane.Time.seconds()

        track_pts =
          if Packager.has_track?(packager, track_id) do
            Packager.track_duration(packager, track_id)
            |> Ratio.new()
            |> Membrane.Time.seconds()
          else
            0
          end

        {max_pts, track_pts}
      end,
      :infinity
    )
  end

  defp live_schedule_next_sync(state) do
    state =
      state
      |> update_in([:live_state, :next_sync_point], fn x ->
        x + Membrane.Time.as_seconds(state.opts.target_segment_duration, :round)
      end)
      |> update_in([:live_state, :next_deadline], fn x ->
        x + Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round)
      end)

    Process.send_after(self(), :sync, state.live_state.next_deadline, abs: true)
    state
  end

  defp live_init_state(state) do
    # Tells where in the playlist we should start issuing segments.
    next_sync_point =
      Agent.get(
        state.packager_pid,
        &Packager.next_sync_point(
          &1,
          Membrane.Time.as_seconds(state.opts.target_segment_duration, :round)
        ),
        :infinity
      )

    {:live, safety_delay} = state.opts.mode
    now = :erlang.monotonic_time(:millisecond)

    # We wait until we have at least 3 segments before starting the initial sync process.
    # This ensures a stable, interruption free playback for the clients.
    minimum_segment_time =
      Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round) * 3

    # Tells when we should do it.
    deadline = now + Membrane.Time.as_milliseconds(safety_delay, :round) + minimum_segment_time

    live_state = %{
      next_sync_point: next_sync_point + div(minimum_segment_time, 1000),
      next_deadline: deadline,
      stop: false
    }

    Process.send_after(self(), :sync, deadline, abs: true)

    %{state | live_state: live_state}
  end
end
