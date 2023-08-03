defmodule Membrane.HLS.Sink do
  use Membrane.Sink
  alias Membrane.Buffer
  alias Membrane.HLS.SegmentContentBuilder, as: SCB
  alias HLS.{Playlist, Segment}
  alias HLS.Playlist.Media.Builder

  require Membrane.Logger

  def_options(
    playlist: [
      spec: HLS.Playlist.Media.t(),
      description: "Media playlist tracking the segments"
    ],
    writer: [
      spec: HLS.FS.Writer.t(),
      description: "Writer implementation that takes care of storing segments and playlist"
    ],
    safety_delay: [
      spec: Membrane.Time.t(),
      description:
        "Safety buffer of time which increases the delay of the sink but ensures that once it starts are included in the segments"
    ],
    content_builder: [
      spec: SegmentContentBuilder.t(),
      description:
        "SegmentContentBuilder implementation that takes care of putting buffers in the right segments."
    ]
  )

  def_input_pad(:input,
    accepted_format: _any,
    availability: :always,
    demand_mode: :auto,
    mode: :pull
  )

  @impl true
  def handle_init(_ctx, opts) do
    extension = SCB.segment_extension(opts.content_builder)

    builder =
      Builder.new(opts.playlist, segment_extension: extension, replace_empty_segments_uri: true)

    {[],
     %{
       playlist: opts.playlist,
       writer: opts.writer,
       content_builder: opts.content_builder,
       builder: builder
     }}
  end

  @impl true
  def handle_write(_pad, buffer, _ctx, state) do
    state = update_in(state, [:content_builder], &SCB.accept_buffer(&1, buffer))
    {[], state}
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    # TODO: flush everythin and write the playlist.
    # write_segments_and_playlist(state, true)
    {[], state}
  end

  defp write_segments_and_playlist(
         state = %{builder: builder, writer: writer, formatter: formatter},
         force \\ false
       ) do
    {uploadables, builder} = Builder.pop(builder, force: force)
    playlist_uri = Builder.playlist(builder).uri

    builder =
      Enum.reduce(uploadables, builder, fn uploadable, builder ->
        buffers =
          uploadable.payloads
          |> Enum.map(fn %{from: from, to: to, payload: payload} ->
            pts = convert_seconds_to_time(from)

            %Buffer{
              pts: pts,
              payload: payload,
              metadata: %{
                duration: convert_seconds_to_time(to) - pts
              }
            }
          end)

        payload = SegmentFormatter.format_segment(formatter, buffers)

        if write(
             writer,
             Playlist.Media.build_segment_uri(playlist_uri, uploadable.segment.uri),
             payload,
             convert_seconds_to_time(uploadable.from)
           ) do
          Builder.ack(builder, uploadable.ref)
        else
          Builder.nack(builder, uploadable.ref)
        end
      end)

    actions =
      if not Enum.empty?(uploadables) or force do
        playlist = %Playlist.Media{Builder.playlist(builder) | finished: force}
        payload = Playlist.marshal(playlist)

        duration =
          playlist.segments
          |> Enum.map(fn %Segment{duration: duration} -> duration end)
          |> Enum.sum()
          |> convert_seconds_to_time()

        if write(writer, playlist.uri, payload, duration) do
          [notify_parent: {:wrote_playlist, playlist.uri, duration}]
        else
          []
        end
      else
        []
      end

    {actions, %{state | builder: builder}}
  end

  @impl true
  def handle_info(:sync, _ctx, state) do
    {segment, builder} = Builder.next_segment(state.builder)

    {late_buffers, content_builder} =
      SCB.drop_buffers_before_segment(state.content_builder, segment)

    {buffers, content_builder, _} = SCB.fit_in_segment(content_builder, segment)

    # We could also send a notification to the pipeline and handle
    # this case there. We might consider restarting it.
    unless Enum.empty?(late_buffers) do
      Membrane.Logger.warn(
        "SegmentContentBuilder received buffers that came too late: #{inspect(late_buffers)}"
      )
    end

    write_and_ack(buffers, segment, %{
      state
      | content_builder: content_builder,
        builder: builder
    })
    |> write_playlist_with_actions()
  end

  defp write_next_segment(state) do
    {segment, builder} = Builder.next_segment(state.builder)

    {late_buffers, content_builder} =
      SCB.drop_buffers_before_segment(state.content_builder, segment)

    {buffers, content_builder, _} = SCB.fit_in_segment(content_builder, segment)

    # We could also send a notification to the pipeline and handle
    # this case there. We might consider restarting it.
    unless Enum.empty?(late_buffers) do
      Membrane.Logger.warn(
        "SegmentContentBuilder received buffers that came too late: #{inspect(late_buffers)}"
      )
    end

    write_and_ack(buffers, segment, %{
      state
      | content_builder: content_builder,
        builder: builder
    })
    |> write_playlist_with_actions()
  end

  @impl true
  def handle_parent_notification({:start, playback}, _ctx, state) do
    t = Membrane.Time.monotonic_time() + state.safety_delay
    {segments, builder} = Builder.sync(state.builder, Membrane.Time.round_to_seconds(playback))
    state = %{state | builder: builder, absolute_time: t, playback: t}

    state =
      segments
      |> Enum.reduce(state, &write_and_ack([], &1, &2))
      |> reload_sync_timer()

    write_playlist_with_actions(state)
  end

  defp reload_sync_timer(state) do
    send_at = state.playback + Builder.playlist(state.builder).target_segment_duration

    timer =
      Process.send_after(
        self(),
        :sync,
        :erlang.convert_time_unit(send_at, :nanosecond, :millisecond),
        abs: true
      )

    %{state | timer: timer, playback: send_at}
  end

  defp write_playlist_with_actions(state, finished? \\ false) do
    playlist = %Playlist.Media{Builder.playlist(state.builder) | finished: finished?}
    payload = Playlist.marshal(playlist)

    duration =
      playlist.segments
      |> Enum.map(fn %Segment{duration: duration} -> duration end)
      |> Enum.sum()
      |> convert_seconds_to_time()

    actions =
      if write(state.writer, playlist.uri, payload, duration) do
        [notify_parent: {:wrote_playlist, playlist.uri, duration}]
      else
        []
      end

    {actions, state}
  end

  defp write_and_ack(buffers, segment, state) do
    playlist_uri = Builder.playlist(state.builder).uri
    payload = SCB.format_segment(state.content_builder, buffers)

    builder =
      if write(
           state.writer,
           Playlist.Media.build_segment_uri(playlist_uri, segment.uri),
           payload,
           convert_seconds_to_time(segment.from)
         ) do
        Builder.ack(state.builder, segment.ref)
      else
        Builder.nack(state.builder, segment.ref)
      end

    %{state | builder: builder}
  end

  defp write(writer, uri, payload, pts) do
    start_at = DateTime.utc_now()

    response = HLS.FS.Writer.write(writer, uri, payload)
    latency = DateTime.diff(DateTime.utc_now(), start_at, :nanosecond)

    case response do
      :ok ->
        Membrane.Logger.info(
          "wrote uri #{inspect(URI.to_string(uri))}",
          %{
            type: :latency,
            origin: "hls.sink",
            latency: latency,
            input: %{
              pts: pts,
              byte_size: byte_size(payload)
            }
          }
        )

        true

      {:error, reason} ->
        Membrane.Logger.warn(
          "write failed for uri #{inspect(URI.to_string(uri))} with reason: #{inspect(reason)}",
          %{
            type: :latency,
            origin: "hls.sink",
            latency: latency,
            input: %{
              pts: pts,
              byte_size: byte_size(payload)
            }
          }
        )

        false
    end
  end

  defp convert_time_to_seconds(time) do
    time
    |> Membrane.Time.as_seconds()
    |> Ratio.to_float()
  end

  defp convert_seconds_to_time(seconds) do
    (seconds * 1_000_000_000)
    |> trunc()
    |> Membrane.Time.nanoseconds()
  end

  defp buffer_to_timed_payload(%Buffer{
         pts: pts,
         payload: payload,
         metadata: %{duration: duration}
       }) do
    from = convert_time_to_seconds(pts)
    %{from: from, to: from + convert_time_to_seconds(duration), payload: payload}
  end
end
