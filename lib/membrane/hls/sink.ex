defmodule Membrane.HLS.Sink do
  use Membrane.Sink

  alias Membrane.HLS.SegmentContentBuilder, as: SCB
  alias HLS.{Playlist, Segment}
  alias HLS.Playlist.Media.Builder
  alias Membrane.HLS.Writer

  require Membrane.Logger

  def_options(
    playlist: [
      spec: HLS.Playlist.Media.t(),
      description: "Media playlist tracking the segments"
    ],
    writer: [
      spec: Writer.t(),
      description: "Writer implementation that takes care of storing segments and playlist"
    ],
    safety_delay: [
      spec: Membrane.Time.t(),
      description:
        "Safety buffer of time which increases the delay of the sink but ensures that once it starts are included in the segments",
      default: Membrane.Time.milliseconds(100)
    ],
    segment_content_builder: [
      spec: SegmentContentBuilder.t(),
      description:
        "SegmentContentBuilder implementation that takes care of putting buffers in the right segments."
    ],
    write_empty_segment_on_startup: [
      spec: boolean(),
      description: "If true, the component will write the empty segment at startup",
      default: false
    ]
  )

  def_input_pad(:input,
    accepted_format: _any,
    availability: :always
  )

  @impl true
  def handle_init(_ctx, opts) do
    builder =
      Builder.new(opts.playlist,
        segment_extension: SCB.segment_extension(opts.segment_content_builder),
        replace_empty_segments_uri: true
      )

    segment_duration =
      opts.playlist.target_segment_duration
      |> convert_seconds_to_time()

    state = %{
      playlist: opts.playlist,
      writer: opts.writer,
      content_builder: opts.segment_content_builder,
      builder: builder,
      safety_delay: opts.safety_delay,
      interval: segment_duration,
      timer: nil,
      playback: nil
    }

    if opts.write_empty_segment_on_startup do
      write_initial_empty_segment(state)
    else
      {[], state}
    end
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state) do
    state = update_in(state, [:content_builder], &SCB.accept_buffer(&1, buffer))
    {[], state}
  end

  @impl true
  def handle_info(:sync, _ctx, state) do
    state = reload_sync_timer(state)
    {segment_actions, state} = write_next_segment(state)
    {playlist_actions, state} = write_playlist(state)
    {segment_actions ++ playlist_actions, state}
  end

  @impl true
  def handle_parent_notification({:start, playback}, _ctx, state) do
    if state.timer != nil, do: Process.cancel_timer(state.timer)

    Membrane.Logger.info(
      "Syncing playlist #{URI.to_string(state.playlist.uri)} @ #{Membrane.Time.pretty_duration(playback)}"
    )

    {segments, builder} = Builder.sync(state.builder, Membrane.Time.as_seconds(playback, :round))
    state = %{state | builder: builder}

    {segment_actions, state} =
      Enum.reduce(segments, {[], state}, fn segment, {actions, state} ->
        {new_actions, state} = write_and_ack([], segment, state)
        {actions ++ new_actions, state}
      end)

    t = Membrane.Time.monotonic_time() + state.safety_delay + state.interval

    timer =
      Process.send_after(self(), :sync, :erlang.convert_time_unit(t, :nanosecond, :millisecond),
        abs: true
      )

    state = %{state | timer: timer, playback: t}

    {playlist_actions, state} =
      unless Enum.empty?(segment_actions) do
        write_playlist(state)
      else
        {[], state}
      end

    {segment_actions ++ playlist_actions, state}
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    if state.timer != nil, do: Process.cancel_timer(state.timer)

    {actions, state} = flush_and_write_playlist(state, [])
    {actions ++ [notify_parent: :end_of_stream], state}
  end

  defp flush_and_write_playlist(state, acc) do
    {segment_actions, state} = write_next_segment(state, true)

    if SCB.is_empty?(state.content_builder) do
      {playlist_actions, state} = write_playlist(state, true)
      {acc ++ segment_actions ++ playlist_actions, state}
    else
      flush_and_write_playlist(state, acc ++ segment_actions)
    end
  end

  defp write_next_segment(state, disable_pending \\ false) do
    {segment, builder} = Builder.next_segment(state.builder)

    {content_builder, late_buffers} = SCB.drop_late_buffers(state.content_builder, segment)

    {content_builder, buffers} =
      SCB.drop_buffers_in_segment(content_builder, segment, disable_pending)

    state = %{state | content_builder: content_builder, builder: builder}

    segment =
      if Enum.empty?(buffers) do
        %Segment{segment | uri: Builder.empty_segment_uri(builder)}
      else
        segment
      end

    {segment_actions, state} = write_and_ack(buffers, segment, state)

    actions =
      List.flatten([
        segment_actions,
        unless(Enum.empty?(late_buffers),
          do: [
            notify_parent:
              {:segment, :write, {:error, :late_buffers},
               %{buffers: late_buffers, uri: segment.uri, segment: segment}}
          ],
          else: []
        )
      ])

    {actions, state}
  end

  defp reload_sync_timer(state) do
    t = state.playback + state.interval

    timer =
      Process.send_after(self(), :sync, :erlang.convert_time_unit(t, :nanosecond, :millisecond),
        abs: true
      )

    %{state | timer: timer, playback: t}
  end

  defp write_playlist(state, finished? \\ false) do
    playlist = %Playlist.Media{Builder.playlist(state.builder) | finished: finished?}
    payload = Playlist.marshal(playlist)

    last_segment = List.last(playlist.segments)

    playback =
      if is_nil(last_segment) do
        0
      else
        convert_seconds_to_time(last_segment.from + last_segment.duration)
      end

    start_at = DateTime.utc_now()
    response = Writer.write(state.writer, playlist.uri, payload)
    latency = DateTime.diff(DateTime.utc_now(), start_at, :nanosecond)

    metadata = %{
      pts: playback,
      byte_size: byte_size(payload),
      latency: latency,
      uri: playlist.uri
    }

    notifications =
      case response do
        :ok ->
          [notify_parent: {:playlist, :write, :ok, metadata}]

        {:error, reason} ->
          [notify_parent: {:playlist, :write, {:error, reason}, metadata}]
      end

    {notifications, state}
  end

  defp write_initial_empty_segment(state) do
    uri =
      Playlist.Media.build_segment_uri(
        state.playlist.uri,
        Builder.empty_segment_uri(state.builder)
      )

    payload = SCB.format_segment(state.content_builder, [])
    response = Writer.write(state.writer, uri, payload)

    metadata = %{uri: uri}

    notifications =
      case response do
        :ok ->
          [notify_parent: {:empty_segment, :write, :ok, metadata}]

        {:error, reason} ->
          [notify_parent: {:empty_segment, :write, {:error, reason}, metadata}]
      end

    {notifications, state}
  end

  defp write_and_ack(buffers, segment, state) do
    start_at = DateTime.utc_now()
    playlist_uri = Builder.playlist(state.builder).uri
    uri = Playlist.Media.build_segment_uri(playlist_uri, segment.uri)
    payload = SCB.format_segment(state.content_builder, buffers)
    response = Writer.write(state.writer, uri, payload)
    latency = DateTime.diff(DateTime.utc_now(), start_at, :nanosecond)

    metadata = %{
      pts: convert_seconds_to_time(segment.from),
      byte_size: byte_size(payload),
      latency: latency,
      uri: uri
    }

    id = if Enum.empty?(buffers), do: :empty_segment, else: :segment

    {notifications, builder} =
      case response do
        :ok ->
          {[notify_parent: {id, :write, :ok, metadata}],
           Builder.ack(state.builder, segment.ref, Enum.empty?(buffers))}

        {:error, reason} ->
          {[notify_parent: {id, :write, {:error, reason}, metadata}],
           Builder.nack(state.builder, segment.ref)}
      end

    {notifications, %{state | builder: builder}}
  end

  defp convert_seconds_to_time(seconds) do
    (seconds * 1_000)
    |> trunc()
    |> Membrane.Time.milliseconds()
  end
end
