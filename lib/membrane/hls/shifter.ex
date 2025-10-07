defmodule Membrane.HLS.Shifter do
  @moduledoc """
  This element is responsible for creating a strictly monotonically increasing DTS/PTS stream
  starting from a particular point in time. Used when putting discontinuities in the playlist
  is not an option and for now when the output playlist is not a sliding window one.

  It starts from a previous duration (e.g. the duration of the track up to now) and goes on.
  At startup, it coordinates with the other shifters to obtain t_zero, from which each buffer
  will compute their offsets. This is done because normally audio/video do not start exactly
  at the same T and we must to preserve this offset. Note that this is going to cause a hole
  in the PTS/DTS stream which is effectively a discontinuity. For most players, this does
  not change a dime.
  """
  use Membrane.Filter

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

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       offset: opts.duration,
       waiting_first_buffer: true,
       waiting_t_zero: true,
       queue: :queue.new(),
       t_zero: nil
     }}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{t_zero: nil}) do
    if :queue.is_empty(state.queue) do
      {[end_of_stream: :output], state}
    else
      # Flush the pending buffers first. For that, we need the parent notification.
      {[], state}
    end
  end

  def handle_end_of_stream(:input, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_parent_notification({:t_zero, t_zero}, ctx, state) do
    state =
      state
      |> put_in([:t_zero], t_zero)
      |> put_in([:waiting_t_zero], false)
      # In case we did not receive the first buffer yet but we received
      # the notification already, we just skip the whole t_zero communication thing.
      |> put_in([:waiting_first_buffer], false)

    {buffers, state} =
      get_and_update_in(state, [:queue], fn q ->
        buffers =
          q
          |> :queue.to_list()
          |> Enum.map(&shift_buffer(state, &1))

        {buffers, :queue.new()}
      end)

    actions = [buffer: {:output, buffers}]

    if ctx.pads.input.end_of_stream? do
      {actions ++ [end_of_stream: :output], state}
    else
      {actions, state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %{waiting_first_buffer: true}) do
    state =
      state
      |> enqueue_buffer(buffer)
      |> put_in([:waiting_first_buffer], false)

    {[notify_parent: {:t_zero, Membrane.Buffer.get_dts_or_pts(buffer)}], state}
  end

  def handle_buffer(:input, buffer, _ctx, state = %{waiting_t_zero: true}) do
    {[], enqueue_buffer(state, buffer)}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, shift_buffer(state, buffer)}], state}
  end

  defp enqueue_buffer(state, buffer) do
    update_in(state, [:queue], fn q -> :queue.in(buffer, q) end)
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

  defp compute_delta(t, state) when state.t_zero >= 0, do: t - state.t_zero
  # When the offset is negative we have no reason to change it, it means the
  # stream is just started.
  defp compute_delta(t, _state), do: t

  defp compute_offset(nil, _state), do: nil

  defp compute_offset(t, state) do
    state.offset + compute_delta(t, state)
  end
end
