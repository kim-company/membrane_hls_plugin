defmodule Membrane.HLS.TextFiller do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: Membrane.Text
  )

  def_output_pad(:output,
    accepted_format: Membrane.Text
  )

  def_options(
    start_pts: [
      spec: Membrane.Time.t()
    ],
    fill_duration: [
      spec: Membrane.Time.t()
    ]
  )

  def handle_init(_ctx, opts) do
    {[], %{opts: opts, filled: false}}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    start_pts = state.opts.start_pts

    shifted_buffer = %{
      buffer
      | pts: buffer.pts + start_pts,
        metadata: %{to: buffer.metadata.to + start_pts}
    }

    if state.filled do
      {[buffer: {:output, shifted_buffer}], state}
    else
      silence_buffer = %Membrane.Buffer{
        payload: "",
        pts: start_pts - state.opts.fill_duration,
        metadata: %{to: start_pts}
      }

      {[
         buffer: {:output, silence_buffer},
         buffer: {:output, shifted_buffer}
       ], %{state | filled: true}}
    end
  end
end
