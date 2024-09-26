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
    ]
  )

  def_input_pad(:input,
    accepted_format: any_of(Membrane.H264, Membrane.AAC),
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
      ]
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts, packager_pid: nil, ended_sinks: MapSet.new(), live_state: nil}}
  end

  @impl true
  def handle_setup(_context, state) do
    {:ok, packager_pid} =
      Agent.start_link(fn ->
        Packager.new(
          storage: state.opts.storage,
          manifest_uri: state.opts.manifest_uri,
          resume_finished_tracks: true
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
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: encoding} = pad_opts},
        state
      )
      when encoding in [:H264, :AAC] do
    spec = [
      bin_input(pad)
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        # The minimum duration of the CMAF will be one second less than the actual target duration.
        # This requires that the H264 stream has a keyframe at least every second.
        segment_min_duration: state.opts.target_segment_duration - Membrane.Time.second()
      })
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        packager_pid: state.packager_pid,
        track_id: track_id,
        target_segment_duration: state.opts.target_segment_duration,
        build_stream: pad_opts.build_stream
      })
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_element_end_of_stream({:sink, _track_id} = sink, _pad, ctx, state) do
    all_sinks =
      ctx.children
      |> Map.keys()
      |> Enum.filter(&match?({:sink, _}, &1))
      |> MapSet.new()

    ended_sinks = MapSet.put(state.ended_sinks, sink)

    if MapSet.equal?(all_sinks, ended_sinks) do
      Agent.update(state.packager_pid, &Packager.flush(&1))

      state =
        state
        |> put_in([:live_state], %{stop: true})
        |> put_in([:ended_sinks], ended_sinks)

      {[notify_parent: :end_of_stream], state}
    else
      {[], %{state | ended_sinks: ended_sinks}}
    end
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info(:sync, _ctx, state = %{live_state: %{stop: true}}) do
    {[], state}
  end

  def handle_info(:sync, _ctx, state) do
    Membrane.Logger.debug("Packager: syncing playlists")

    Agent.update(state.packager_pid, fn p ->
      Packager.sync(p, state.live_state.next_sync_point)
    end)

    {[], live_schedule_next_sync(state)}
  end

  defp live_schedule_next_sync(state) do
    state =
      state
      |> update_in([:live_state, :next_sync_point], fn x ->
        x + state.opts.target_segment_duration
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
        &Packager.next_sync_point(&1, state.opts.target_segment_duration)
      )

    {:live, safety_delay} = state.opts.mode
    now = :erlang.monotonic_time(:millisecond)

    # Tells when we should do it.
    deadline =
      now + Membrane.Time.as_milliseconds(state.opts.target_segment_duration, :round) +
        Membrane.Time.as_milliseconds(safety_delay, :round)

    live_state = %{
      next_sync_point: next_sync_point,
      next_deadline: deadline,
      stop: false
    }

    Process.send_after(self(), :sync, deadline, abs: true)

    %{state | live_state: live_state}
  end
end
