defmodule HLS.Playlist.Tag.VariantStream do
  use HLS.Playlist.Tag, id: :ext_x_stream_inf

  @impl true
  def is_multiline?(), do: true

  @impl true
  def unmarshal([stream_info, stream_uri]) do
    stream_info
    |> capture_attribute_list!(fn
      "BANDWIDTH", val ->
        {:bandwidth, String.to_integer(val)}

      "AVERAGE-BANDWIDTH", val ->
        {:average_bandwidth, String.to_integer(val)}

      "CODECS", val ->
        {:codecs, String.split(val, ",")}

      "AUDIO", val ->
        {:audio, val}

      "VIDEO", val ->
        {:video, val}

      "SUBTITLES", val ->
        {:subtitles, val}

      "CLOSED-CAPTIONS", val ->
        {:closed_captions, val}

      "FRAME-RATE", val ->
        {:frame_rate, String.to_float(val)}

      "RESOLUTION", val ->
        [width, height] =
          val
          |> String.split("x")
          |> Enum.map(&String.to_integer/1)

        {:resolution, {width, height}}

      _key, _val ->
        :skip
    end)
    |> Map.put_new(:uri, URI.parse(stream_uri))
  end
end
