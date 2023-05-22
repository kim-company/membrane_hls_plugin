defmodule Membrane.HLS.Sink do
  use Membrane.Sink
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias Membrane.HLS.SegmentFormatter
  alias HLS.Playlist
  alias HLS.Playlist.Media.Builder
  alias HLS.Segment

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
    formatter: [
      spec: SegmentFormatter.t(),
      description: "SegmentFormatter implementation that formats buffers into segments"
    ]
  )

  def_input_pad(:input,
    accepted_format: any_of(Format.WebVTT, Format.MPEG, Format.PackedAudio),
    availability: :always,
    demand_mode: :auto,
    mode: :pull
  )

  @impl true
  def handle_init(_ctx, opts) do
    extension = SegmentFormatter.segment_extension(opts.formatter)

    builder =
      Builder.new(opts.playlist, segment_extension: extension, replace_empty_segments_uri: true)

    {[],
     %{
       playlist: opts.playlist,
       writer: opts.writer,
       formatter: opts.formatter,
       builder: builder
     }}
  end

  def handle_end_of_stream(
        _pad,
        _ctx,
        state
      ) do
    write_segments_and_playlist(state, true)
  end

  def handle_write(
        _pad,
        buffer,
        _ctx,
        state
      ) do
    timed_payload = buffer_to_timed_payload(buffer)

    state
    |> update_in([:builder], &Builder.fit(&1, timed_payload))
    |> write_segments_and_playlist()
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
