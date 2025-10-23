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
    {[], %{duration: opts.duration, offset: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{offset: nil} = state) do
    state = %{state | offset: state.duration - Membrane.Buffer.get_dts_or_pts(buffer)}
    {[buffer: {:output, shift_buffer(buffer, state)}], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, shift_buffer(buffer, state)}], state}
  end

  defp shift_buffer(buffer, state) do
    %{
      buffer
      | pts: add_offset(buffer.pts, state),
        dts: add_offset(buffer.dts, state),
        metadata: update_metadata(buffer.metadata, state)
    }
  end

  defp update_metadata(%{to: to} = metadata, state),
    do: %{metadata | to: add_offset(to, state)}

  defp update_metadata(metadata, _state), do: metadata

  defp add_offset(nil, _state), do: nil
  defp add_offset(t, state), do: max(state.duration, t + state.offset)
end
