defprotocol Membrane.HLS.SegmentContentBuilder do
  alias Membrane.Buffer
  alias HLS.Segment

  @spec format_segment(t(), [Buffer.t()]) :: binary()
  def format_segment(impl, buffers)

  @spec segment_extension(t()) :: binary()
  def segment_extension(impl)

  @spec accept_buffer(t(), Buffer.t()) :: t()
  def accept_buffer(impl, buffer)

  @spec drop_late_buffers(t(), Segment.t()) :: {t(), [Buffer.t()]}
  def drop_late_buffers(impl, segment)

  @spec drop_buffers_in_segment(t(), Segment.t()) :: {t(), [Buffer.t()]}
  def drop_buffers_in_segment(impl, segment)

  @spec is_empty?(t()) :: boolean()
  def is_empty?(impl)
end
