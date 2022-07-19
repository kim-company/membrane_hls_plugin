defmodule HLS.Playlist.Tag.TargetSegmentDuration do
  use HLS.Playlist.Tag, id: :ext_x_targetduration

  @impl true
  def unmarshal(data), do: capture_value!(data, ~s/\\d+/, &String.to_integer/1)
end
