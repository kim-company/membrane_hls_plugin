defmodule Support.SegmentFormatter do
  defstruct []
end

defimpl Membrane.HLS.SegmentFormatter, for: Support.SegmentFormatter do
  def format_segment(_, buffers) do
    buffers
    |> Enum.map(fn buffer -> buffer.payload end)
    |> Enum.join()
  end

  def segment_extension(_), do: ".txt"
end
