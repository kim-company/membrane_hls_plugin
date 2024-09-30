defmodule Membrane.HLS.Shifter do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: any_of(Membrane.H264, Membrane.AAC, Membrane.Text)
  )

  def_output_pad(:output,
    accepted_format: any_of(Membrane.H264, Membrane.AAC, Membrane.Text)
  )

  def_options(
    duration: [
      spec: Membrane.Time.t()
    ]
  )

  def handle_init(_ctx, opts) do
    {[], %{duration: opts.duration}}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    shifted_buffer = %{
      buffer
      | pts: buffer.pts + state.duration,
        dts: Membrane.Buffer.get_dts_or_pts(buffer) + state.duration,
        metadata: update_metadata(buffer.metadata, state.duration)
    }

    {[buffer: {:output, shifted_buffer}], state}
  end

  def update_metadata(%{to: to} = metadata, duration), do: %{metadata | to: to + duration}
  def update_metadata(metadata, _duration), do: metadata
end
