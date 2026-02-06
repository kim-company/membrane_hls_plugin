defmodule Membrane.HLS.TrimAlignTest do
  use ExUnit.Case, async: true

  alias Membrane.HLS.TrimAlign
  alias Membrane.Pad

  require Pad

  test "aligns pads by trimming leading buffers" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :audio, :any)
    state = add_pad(state, :text, :any)

    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(0), %{}, state)
    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(1_000), %{}, state)

    {actions, state} = TrimAlign.handle_buffer(Pad.ref(:input, :text), buffer(1_000), %{}, state)

    assert action_buffers_pts(actions, :audio) == [Membrane.Time.milliseconds(1_000)]
    assert action_buffers_pts(actions, :text) == [Membrane.Time.milliseconds(1_000)]

    {[buffer: {Pad.ref(:output, :audio), %Membrane.Buffer{pts: direct_pts, payload: _payload}}],
     _state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(3_000), %{}, state)

    assert direct_pts == Membrane.Time.milliseconds(3_000)
  end

  test "cuts h264 only at keyframe boundaries" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)
    state = add_pad(state, :audio, :any)

    h264_format = %Membrane.H264{alignment: :au, nalu_in_metadata?: true}

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :video), h264_format, %{}, state)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :audio), %Membrane.AAC{}, %{}, state)

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(0, %{h264: %{key_frame?: false}}),
        %{},
        state
      )

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(900, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(500), %{}, state)

    {actions, _state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(1_000), %{}, state)

    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(900)]
    assert action_buffers_pts(actions, :audio) == [Membrane.Time.milliseconds(1_000)]
  end

  test "follows delayed h264 keyframe when audio starts later" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)
    state = add_pad(state, :audio, :any)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(
        Pad.ref(:input, :video),
        %Membrane.H264{alignment: :au, nalu_in_metadata?: true},
        %{},
        state
      )

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :audio), %Membrane.AAC{}, %{}, state)

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(0, %{h264: %{key_frame?: false}}),
        %{},
        state
      )

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(900, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(1_900, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(1_000), %{}, state)
    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(1_100), %{}, state)

    {actions, _state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(2_000), %{}, state)

    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(1_900)]
    assert action_buffers_pts(actions, :audio) == [Membrane.Time.milliseconds(2_000)]
  end

  test "raises for non parsed h264 format" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)

    assert_raise RuntimeError, ~r/requires parsed H264 input/, fn ->
      TrimAlign.handle_stream_format(
        Pad.ref(:input, :video),
        %Membrane.H264{alignment: :nalu, nalu_in_metadata?: false},
        %{},
        state
      )
    end
  end

  test "raises when required trim exceeds limit" do
    state = init_align(max_leading_trim: Membrane.Time.milliseconds(500), max_queued_buffers: 100)
    state = add_pad(state, :a, :any)
    state = add_pad(state, :b, :any)

    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :a), buffer(0), %{}, state)
    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :a), buffer(1_000), %{}, state)

    assert_raise RuntimeError, ~r/exceeding max_leading_trim/, fn ->
      TrimAlign.handle_buffer(Pad.ref(:input, :b), buffer(1_000), %{}, state)
    end
  end

  test "raises when queue grows above limit" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 2)
    state = add_pad(state, :a, :any)
    state = add_pad(state, :b, :any)

    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :a), buffer(0), %{}, state)
    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :a), buffer(100), %{}, state)

    assert_raise RuntimeError, ~r/exceeded max_queued_buffers/, fn ->
      TrimAlign.handle_buffer(Pad.ref(:input, :a), buffer(200), %{}, state)
    end
  end

  defp init_align(opts) do
    {[], state} = TrimAlign.handle_init(%{}, Map.new(opts))
    state
  end

  defp add_pad(state, id, cut_strategy) do
    {[], state} =
      TrimAlign.handle_pad_added(
        Pad.ref(:input, id),
        %{pad_options: %{cut_strategy: cut_strategy}},
        state
      )

    state
  end

  defp buffer(pts_ms, metadata \\ %{}) do
    %Membrane.Buffer{
      payload: <<0>>,
      pts: Membrane.Time.milliseconds(pts_ms),
      metadata: metadata
    }
  end

  defp action_buffers_pts(actions, id) do
    Enum.find_value(actions, [], fn
      {:buffer, {pad, buffers}} when pad == Pad.ref(:output, id) and is_list(buffers) ->
        Enum.map(buffers, & &1.pts)

      _other ->
        nil
    end)
  end
end
