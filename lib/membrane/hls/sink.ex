defmodule Membrane.HLS.Sink do
  use Membrane.Sink
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias HLS.Playlist.Media
  alias HLS.Playlist.Media.Builder

  require Membrane.Logger

  def_options(
    playlist: [
      spec: HLS.Playlist.Media.t(),
      description: "Media playlist tracking the segments"
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
       playlist: opts.playlist
     }}
  end

  def handle_stream_format(_pad, format = %Format.WebVTT{}, _ctx, state = %{playlist: playlist}) do
    state =
      state
      |> Map.put(:builder, Builder.new(playlist, ".vtt"))
      |> Map.put(:format, format)
      |> Map.take([:builder, :format])

    {[], state}
  end

  def handle_stream_format(pad, format, _ctx, state = %{builder: _}) do
    Membrane.Logger.warn(
      "Received stream format from pad #{inspect(pad)} more than once: #{inspect(format)}"
    )

    {[], state}
  end

  def handle_end_of_stream(
        _pad,
        _ctx,
        state
      ) do
    state
    |> update_in([:builder], &Builder.flush(&1))
    |> build_parent_notifications(true)
  end

  def handle_write(
        _pad,
        %Buffer{pts: pts, payload: payload, metadata: %{duration: duration}},
        _ctx,
        state
      ) do
    from = convert_time_to_seconds(pts)
    timed_payload = %{from: from, to: from + convert_time_to_seconds(duration), payload: payload}

    state
    |> update_in([:builder], &Builder.fit(&1, timed_payload))
    |> build_parent_notifications()
  end

  defp build_parent_notifications(state = %{builder: builder, format: format}, force \\ false) do
    {uploadables, builder} = Builder.take_uploadables(builder)

    segment_notifications =
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

        %{uri: uri, type: :segment, format: format, buffers: payload}
      end)
      |> Enum.map(fn payload -> {:notify_parent, {:write, payload}} end)

    playlist_notifications =
      if Enum.empty?(segment_notifications) and not force do
        []
      else
        playlist = %Media{uri: uri} = Builder.playlist(builder)
        [{:notify_parent, {:write, %{uri: uri, type: :playlist, playlist: playlist}}}]
      end

    notifications = segment_notifications ++ playlist_notifications
    {notifications, %{state | builder: builder}}
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
