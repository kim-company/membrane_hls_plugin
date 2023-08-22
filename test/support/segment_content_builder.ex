defmodule Support.SegmentContentBuilder do
  defstruct acc: []
end

defimpl Membrane.HLS.SegmentContentBuilder, for: Support.SegmentContentBuilder do
  alias Support.SegmentContentBuilder, as: SCB

  @impl true
  def format_segment(_, buffers) do
    buffers
    |> Enum.map(fn buffer -> buffer.payload end)
    |> Enum.join()
  end

  @impl true
  def segment_extension(_), do: ".txt"

  @impl true
  def accept_buffer(scb, buffer) do
    %SCB{acc: [buffer | scb.acc]}
  end

  @impl true
  def drop_late_buffers(state, segment) do
    from = Membrane.Time.seconds(ceil(segment.from))
    {valid, before} = Enum.split_while(state.acc, fn buffer -> buffer.pts >= from end)
    {%SCB{acc: valid}, before}
  end

  @impl true
  def drop_buffers_in_segment(state, segment) do
    to = Membrane.Time.seconds(ceil(segment.from + segment.duration))
    {future, valid} = Enum.split_while(state.acc, fn buffer -> buffer.pts > to end)
    {%SCB{acc: future}, valid}
  end

  @impl true
  def is_empty?(state), do: Enum.empty?(state.acc)
end
