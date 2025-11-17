defmodule Membrane.HLS.MPEG.TS.Aggregator do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: Membrane.RemoteStream
  )

  def_output_pad(:output,
    accepted_format: Membrane.RemoteStream
  )

  def_options(
    target_duration: [
      spec: Membrane.Time.t(),
      default: Membrane.Time.seconds(2),
      description: """
      Segments will converge to this duration. When a segment exceeds the target,
      the excess is credited to the next segment to maintain average duration.
      """
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      target_duration: opts.target_duration,
      acc: [],
      pts: nil,
      dts: nil,
      accumulated_offset: 0
    }

    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{acc: []}) do
    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(:input, _ctx, state) do
    {buffer, state} = finalize_segment(state)
    {[buffer: {:output, buffer}, end_of_stream: :output], state}
  end

  @impl true
  def handle_buffer(:input, buffer = %{pts: nil}, _ctx, state) do
    # This might be a PAT/PMT buffer which does not have PTS information.
    state = add_frame(state, buffer)
    {[], state}
  end

  def handle_buffer(
        :input,
        buffer = %{metadata: %{pusi: true}},
        _ctx,
        state = %{pts: nil}
      ) do
    {[], init_segment(state, buffer)}
  end

  def handle_buffer(:input, buffer = %{metadata: %{rai: true}}, _ctx, state) do
    actual_duration = buffer.pts - state.pts
    duration = state.accumulated_offset + actual_duration

    if duration >= state.target_duration do
      {output, state} = finalize_segment(state, actual_duration)
      state = init_segment(state, buffer)
      {[buffer: {:output, output}], state}
    else
      state = add_frame(state, buffer)
      {[], state}
    end
  end

  def handle_buffer(:input, buffer, _ctx, state = %{acc: []}) do
    Membrane.Logger.warning(
      "Received buffer before PUSI indicator -- dropping (pts: #{buffer.pts})"
    )

    # We're waiting until the first buffer with PUSI indicator set before
    # starting a new segment.
    {[], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    state = add_frame(state, buffer)
    {[], state}
  end

  defp init_segment(state, buffer) do
    state
    |> update_in([:acc], fn acc -> [buffer | acc] end)
    |> put_in([:pts], buffer.pts)
    |> put_in([:dts], buffer.dts)
  end

  defp add_frame(state, buffer) do
    state
    |> update_in([:acc], fn acc -> [buffer | acc] end)
  end

  defp finalize_segment(state) do
    buffers = Enum.reverse(state.acc)
    duration = List.last(buffers).pts - state.pts
    finalize_segment(state, duration)
  end

  defp finalize_segment(state, duration) do
    buffers = Enum.reverse(state.acc)

    units = Enum.flat_map(buffers, fn x -> Map.get(x.metadata, :units, []) end)

    payload =
      buffers
      |> Enum.map(fn x -> x.payload end)
      |> Enum.join(<<>>)

    buffer = %Membrane.Buffer{
      payload: payload,
      pts: state.pts,
      dts: state.dts,
      metadata: %{pusi: true, duration: duration, units: units}
    }

    # Calculate offset to carry forward to next segment
    offset = duration - state.target_duration

    state =
      state
      |> put_in([:acc], [])
      |> put_in([:pts], nil)
      |> put_in([:dts], nil)
      |> update_in([:accumulated_offset], fn current_offset -> current_offset + offset end)

    {buffer, state}
  end
end
