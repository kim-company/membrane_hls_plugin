defmodule Membrane.HLS.Playlist.Tag.Version do
  use Membrane.HLS.Playlist.Tag, id: :ext_x_version

  @impl true
  def unmarshal(data), do: capture_value!(data, ~s/\\d+/, &String.to_integer/1)
end
