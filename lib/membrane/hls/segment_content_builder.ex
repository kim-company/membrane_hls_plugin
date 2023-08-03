defprotocol Membrane.HLS.SegmentContentBuilder do
  alias Membrane.Buffer
  alias HLS.Segment

  @spec format_segment(t(), [Buffer.t()]) :: binary()
  def format_segment(impl, buffers)

  @spec segment_extension(t()) :: binary()
  def segment_extension(impl)

  @spec accept_buffer(t(), Buffer.t()) :: t()
  def accept_buffer(impl, buffer)

  @spec drop_buffers_before_segment(t(), Segment.t()) :: {t(), [Buffer.t()]}
  def drop_buffers_before_segment(impl, segment)

  @spec fit_in_segment(t(), Segment.t()) :: {t(), [Buffer.t()], boolean()}
  def fit_in_segment(impl, segment)
end
