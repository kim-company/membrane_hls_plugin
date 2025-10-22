defmodule Membrane.HLS.Filler.Text do
  use Membrane.Filter

  def_input_pad(:input, accepted_format: Membrane.Text)
  def_output_pad(:output, accepted_format: Membrane.Text)

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{
      queue: :queue.new(),
      time_reference: nil,
      time_first_buffer: nil
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

  def handle_buffer(:input, buffer, ctx, state = %{time_first_buffer: nil}) do
    state =
      state
      |> update_in([:queue], fn q -> :queue.in(buffer, q) end)
      |> put_in([:time_first_buffer], Membrane.Buffer.get_dts_or_pts(buffer))

    fill_and_forward(ctx, state)
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_parent_notification({:time_reference, t}, ctx, state) do
    state = put_in(state, [:time_reference], t)

    cond do
      state.time_first_buffer != nil ->
        fill_and_forward(ctx, state)

      ctx.pads.input.end_of_stream? ->
        {[end_of_stream: :output], state}

      true ->
        {[], state}
    end
  end

  defp fill_and_forward(ctx, state) do
    from = state.time_reference
    to = state.time_first_buffer

    filler_buffers =
      if from < to do
        buffer = %Membrane.Buffer{
          payload: "",
          pts: from,
          metadata: %{to: to}
        }

        [buffer]
      else
        []
      end

    {real_buffers, state} =
      get_and_update_in(state, [:queue], fn q ->
        {:queue.to_list(q), :queue.new()}
      end)

    buffers = filler_buffers ++ real_buffers

    actions =
      if ctx.pads.input.end_of_stream? do
        [buffer: {:output, buffers}, end_of_stream: :output]
      else
        [buffer: {:output, buffers}]
      end

    {actions, state}
  end
end
