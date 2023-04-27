defmodule Membrane.HLS.Sink do
  use Membrane.Sink
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias HLS.Playlist.Media
  alias HLS.Segment
  alias HLS.Storage

  require Membrane.Logger

  def_options(
    storage: [
      spec: HLS.Storage.t(),
      description: "HLS.Storage instance pointing to the target HLS playlist"
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
       storage: opts.storage,
       playlist: opts.playlist,
       formatter: opts.segment_formatter,
       extension: "",
       state: :syncing,
       acc: []
     }}
  end

  def handle_stream_format(_pad, %Format.WebVTT{}, _ctx, state) do
    {[], %{state | extension: ".vtt"}}
  end

  def handle_end_of_stream(_pad, _ctx, state = %{acc: []}) do
    {[], state}
  end

  def handle_end_of_stream(
        _pad,
        _ctx,
        state = %{acc: acc, playlist: playlist, formatter: formatter, storage: storage}
      ) do
    %Media{uri: playlist_uri, segments_reversed: [last_segment | _]} = playlist

    payload =
      acc
      |> Enum.reverse()
      |> formatter.()

    Membrane.Logger.debug(
      "Uploading payload #{byte_size(payload)} to #{inspect(last_segment.uri)}"
    )

    Membrane.Logger.debug("Uploading playlist to #{inspect(playlist.uri)}")

    # TODO: upload payload to URI
    # TODO: upload playlist!
    Storage.put_segment(storage, last_segment, payload)
    Storage.put(storage, playlist_uri, HLS.Playlist.marshal(playlist))

    {[], %{state | acc: []}}
  end

  def handle_write(
        pad,
        buffer = %Buffer{pts: pts},
        ctx,
        state = %{state: :syncing, playlist: playlist, extension: extension}
      ) do
    playlist = Media.generate_missing_segments(playlist, convert_time_to_seconds(pts), extension)
    handle_write(pad, buffer, ctx, %{state | state: :operational, playlist: playlist})
  end

  def handle_write(
        _pad,
        buffer = %Buffer{pts: pts},
        _ctx,
        state = %{
          playlist: playlist,
          acc: acc,
          formatter: formatter,
          extension: extension,
          storage: storage
        }
      ) do
    %Media{uri: playlist_uri, segments_reversed: [last_segment | _]} = playlist
    %Segment{from: from, duration: duration} = last_segment
    playback_offset = from + duration

    if convert_time_to_seconds(pts) >= playback_offset do
      # we're ready to ship a segment!
      payload =
        acc
        |> Enum.reverse()
        |> formatter.()

      Membrane.Logger.debug(
        "Uploading payload #{byte_size(payload)} to #{inspect(last_segment.uri)}"
      )

      Membrane.Logger.debug("Uploading playlist to #{inspect(playlist.uri)}")

      # TODO: upload payload to URI
      # TODO: upload playlist!
      Storage.put_segment(storage, last_segment, payload)
      Storage.put(storage, playlist_uri, HLS.Playlist.marshal(playlist))

      playlist =
        Media.generate_missing_segments(playlist, convert_time_to_seconds(pts), extension)

      {[], %{state | playlist: playlist, acc: [buffer]}}
    else
      # accumulate!
      {[], %{state | acc: [buffer | acc]}}
    end
  end

  def default_formatter(buffers) do
    buffers
    |> Enum.map(fn %Buffer{payload: x} -> x end)
    |> Enum.join()
  end

  defp convert_time_to_seconds(time) do
    time
    |> Membrane.Time.as_seconds()
    |> Ratio.to_float()
  end
end
