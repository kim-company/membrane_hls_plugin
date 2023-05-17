defprotocol Membrane.HLS.SegmentFormatter do
  alias Membrane.Buffer
  @spec format_segment(t(), [Buffer.t()]) :: binary()
  def format_segment(impl, buffers)

  @spec segment_extension(t()) :: binary()
  def segment_extension(impl)
end
