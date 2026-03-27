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

  test "when non-h264 starts after first video keyframe, waits for next video cut point" do
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

    {[], state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(1_000), %{}, state)

    {actions, state} = TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(1_100), %{}, state)
    assert actions == []

    {actions, state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(1_900, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    assert actions == []

    {actions, _state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(2_000), %{}, state)

    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(1_900)]
    assert action_buffers_pts(actions, :audio) == [Membrane.Time.milliseconds(2_000)]
  end

  test "advances to next video keyframe when subtitle starts after first candidate" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)
    state = add_pad(state, :subtitles, :any)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(
        Pad.ref(:input, :video),
        %Membrane.H264{alignment: :au, nalu_in_metadata?: true},
        %{},
        state
      )

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :subtitles), %Membrane.Text{}, %{}, state)

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

    {actions, state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :subtitles), buffer(1_200), %{}, state)

    assert actions == []

    {actions, _state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :subtitles), buffer(2_000), %{}, state)

    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(1_900)]

    # Text starts 100ms after the cut point, so a filler is prepended at the
    # reference to keep all tracks aligned.
    text_bufs = action_buffers(actions, :subtitles)
    assert length(text_bufs) == 2
    assert hd(text_bufs).pts == Membrane.Time.milliseconds(1_900)
    assert hd(text_bufs).payload == ""
    assert List.last(text_bufs).pts == Membrane.Time.milliseconds(2_000)
  end

  test "clips overlapping subtitle cue to alignment cut point" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)
    state = add_pad(state, :subtitles, :any)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(
        Pad.ref(:input, :video),
        %Membrane.H264{alignment: :au, nalu_in_metadata?: true},
        %{},
        state
      )

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :subtitles), %Membrane.Text{}, %{}, state)

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

    subtitle =
      %Membrane.Buffer{
        payload: "long cue",
        pts: Membrane.Time.milliseconds(1_200),
        metadata: %{to: Membrane.Time.milliseconds(2_400)}
      }

    {actions, _state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :subtitles), subtitle, %{}, state)

    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(1_900)]

    [clipped_subtitle] = action_buffers(actions, :subtitles)
    assert clipped_subtitle.pts == Membrane.Time.milliseconds(1_900)
    assert clipped_subtitle.metadata.to == Membrane.Time.milliseconds(2_400)
    assert clipped_subtitle.payload == "long cue"
  end

  test "text without metadata.to falls back to legacy non-overlap behavior" do
    state = init_align(max_leading_trim: Membrane.Time.seconds(3), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)
    state = add_pad(state, :subtitles, :any)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(
        Pad.ref(:input, :video),
        %Membrane.H264{alignment: :au, nalu_in_metadata?: true},
        %{},
        state
      )

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :subtitles), %Membrane.Text{}, %{}, state)

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

    subtitle_before_cut =
      %Membrane.Buffer{payload: "before", pts: Membrane.Time.milliseconds(1_200), metadata: %{}}

    {actions, state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :subtitles), subtitle_before_cut, %{}, state)

    assert actions == []

    subtitle_after_cut =
      %Membrane.Buffer{payload: "after", pts: Membrane.Time.milliseconds(2_000), metadata: %{}}

    {actions, _state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :subtitles), subtitle_after_cut, %{}, state)

    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(1_900)]

    # No metadata.to, subtitle starts after cut point → filler at reference.
    text_bufs = action_buffers(actions, :subtitles)
    assert length(text_bufs) == 2
    assert hd(text_bufs).pts == Membrane.Time.milliseconds(1_900)
    assert hd(text_bufs).payload == ""
    assert List.last(text_bufs).pts == Membrane.Time.milliseconds(2_000)
    assert List.last(text_bufs).payload == "after"
  end

  test "text pad with gap after cut point emits filler at reference to stay aligned" do
    # Reproduces the production crash: cut point is at 4.0s (video keyframe),
    # but the first subtitle cue arrives at 5.07s. Without a filler, the text
    # track's first_forward_ts would be 5.07s — a 1.07s misalignment that
    # cascades into HLS packager track_timing_mismatch_at_sync errors.
    state = init_align(max_leading_trim: Membrane.Time.seconds(10), max_queued_buffers: 100)
    state = add_pad(state, :video, :h264_keyframe)
    state = add_pad(state, :audio, :any)
    state = add_pad(state, :text, :any)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(
        Pad.ref(:input, :video),
        %Membrane.H264{alignment: :au, nalu_in_metadata?: true},
        %{},
        state
      )

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :audio), %Membrane.AAC{}, %{}, state)

    {[stream_format: _], state} =
      TrimAlign.handle_stream_format(Pad.ref(:input, :text), %Membrane.Text{}, %{}, state)

    # Video: non-keyframe at 0s, keyframe at 2s (the cut point), keyframe at 4s
    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(0, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(2_000, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :video),
        buffer(4_000, %{h264: %{key_frame?: true}}),
        %{},
        state
      )

    # Audio: frames at 2.014s and 4.02s (AAC frame boundary near cut point)
    {[], state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(2_014), %{}, state)

    {[], state} =
      TrimAlign.handle_buffer(Pad.ref(:input, :audio), buffer(4_020), %{}, state)

    # Text: first subtitle cue doesn't arrive until well after the cut point.
    # This is the scenario from production — subtitle at T=0.03s, next at T=5.07s.
    {[], state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :text),
        %Membrane.Buffer{
          payload: "early cue",
          pts: Membrane.Time.milliseconds(30),
          metadata: %{to: Membrane.Time.milliseconds(1_500)}
        },
        %{},
        state
      )

    # This subtitle arrives 1.07s after the cut point. Alignment should
    # still choose T=4.0s as the cut point (video keyframe), and text
    # MUST start at T=4.0s too — with an empty filler if needed.
    {actions, _state} =
      TrimAlign.handle_buffer(
        Pad.ref(:input, :text),
        %Membrane.Buffer{
          payload: "late cue",
          pts: Membrane.Time.milliseconds(5_070),
          metadata: %{to: Membrane.Time.milliseconds(8_000)}
        },
        %{},
        state
      )

    # Video cuts at the keyframe
    assert action_buffers_pts(actions, :video) == [Membrane.Time.milliseconds(4_000)]

    # Audio cuts at the nearest AAC frame boundary (22ms drift is fine)
    assert action_buffers_pts(actions, :audio) == [Membrane.Time.milliseconds(4_020)]

    # Text MUST start at the cut point, not at 5.07s.
    # The first buffer should be an empty filler at the reference,
    # followed by the actual cue.
    text_buffers = action_buffers(actions, :text)
    assert length(text_buffers) == 2

    [filler, actual_cue] = text_buffers
    assert filler.pts == Membrane.Time.milliseconds(4_000)
    assert filler.payload == ""
    assert actual_cue.pts == Membrane.Time.milliseconds(5_070)
    assert actual_cue.payload == "late cue"
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

  defp action_buffers(actions, id) do
    Enum.find_value(actions, [], fn
      {:buffer, {pad, buffers}} when pad == Pad.ref(:output, id) and is_list(buffers) ->
        buffers

      {:buffer, {pad, %Membrane.Buffer{} = buffer}} when pad == Pad.ref(:output, id) ->
        [buffer]

      _other ->
        nil
    end)
  end

  defp action_buffers_pts(actions, id) do
    actions
    |> action_buffers(id)
    |> Enum.map(& &1.pts)
  end
end
