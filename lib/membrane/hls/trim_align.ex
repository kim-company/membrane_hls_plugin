defmodule Membrane.HLS.TrimAlign do
  @moduledoc """
  Trims leading buffers so all input pads start at a common synchronization point.

  When H264 pads are present, synchronization is anchored on H264 keyframe cut points.
  The aligner chooses the earliest H264 cut point for which all non-H264 pads have already
  started (`first_ts <= cut_point`). If this is not satisfied, it advances to the next H264
  cut point and retries.

  Without H264 pads, synchronization falls back to the latest first cuttable timestamp among
  all pads.

  For `%Membrane.Text{}` pads, if the selected cut point lands inside a subtitle cue
  (`buffer.pts < cut_point < buffer.metadata.to`), the first forwarded cue is clipped to start
  exactly at the cut point instead of being dropped.

  H264 pads can only be trimmed at keyframe boundaries and require parser metadata
  (`%Membrane.H264{alignment: :au, nalu_in_metadata?: true}`).
  """

  use Membrane.Filter, flow_control_hints?: false

  alias Membrane.Buffer

  @type cut_strategy :: :any | :h264_keyframe

  def_options(
    max_leading_trim: [
      spec: Membrane.Time.t(),
      default: Membrane.Time.seconds(3),
      description: """
      Maximum amount of leading content that can be trimmed from a single pad.
      """
    ],
    max_queued_buffers: [
      spec: pos_integer(),
      default: 2_000,
      description: """
      Maximum number of buffers allowed in a single pad queue before alignment is established.
      """
    ]
  )

  def_input_pad(:input,
    availability: :on_request,
    flow_control: :auto,
    accepted_format: _any,
    options: [
      cut_strategy: [
        spec: cut_strategy(),
        default: :any,
        description: """
        Defines where trimming can cut:
        * `:any` - cut at any buffer boundary
        * `:h264_keyframe` - cut only on H264 keyframe AUs
        """
      ]
    ]
  )

  def_output_pad(:output,
    availability: :on_request,
    flow_control: :auto,
    accepted_format: _any
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       pads: %{},
       alignment_reference: nil,
       max_leading_trim: opts.max_leading_trim,
       max_queued_buffers: opts.max_queued_buffers
     }}
  end

  @impl true
  def handle_pad_added({Membrane.Pad, :output, _id}, _ctx, state), do: {[], state}

  def handle_pad_added(pad, ctx, state) do
    pad_state = %{
      queue: :queue.new(),
      cut_strategy: ctx.pad_options[:cut_strategy] || :any,
      cut_candidate: nil,
      first_ts: nil,
      stream_format: nil,
      started?: false,
      ended?: false,
      eos_sent?: false
    }

    {[], put_in(state, [:pads, pad], pad_state)}
  end

  @impl true
  def handle_stream_format(pad, format, _ctx, state) do
    pad_state = Map.fetch!(state.pads, pad)
    validate_stream_format!(pad_state.cut_strategy, format, pad)
    state = put_in(state, [:pads, pad, :stream_format], format)

    {[stream_format: {output_pad(pad), format}], state}
  end

  @impl true
  def handle_buffer(pad, buffer, _ctx, %{alignment_reference: nil} = state) do
    ts = get_buffer_timestamp!(buffer)

    pad_state = Map.fetch!(state.pads, pad)
    updated_queue = :queue.in(buffer, pad_state.queue)

    if :queue.len(updated_queue) > state.max_queued_buffers do
      raise RuntimeError,
            """
            Alignment queue for pad #{inspect(pad)} exceeded max_queued_buffers=#{state.max_queued_buffers}.
            Increase :trim_align_max_queued_buffers or fix upstream timing skew.
            """
    end

    updated_pad_state =
      pad_state
      |> Map.put(:queue, updated_queue)
      |> maybe_set_first_timestamp(ts)
      |> maybe_set_cut_candidate(buffer, ts)

    state = put_in(state, [:pads, pad], updated_pad_state)

    state
    |> maybe_establish_alignment()
    |> maybe_emit_pending_eos()
  end

  def handle_buffer(pad, buffer, _ctx, state) do
    {[buffer: {output_pad(pad), buffer}], state}
  end

  @impl true
  def handle_end_of_stream(pad, _ctx, state) do
    state = update_in(state, [:pads, pad], &Map.put(&1, :ended?, true))

    if is_integer(state.alignment_reference) do
      state = update_in(state, [:pads, pad], &Map.put(&1, :eos_sent?, true))
      {[end_of_stream: output_pad(pad)], state}
    else
      state
      |> maybe_establish_alignment()
      |> maybe_emit_pending_eos()
    end
  end

  defp maybe_establish_alignment(%{alignment_reference: reference} = state)
       when is_integer(reference),
       do: {[], state}

  defp maybe_establish_alignment(state) do
    if state.pads == %{} or
         Enum.any?(state.pads, fn {_pad, data} -> is_nil(data.cut_candidate) end) do
      {[], state}
    else
      case resolve_alignment_reference(state.pads) do
        {:ok, reference} ->
          case build_alignment_actions(state, reference) do
            {:ok, actions, pads, aligned_reference} ->
              {actions, %{state | alignment_reference: aligned_reference, pads: pads}}

            :not_ready ->
              {[], state}

            {:error, reason} ->
              raise RuntimeError, reason
          end

        :not_ready ->
          {[], state}
      end
    end
  end

  defp maybe_emit_pending_eos({actions, %{alignment_reference: reference} = state})
       when is_integer(reference) do
    {eos_actions, pads} =
      Enum.reduce(state.pads, {[], %{}}, fn {pad, pad_state}, {eos_acc, pads_acc} ->
        if pad_state.ended? and not pad_state.eos_sent? do
          {
            [{:end_of_stream, output_pad(pad)} | eos_acc],
            Map.put(pads_acc, pad, %{pad_state | eos_sent?: true})
          }
        else
          {eos_acc, Map.put(pads_acc, pad, pad_state)}
        end
      end)

    {actions ++ Enum.reverse(eos_actions), %{state | pads: pads}}
  end

  defp maybe_emit_pending_eos(result), do: result

  defp resolve_alignment_reference(pads) do
    h264_candidates =
      pads
      |> Map.values()
      |> Enum.filter(&h264_pad?/1)
      |> Enum.map(& &1.cut_candidate)

    case h264_candidates do
      [] ->
        {:ok, latest_cut_candidate(pads)}

      _h264 ->
        h264_candidates
        |> Enum.min()
        |> resolve_h264_reference(pads)
    end
  end

  defp resolve_h264_reference(reference, pads) do
    with {:ok, h264_reference} <- next_common_h264_cut_point(pads, reference) do
      case latest_non_h264_start_after(pads, h264_reference) do
        nil -> {:ok, h264_reference}
        later_start -> resolve_h264_reference(later_start, pads)
      end
    end
  end

  defp next_common_h264_cut_point(pads, reference) do
    case next_h264_cut_points(pads, reference) do
      :not_ready ->
        :not_ready

      {:ok, []} ->
        {:ok, reference}

      {:ok, cut_points} ->
        next_reference = Enum.max(cut_points)

        if next_reference == reference do
          {:ok, reference}
        else
          next_common_h264_cut_point(pads, next_reference)
        end
    end
  end

  defp next_h264_cut_points(pads, reference) do
    Enum.reduce_while(pads, {:ok, []}, fn {_pad, pad_state}, {:ok, acc} ->
      if h264_pad?(pad_state) do
        case next_h264_cut_point(pad_state, reference) do
          :not_ready -> {:halt, :not_ready}
          ts -> {:cont, {:ok, [ts | acc]}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp next_h264_cut_point(pad_state, reference) do
    buffers = :queue.to_list(pad_state.queue)

    case take_from_reference(buffers, pad_state, reference) do
      :not_ready -> :not_ready
      %{first_forward_ts: ts} -> ts
    end
  end

  defp latest_non_h264_start_after(pads, reference) do
    pads
    |> Map.values()
    |> Enum.reject(&h264_pad?/1)
    |> Enum.map(& &1.first_ts)
    |> Enum.filter(&(is_integer(&1) and &1 > reference))
    |> Enum.max(fn -> nil end)
  end

  defp latest_cut_candidate(pads) do
    pads
    |> Map.values()
    |> Enum.map(& &1.cut_candidate)
    |> Enum.max()
  end

  defp h264_pad?(pad_state), do: pad_state.cut_strategy == :h264_keyframe

  defp text_pad?(%{stream_format: %Membrane.Text{}}), do: true
  defp text_pad?(_pad_state), do: false

  defp build_alignment_actions(state, reference) do
    with {:ok, selection} <- select_buffers(state.pads, reference),
         :ok <- validate_trim_limits(state.pads, selection, state.max_leading_trim) do
      log_alignment_selection(state.pads, selection, reference)

      actions =
        selection
        |> Enum.reduce([], fn {pad, %{forward_buffers: forward_buffers}}, acc ->
          if forward_buffers == [] do
            acc
          else
            [{:buffer, {output_pad(pad), forward_buffers}} | acc]
          end
        end)
        |> Enum.reverse()

      pads =
        Enum.reduce(state.pads, %{}, fn {pad, pad_state}, acc ->
          Map.put(acc, pad, %{pad_state | queue: :queue.new(), started?: true})
        end)

      {:ok, actions, pads, reference}
    else
      :not_ready -> :not_ready
      {:error, _reason} = error -> error
    end
  end

  defp log_alignment_selection(pads, selection, reference) do
    Membrane.Logger.info("TrimAlign cutting point found at T=#{format_time(reference)}")

    Enum.each(selection, fn {pad, %{first_forward_ts: first_forward_ts}} ->
      first_ts = Map.fetch!(pads, pad).first_ts
      trimmed_duration = first_forward_ts - first_ts

      Membrane.Logger.info(
        "TrimAlign stream=#{inspect(pad)} trimmed=#{format_time(trimmed_duration)} (from T=#{format_time(first_ts)} to T=#{format_time(first_forward_ts)})"
      )
    end)
  end

  defp select_buffers(pads, reference) do
    Enum.reduce_while(pads, {:ok, %{}}, fn {pad, pad_state}, {:ok, acc} ->
      buffers = :queue.to_list(pad_state.queue)

      case take_from_reference(buffers, pad_state, reference) do
        :not_ready -> {:halt, :not_ready}
        selection -> {:cont, {:ok, Map.put(acc, pad, selection)}}
      end
    end)
  end

  defp validate_trim_limits(pads, selection, max_leading_trim) do
    Enum.reduce_while(selection, :ok, fn {pad, %{first_forward_ts: first_forward_ts}}, :ok ->
      pad_state = Map.fetch!(pads, pad)
      trimmed_duration = first_forward_ts - pad_state.first_ts

      if trimmed_duration > max_leading_trim do
        {:halt,
         {:error,
          """
          Alignment on pad #{inspect(pad)} requires trimming #{format_time(trimmed_duration)},
          exceeding max_leading_trim=#{format_time(max_leading_trim)}.
          """}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp take_from_reference(buffers, %{cut_strategy: :any} = pad_state, reference)
       when is_list(buffers) do
    if text_pad?(pad_state) do
      take_text_from_reference(buffers, reference)
    else
      take_from_reference_by_cut_strategy(buffers, :any, reference)
    end
  end

  defp take_from_reference(buffers, %{cut_strategy: cut_strategy}, reference)
       when is_list(buffers) do
    take_from_reference_by_cut_strategy(buffers, cut_strategy, reference)
  end

  defp take_from_reference_by_cut_strategy(buffers, cut_strategy, reference) do
    index =
      Enum.find_index(buffers, fn buffer ->
        ts = get_buffer_timestamp!(buffer)
        ts >= reference and cuttable?(cut_strategy, buffer)
      end)

    case index do
      nil ->
        :not_ready

      index ->
        {trimmed, forward} = Enum.split(buffers, index)
        [first_forward | _rest] = forward

        %{
          trimmed_count: length(trimmed),
          forward_buffers: forward,
          first_forward_ts: get_buffer_timestamp!(first_forward)
        }
    end
  end

  defp take_text_from_reference(buffers, reference) do
    index =
      Enum.find_index(buffers, fn buffer ->
        buffer_ts = get_buffer_timestamp!(buffer)

        cond do
          buffer_ts >= reference ->
            true

          true ->
            text_buffer_overlaps_reference?(buffer, reference)
        end
      end)

    case index do
      nil ->
        :not_ready

      index ->
        {trimmed, [first_forward | rest]} = Enum.split(buffers, index)
        first_forward_ts_raw = get_buffer_timestamp!(first_forward)

        {first_forward, first_forward_ts} =
          case text_buffer_end_timestamp(first_forward) do
            end_ts
            when is_integer(end_ts) and first_forward_ts_raw < reference and end_ts > reference ->
              {clip_text_buffer_start(first_forward, reference), reference}

            _other ->
              {first_forward, first_forward_ts_raw}
          end

        %{
          trimmed_count: length(trimmed),
          forward_buffers: [first_forward | rest],
          first_forward_ts: first_forward_ts
        }
    end
  end

  defp text_buffer_overlaps_reference?(buffer, reference) do
    buffer_ts = get_buffer_timestamp!(buffer)

    case text_buffer_end_timestamp(buffer) do
      end_ts when is_integer(end_ts) ->
        buffer_ts < reference and end_ts > reference

      _other ->
        false
    end
  end

  defp text_buffer_end_timestamp(%Buffer{metadata: %{to: to}}) when is_integer(to), do: to
  defp text_buffer_end_timestamp(_buffer), do: nil

  defp clip_text_buffer_start(%Buffer{} = buffer, reference) do
    dts = if is_integer(buffer.dts), do: reference, else: buffer.dts
    %{buffer | pts: reference, dts: dts}
  end

  defp maybe_set_first_timestamp(%{first_ts: nil} = pad_state, ts),
    do: %{pad_state | first_ts: ts}

  defp maybe_set_first_timestamp(pad_state, _ts), do: pad_state

  defp maybe_set_cut_candidate(%{cut_candidate: nil} = pad_state, buffer, ts) do
    if cuttable?(pad_state.cut_strategy, buffer) do
      %{pad_state | cut_candidate: ts}
    else
      pad_state
    end
  end

  defp maybe_set_cut_candidate(pad_state, _buffer, _ts), do: pad_state

  defp cuttable?(:any, _buffer), do: true

  defp cuttable?(:h264_keyframe, %Buffer{metadata: %{h264: %{key_frame?: key_frame?}}})
       when is_boolean(key_frame?),
       do: key_frame?

  defp cuttable?(:h264_keyframe, buffer) do
    raise RuntimeError,
          """
          H264 buffer is missing keyframe metadata required for alignment: #{inspect(buffer.metadata)}.
          Ensure input comes from Membrane.H264.Parser with AU alignment.
          """
  end

  defp validate_stream_format!(:any, _format, _pad), do: :ok

  defp validate_stream_format!(:h264_keyframe, %Membrane.H264{} = format, pad) do
    if format.alignment == :au and format.nalu_in_metadata? do
      :ok
    else
      raise RuntimeError,
            """
            Pad #{inspect(pad)} requires parsed H264 input for alignment.
            Expected %Membrane.H264{alignment: :au, nalu_in_metadata?: true}, got: #{inspect(format)}
            """
    end
  end

  defp validate_stream_format!(:h264_keyframe, format, pad) do
    raise RuntimeError,
          """
          Pad #{inspect(pad)} is configured with :h264_keyframe strategy but got non-H264 format: #{inspect(format)}
          """
  end

  defp get_buffer_timestamp!(buffer) do
    case Buffer.get_dts_or_pts(buffer) do
      ts when is_integer(ts) -> ts
      _ -> raise RuntimeError, "Alignment requires buffers with DTS or PTS"
    end
  end

  defp output_pad({Membrane.Pad, :input, id}), do: {Membrane.Pad, :output, id}

  defp format_time(time_ns) when is_integer(time_ns) do
    "#{Float.round(time_ns / Membrane.Time.second(), 3)}s"
  end
end
