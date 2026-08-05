defmodule Membrane.HLS.Filler.AACTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.{Buffer, Testing}

  @aac_frame_duration round(1024 / 48_000 * Membrane.Time.second())
  @filler_pts [0, @aac_frame_duration, 2 * @aac_frame_duration, 3 * @aac_frame_duration]

  test "emits raw AAC silence when filling raw AAC streams" do
    stream_format = %Membrane.AAC{
      profile: :LC,
      channels: 2,
      sample_rate: 48_000,
      samples_per_frame: 1024,
      encapsulation: :none
    }

    real_buffer_pts = 4 * @aac_frame_duration

    real_buffer = %Buffer{
      pts: real_buffer_pts,
      dts: real_buffer_pts,
      payload: <<1, 2, 3>>
    }

    pipeline = start_filler_pipeline(stream_format, real_buffer)

    for pts <- @filler_pts do
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: ^pts, payload: payload})
      refute adts?(payload)
    end

    assert_sink_buffer(pipeline, :sink, %Buffer{pts: ^real_buffer_pts, payload: <<1, 2, 3>>})

    Testing.Pipeline.terminate(pipeline)
  end

  test "emits ADTS AAC silence when filling ADTS streams" do
    stream_format = %Membrane.AAC{
      profile: :LC,
      channels: 2,
      sample_rate: 48_000,
      samples_per_frame: 1024,
      encapsulation: :ADTS
    }

    real_buffer_pts = 4 * @aac_frame_duration

    real_buffer = %Buffer{
      pts: real_buffer_pts,
      dts: real_buffer_pts,
      payload: <<0xFF, 0xF1, 1, 2, 3>>
    }

    pipeline = start_filler_pipeline(stream_format, real_buffer)

    for pts <- @filler_pts do
      assert_sink_buffer(pipeline, :sink, %Buffer{pts: ^pts, payload: payload})
      assert adts?(payload)
    end

    assert_sink_buffer(pipeline, :sink, %Buffer{
      pts: ^real_buffer_pts,
      payload: <<0xFF, 0xF1, 1, 2, 3>>
    })

    Testing.Pipeline.terminate(pipeline)
  end

  defp start_filler_pipeline(stream_format, real_buffer) do
    spec =
      child(:source, %Testing.Source{
        stream_format: stream_format,
        output: [real_buffer]
      })
      |> child(:filler, Membrane.HLS.Filler.AAC)
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

    assert_sink_playing(pipeline, :sink)
    Testing.Pipeline.notify_child(pipeline, :filler, {:time_reference, 0})

    pipeline
  end

  defp adts?(<<0xFF, second_byte, _rest::binary>>) do
    Bitwise.band(second_byte, 0xF0) == 0xF0
  end

  defp adts?(_payload), do: false
end
