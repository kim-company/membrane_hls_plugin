defmodule Membrane.HLS.Shifter do
  @moduledoc """
  This element is responsible for creating a strictly monotonically increasing DTS/PTS stream
  starting from a particular point in time. Used when putting discontinuities in the playlist
  is not an option and for now when the output playlist is not a sliding window one.

  It starts from a previous duration (e.g. the duration of the track up to now) and goes on.
  """
  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any)

  def_options(
    duration: [
      spec: Membrane.Time.t(),
      description: """
      The duration of the track we're adding segments to. Timing will restart from this value.
      """
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{offset: opts.duration}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, shift_buffer(state, buffer)}], state}
  end

  defp shift_buffer(state, buffer) do
    %{
      buffer
      | pts: compute_offset(buffer.pts, state),
        dts: compute_offset(buffer.dts, state),
        metadata: update_metadata(buffer.metadata, state)
    }
  end

  defp update_metadata(%{to: to} = metadata, state),
    do: %{metadata | to: compute_offset(to, state)}

  defp update_metadata(metadata, _state), do: metadata

  defp compute_delta(t, state) when state.offset >= 0, do: t - state.offset
  # When the offset is negative we have no reason to change it, it means the
  # stream is just started.
  defp compute_delta(t, _state), do: t

  defp compute_offset(nil, _state), do: nil

  defp compute_offset(t, state) do
    state.offset + compute_delta(t, state)
  end
end
