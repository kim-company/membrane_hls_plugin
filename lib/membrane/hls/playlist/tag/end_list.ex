defmodule Membrane.HLS.Playlist.Tag.EndList do
  use Membrane.HLS.Playlist.Tag, id: :ext_x_endlist

  @impl true
  def unmarshal(_data), do: true
end
