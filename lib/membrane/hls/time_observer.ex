defmodule Membrane.HLS.TimeObserver do
  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{observed?: false}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{observed?: false}) do
    state = put_in(state, [:observed?], true)

    actions = [
      notify_parent: {:observed_time, Membrane.Buffer.get_dts_or_pts(buffer)},
      buffer: {:output, buffer}
    ]

    {actions, state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end
end
