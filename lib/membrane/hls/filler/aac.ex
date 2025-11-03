defmodule Membrane.HLS.Filler.AAC do
  use Membrane.Filter

  @silent_frames %{
    1 => <<222, 2, 0, 76, 97, 118, 99, 54, 48, 46, 51, 49, 46, 49, 48, 50, 0, 2, 48, 64, 14>>,
    2 =>
      <<255, 241, 80, 128, 3, 223, 252, 222, 2, 0, 76, 97, 118, 99, 53, 56, 46, 57, 49, 46, 49,
        48, 48, 0, 66, 32, 8, 193, 24, 56>>
  }

  def_input_pad(:input,
    accepted_format: %Membrane.AAC{profile: :LC, channels: channels} when channels in [1, 2]
  )

  def_output_pad(:output, accepted_format: Membrane.AAC)

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
  def handle_parent_notification({:time_reference, t}, ctx, state = %{time_reference: nil}) do
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

  def handle_parent_notification(_, _ctx, state) do
    {[], state}
  end

  defp fill_and_forward(ctx, state) do
    from = state.time_reference
    to = state.time_first_buffer

    filler_buffers =
      if from < to do
        generate_buffers(from, to, ctx.pads.input.stream_format)
      else
        # Either its zero or negative (hence trimmer did not do its job).
        # In any case, we don't have to add anything.
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

  defp generate_buffers(from, to, stream_format) do
    frame_duration =
      round(stream_format.samples_per_frame / stream_format.sample_rate * Membrane.Time.second())

    # We have to produce the buffers backward to avoid creating
    # a gap between the real buffers and the filler ones.

    Stream.resource(
      fn -> {from, to - frame_duration} end,
      fn {from, to} ->
        if from > to do
          {:halt, {from, to}}
        else
          buffer = %Membrane.Buffer{
            pts: to,
            payload: @silent_frames[stream_format.channels]
          }

          {[buffer], {from, to - frame_duration}}
        end
      end,
      fn _ -> :ok end
    )
    |> Enum.reverse()
  end
end
