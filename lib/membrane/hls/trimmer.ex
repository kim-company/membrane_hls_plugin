defmodule Membrane.HLS.Trimmer do
  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{
      queue: :queue.new(),
      time_reference: nil
    }

    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{time_reference: nil}) do
    # We need parent notification first.
    {[], state}
  end

  def handle_end_of_stream(:input, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{time_reference: nil}) do
    state = update_in(state, [:queue], fn q -> :queue.in(buffer, q) end)
    {[], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, filter_buffers(buffer, state.time_reference)}], state}
  end

  @impl true
  def handle_parent_notification({:time_reference, t}, ctx, state) do
    {buffers, state} =
      get_and_update_in(state, [:queue], fn q ->
        {:queue.to_list(q), :queue.new()}
      end)

    buffers = filter_buffers(buffers, t)
    state = put_in(state, [:time_reference], t)

    actions =
      if ctx.pads.input.end_of_stream? do
        [buffer: {:output, buffers}, end_of_stream: :output]
      else
        [buffer: {:output, buffers}]
      end

    {actions, state}
  end

  defp filter_buffers(buffer_or_buffers, before) do
    buffer_or_buffers
    |> List.wrap()
    |> Enum.filter(fn x -> Membrane.Buffer.get_dts_or_pts(x) >= before end)
  end
end
