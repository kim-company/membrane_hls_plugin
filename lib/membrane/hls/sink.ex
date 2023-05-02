defmodule Membrane.HLS.Sink do
  use Membrane.Sink
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias HLS.Playlist.Media
  alias HLS.{Storage, Playlist}
  alias HLS.Playlist.Media.Builder

  require Membrane.Logger

  def_options(
    writer: [
      spec: HLS.Storage.t(),
      description: "HLS.Storage instance used to upload segments"
    ],
    playlist: [
      spec: HLS.Playlist.Media.t(),
      description: "Media playlist tracking the segments"
    ],
    segment_formatter: [
      spec: ([Buffer.t()] -> binary()),
      description: "Function responsible for formatting buffer payloads into a unique Segment",
      default: &__MODULE__.default_formatter/1
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
    {[],
     %{
       writer: opts.writer,
       playlist: opts.playlist,
       formatter: opts.segment_formatter
     }}
  end

  def handle_stream_format(_pad, %Format.WebVTT{}, _ctx, state = %{playlist: playlist}) do
    state =
      state
      |> Map.put(:builder, Builder.new(playlist, ".vtt"))
      |> Map.take([:builder, :writer, :formatter])

    {[], state}
  end

  def handle_stream_format(_pad, format, _ctx, state = %{builder: _}) do
    Membrane.Logger.warn("Received stream format more than once: #{inspect(format)}")
    {[], state}
  end

  def handle_end_of_stream(
        _pad,
        _ctx,
        state = %{builder: builder}
      ) do
    %{state | builder: Builder.flush(builder)}
    |> take_and_upload_segments()
    |> upload_playlist()

    {[], state}
  end

  def handle_write(
        _pad,
        %Buffer{pts: pts, payload: payload, metadata: %{duration: duration}},
        _ctx,
        state = %{builder: builder}
      ) do
    from = convert_time_to_seconds(pts)
    timed_payload = %{from: from, to: from + convert_time_to_seconds(duration), payload: payload}

    state =
      %{state | builder: Builder.fit(builder, timed_payload)}
      |> take_and_upload_segments()
      |> upload_playlist()

    {[], state}
  end

  def default_formatter(buffers) do
    buffers
    |> Enum.map(fn %Buffer{payload: x} -> x end)
    |> Enum.join()
  end

  defp take_and_upload_segments(state = %{builder: builder, formatter: formatter, writer: writer}) do
    {uploadables, builder} = Builder.take_uploadables(builder)

    uploadables
    |> Enum.map(fn %{uri: uri, payload: payloads} ->
      payload =
        payloads
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
        |> formatter.()

      %{uri: uri, payload: payload}
    end)
    |> Enum.each(fn %{uri: uri, payload: payload} ->
      Membrane.Logger.debug("Uploading payload #{byte_size(payload)} to #{inspect(uri)}")

      Storage.write(writer, uri, payload)
    end)

    %{state | builder: builder}
  end

  defp upload_playlist(state = %{builder: builder, writer: writer}) do
    # Upload the playlist
    playlist = %Media{uri: uri} = Builder.playlist(builder)
    payload = Playlist.marshal(playlist)
    Membrane.Logger.debug("Uploading playlist to #{inspect(uri)}")
    Storage.write(writer, uri, payload)
    state
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
end
