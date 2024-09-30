defmodule Membrane.HLS.TextFiller do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: Membrane.Text
  )

  def_output_pad(:output,
    accepted_format: Membrane.Text
  )

  def_options(
    from: [
      spec: Membrane.Time.t()
    ]
  )

  def handle_init(_ctx, opts) do
    {[], %{from: opts.from, filled: false}}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    if state.filled do
      {[forward: buffer], state}
    else
      Membrane.Logger.debug(
        "Generated empty text buffer with a duration of #{buffer.pts - state.from - Membrane.Time.millisecond()}"
      )

      silence_buffer = %Membrane.Buffer{
        payload: "",
        pts: state.from,
        metadata: %{to: buffer.pts - Membrane.Time.millisecond()}
      }

      {[buffer: {:output, [silence_buffer, buffer]}], %{state | filled: true}}
    end
  end
end
