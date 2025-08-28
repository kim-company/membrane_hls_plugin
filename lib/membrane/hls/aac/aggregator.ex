defmodule Membrane.HLS.AAC.Aggregator do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: Membrane.AAC
  )

  def_output_pad(:output,
    accepted_format: Membrane.AAC
  )

  def_options(
    target_duration: [
      spec: Membrane.Time.t(),
      description: """
      Segments will converge to this duration.
      """
    ],
    offset: [
      spec: Membrane.Time.t(),
      default: 0,
      description: """
      The very first segment of the audio can be used to re-align audio/video streams. Usually when
      an encoder starts producing audio and video data, the initial video PTS/DTS might start with a difference due to the presence of B frames (e.g. DTS 2.67, PTS 2.7).
      Setting the offset to that difference (which is usually deterministic based on encoder's settings)
      will make the subsequent segments align.
      """
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{target_duration: opts.target_duration, acc: [], pts: nil, accumulated_offset: -opts.offset}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state = %{acc: []}) do
    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(:input, _ctx, state) do
    {out_buffer, state} = finalize_segment(state)
    {[buffer: {:output, out_buffer}, end_of_stream: :output], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case state.pts do
      nil ->
        state = init_segment(state, buffer)
        {[], state}

      pts ->
        actual_duration = buffer.pts - pts
        duration = state.accumulated_offset + actual_duration

        if duration >= state.target_duration do
          {out_buffer, state} = finalize_segment(state, actual_duration)
          state = init_segment(state, buffer)
          {[buffer: {:output, out_buffer}], state}
        else
          {[], add_buffer(state, buffer)}
        end
    end
  end

  defp init_segment(state, buffer) do
    state
    |> put_in([:pts], buffer.pts)
    |> put_in([:acc], [buffer])
  end

  defp add_buffer(state, buffer) do
    update_in(state, [:acc], fn acc -> [buffer | acc] end)
  end

  defp finalize_segment(state) do
    # NOTE: we're loosing the last frame's duration! we can still compute it
    # by checking the number of AAC frames in the payload: @ 48000 sample rate and
    # 1024 samples per frame, we have 21ms per buffer)
    buffers = Enum.reverse(state.acc)
    duration = List.last(buffers).pts - state.pts
    finalize_segment(state, duration)
  end

  defp finalize_segment(state, duration) do
    payload =
      state.acc
      |> Enum.reverse()
      |> Stream.map(fn x -> x.payload end)
      |> Enum.join()

    payload = encode_id3v2_priv_timestamp(state.pts) <> payload

    metadata = %{
      duration: duration
    }

    buffer = %Membrane.Buffer{
      payload: payload,
      pts: state.pts,
      metadata: metadata
    }

    offset = duration - state.target_duration

    state =
      state
      |> put_in([:acc], [])
      |> put_in([:pts], nil)
      |> update_in([:accumulated_offset], fn x -> x + offset end)

    {buffer, state}
  end

  @id3v2_identifier "ID3"
  @priv_frame_id "PRIV"
  @apple_owner_id "com.apple.streaming.transportStreamTimestamp"

  # ID3v2.4.0
  @id3v2_version <<4, 0>>

  defp encode_id3v2_priv_timestamp(pts) do
    payload =
      (pts / 1.0e9 * 90_000)
      |> round()
      |> rem(2 ** 33 - 1)
      |> then(fn ts ->
        <<ts::unsigned-big-integer-size(64)>>
      end)

    encode_id3v2_priv(@apple_owner_id, payload)
  end

  defp encode_id3v2_priv(owner, payload) do
    # Build PRIV frame
    priv_frame = build_priv_frame(owner, payload)

    # Calculate total tag size (excluding the 10-byte header)
    tag_size = byte_size(priv_frame)

    # Build complete ID3v2 tag
    <<
      # "ID3"
      @id3v2_identifier::binary,
      # Version 4.0
      @id3v2_version::binary,
      # Flags (none set)
      0::8,
      # Synchsafe size
      encode_synchsafe_int32(tag_size)::binary,
      # PRIV frame
      priv_frame::binary
    >>
  end

  defp build_priv_frame(owner_id, private_data)
       when is_binary(owner_id) and is_binary(private_data) do
    # Frame content: null-terminated owner ID + private data
    frame_content = <<owner_id::binary, 0, private_data::binary>>

    # Calculate frame size (excluding frame header)
    frame_size = byte_size(frame_content)

    <<
      # "PRIV"
      @priv_frame_id::binary,
      # Frame size (synchsafe)
      encode_synchsafe_int32(frame_size)::binary,
      # Frame flags (none set)
      0::16,
      # Frame data
      frame_content::binary
    >>
  end

  def encode_synchsafe_int32(value) when is_integer(value) and value >= 0 do
    import Bitwise

    max_synchsafe_value = (1 <<< 28) - 1

    if value > max_synchsafe_value do
      raise ArgumentError,
            "Value #{value} exceeds maximum synchsafe value (#{max_synchsafe_value})"
    end

    # Extract 7-bit chunks
    byte4 = value &&& 0x7F
    byte3 = value >>> 7 &&& 0x7F
    byte2 = value >>> 14 &&& 0x7F
    byte1 = value >>> 21 &&& 0x7F

    <<byte1, byte2, byte3, byte4>>
  end
end
