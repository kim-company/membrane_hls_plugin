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
      ts: nil,
      pts: nil,
      dts: nil,
      last_ts: nil,
      last_duration: nil,
      accumulated_offset: 0,
      pat_pmt: %{pat: nil, pmt: nil}
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

  def handle_buffer(
        :input,
        buffer = %{metadata: %{pid: 0}},
        _ctx,
        state
      ) do
    {[], put_in(state, [:pat_pmt, :pat], buffer)}
  end

  def handle_buffer(
        :input,
        buffer = %{metadata: %{pid: 0x1000}},
        _ctx,
        state
      ) do
    {[], put_in(state, [:pat_pmt, :pmt], buffer)}
  end

  @impl true
  def handle_buffer(:input, %{pts: nil}, _ctx, state) do
    # Drop packets without timing info (PAT/PMT are cached via PID handlers).
    {[], state}
  end

  def handle_buffer(
        :input,
        buffer = %{metadata: %{pusi: true, rai: true}},
        _ctx,
        state = %{ts: nil}
      ) do
    {[], init_segment(state, buffer)}
  end

  def handle_buffer(
        :input,
        %{metadata: %{pusi: true}},
        _ctx,
        state = %{ts: nil}
      ) do
    {[], state}
  end

  def handle_buffer(:input, buffer = %{metadata: %{rai: true}}, _ctx, state) do
    buffer_ts = Membrane.Buffer.get_dts_or_pts(buffer)
    duration = state.accumulated_offset + (buffer_ts - state.ts)

    if duration >= state.target_duration do
      {output, state} = finalize_segment(state, duration)
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
    pat_pmt =
      [state.pat_pmt.pmt, state.pat_pmt.pat]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&retime_psi(&1, buffer))
    buffer_ts = Membrane.Buffer.get_dts_or_pts(buffer)

    state
    |> update_in([:acc], fn acc -> [buffer | pat_pmt ++ acc] end)
    |> put_in([:ts], buffer_ts)
    |> put_in([:pts], buffer.pts)
    |> put_in([:dts], buffer.dts)
    |> put_in([:last_ts], buffer_ts)
    |> put_in([:last_duration], nil)
  end

  defp retime_psi(%Membrane.Buffer{} = psi_buffer, %Membrane.Buffer{} = ts_buffer) do
    %Membrane.Buffer{psi_buffer | pts: ts_buffer.pts, dts: ts_buffer.dts}
  end

  defp add_frame(state, buffer) do
    buffer_ts = Membrane.Buffer.get_dts_or_pts(buffer)

    state =
      if state.last_ts != nil and buffer_ts != nil and buffer_ts != state.last_ts do
        last_duration = buffer_ts - state.last_ts

        state
        |> put_in([:last_duration], last_duration)
        |> put_in([:last_ts], buffer_ts)
      else
        state
      end

    update_in(state, [:acc], fn acc -> [buffer | acc] end)
  end

  defp finalize_segment(state) do
    buffers = Enum.reverse(state.acc)
    last_ts = Membrane.Buffer.get_dts_or_pts(List.last(buffers))

    duration =
      case state.last_duration do
        nil -> last_ts - state.ts
        last_duration -> last_ts + last_duration - state.ts
      end
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

    # Calculate offset to carry forward to next segment (only over-target is credited)
    offset = duration - state.target_duration

    state =
      state
      |> put_in([:acc], [])
      |> put_in([:ts], nil)
      |> put_in([:pts], nil)
      |> put_in([:dts], nil)
      |> put_in([:last_ts], nil)
      |> put_in([:last_duration], nil)
      |> update_in([:accumulated_offset], fn current_offset -> current_offset + offset end)

    {buffer, state}
  end

end
