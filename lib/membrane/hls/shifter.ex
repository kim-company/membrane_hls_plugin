defmodule Membrane.HLS.Shifter do
  use Membrane.Filter

  # This is here to make sure we're not creating negative timestamps. A safe
  # bet is framerate duration * 16 (maximum frame reordering for h264)
  @min_offset Membrane.Time.seconds(2)

  def_input_pad(:input,
    accepted_format: any_of(Membrane.H264, Membrane.AAC, Membrane.Text, Membrane.RemoteStream)
  )

  def_output_pad(:output,
    accepted_format: any_of(Membrane.H264, Membrane.AAC, Membrane.Text, Membrane.RemoteStream)
  )

  def_options(
    duration: [
      spec: Membrane.Time.t(),
      description: """
      The duration of the track we're adding segments to. Timing will restart from this value.
      """
    ]
  )

  def handle_init(_ctx, opts) do
    {[], %{offset: max(opts.duration, @min_offset), t_zero: nil}}
  end

  def handle_buffer(:input, buffer, ctx, state = %{t_zero: nil}) do
    state = put_in(state, [:t_zero], Membrane.Buffer.get_dts_or_pts(buffer))
    handle_buffer(:input, buffer, ctx, state)
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    shifted_buffer = %{
      buffer
      | pts: compute_offset(buffer.pts, state),
        dts: compute_offset(buffer.dts, state),
        metadata: update_metadata(buffer.metadata, state)
    }

    {[buffer: {:output, shifted_buffer}], state}
  end

  defp update_metadata(%{to: to} = metadata, state),
    do: %{metadata | to: compute_offset(to, state)}

  defp update_metadata(metadata, _state), do: metadata

  defp compute_delta(t, state), do: t - state.t_zero

  defp compute_offset(nil, _state), do: nil

  defp compute_offset(t, state) do
    state.offset + compute_delta(t, state)
  end
end
