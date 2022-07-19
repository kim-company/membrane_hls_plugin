defmodule HLS.Playlist.Tag.EndList do
  use HLS.Playlist.Tag, id: :ext_x_endlist

  @impl true
  def unmarshal(_data), do: true
end
