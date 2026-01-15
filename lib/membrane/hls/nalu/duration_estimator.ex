defmodule Membrane.HLS.NALU.DurationEstimator do
  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{pending: nil, last_ts: nil, last_duration: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    ts = buffer.dts || buffer.pts

    if is_nil(ts) do
      raise "NALU duration estimator requires PTS/DTS on every buffer"
    end

    case state.pending do
      nil ->
        {[], %{state | pending: buffer, last_ts: ts}}

      pending ->
        duration = ts - state.last_ts

        if duration < 0 do
          raise "NALU duration estimator received non-monotonic timestamps"
        end

        pending = put_duration(pending, duration)

        actions = [buffer: {:output, pending}]

        {actions,
         %{state | pending: buffer, last_ts: ts, last_duration: duration}}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    case state.pending do
      nil ->
        {[end_of_stream: :output], state}

      pending ->
        duration = state.last_duration || 0

        pending = put_duration(pending, duration)

        {[buffer: {:output, pending}, end_of_stream: :output],
         %{state | pending: nil}}
    end
  end

  defp put_duration(buffer, duration) do
    %{
      buffer
      | metadata: Map.put(buffer.metadata, :duration, duration)
    }
  end
end
