defmodule Membrane.HLS.Playlist.Tag.MediaSequenceNumber do
  use Membrane.HLS.Playlist.Tag, id: :ext_x_media_sequence

  @impl true
  def unmarshal(data), do: capture_value!(data, ~s/\\d+/, &String.to_integer/1)
end
