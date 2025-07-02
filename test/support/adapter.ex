defmodule Support.Adapter do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: _
  )

  def_output_pad(:output,
    accepted_format: _
  )

  def_options(
    output_format: [
      spec: any(),
      description: """
      The output stream format this element should emit
      """
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{output_format: opts.output_format}}
  end

  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, state.output_format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end
end
