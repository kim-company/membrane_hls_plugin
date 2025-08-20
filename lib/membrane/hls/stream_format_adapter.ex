defmodule Membrane.HLS.StreamFormatAdapter do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: _any
  )

  def_output_pad(:output,
    accepted_format: _any
  )

  def_options(
    stream_format: [
      spec: module() | struct(),
      description: "The stream format to forward",
      default: %Membrane.RemoteStream{}
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{stream_format: opts.stream_format}}
  end

  @impl true
  def handle_stream_format(_pad, _format, _ctx, state) do
    {[stream_format: {:output, state.stream_format}], state}
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state) do
    {[forward: buffer], state}
  end
end