defmodule Membrane.HLS.WebVTT.AggregatorTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  alias Membrane.Buffer
  alias Membrane.HLS.WebVTT.Aggregator

  test "buffer fits first segment" do
    segments =
      [%{from: 0, to: 4}]
      |> generate_cues()
      |> segment_cues()

    assert segments == [
             %{cues: [%Subtitle.Cue{from: 0, to: 4, text: "0", id: ""}], from: 0, to: 6}
           ]
  end

  test "buffer spans across multiple segments" do
    segments =
      [%{from: 0, to: 8}]
      |> generate_cues()
      |> segment_cues()

    assert segments == [
             %{cues: [%Subtitle.Cue{from: 0, to: 6, text: "0", id: ""}], from: 0, to: 6},
             %{cues: [%Subtitle.Cue{from: 6, to: 8, text: "0", id: ""}], from: 6, to: 12}
           ]
  end

  test "buffer is not repeated when omit_repetition is enabled" do
    segments =
      [%{from: 0, to: 8}]
      |> generate_cues()
      |> segment_cues(true)

    assert segments == [
             %{cues: [%Subtitle.Cue{from: 0, to: 8, text: "0", id: ""}], from: 0, to: 6},
             %{cues: [], from: 6, to: 12}
           ]
  end

  test "multiple buffers" do
    segments =
      [%{from: 0, to: 4}, %{from: 4, to: 7}]
      |> generate_cues()
      |> segment_cues()

    assert segments == [
             %{
               cues: [
                 %Subtitle.Cue{from: 0, to: 4, text: "0", id: ""},
                 %Subtitle.Cue{from: 4, to: 6, text: "1", id: ""}
               ],
               from: 0,
               to: 6
             },
             %{cues: [%Subtitle.Cue{from: 6, to: 7, text: "1", id: ""}], from: 6, to: 12}
           ]
  end

  test "buffers with empty segment in between" do
    segments =
      [%{from: 0, to: 3}, %{from: 13, to: 14}]
      |> generate_cues()
      |> segment_cues()

    assert segments == [
             %{cues: [%Subtitle.Cue{from: 0, to: 3, text: "0", id: ""}], from: 0, to: 6},
             %{cues: [], from: 6, to: 12},
             %{cues: [%Subtitle.Cue{from: 13, to: 14, text: "1", id: ""}], from: 12, to: 18}
           ]
  end

  test "empty buffers forward the segment but are not added to its contents" do
    segments = segment_cues([%{from: 0, to: 8, payload: ""}])
    assert segments == [%{cues: [], from: 0, to: 6}, %{cues: [], from: 6, to: 12}]
  end

  test "empty buffers and proper buffers" do
    segments = segment_cues([%{from: 0, to: 8, payload: ""}, %{from: 9, to: 10, payload: "abc"}])

    assert segments == [
             %{cues: [], from: 0, to: 6},
             %{cues: [%Subtitle.Cue{from: 9, to: 10, text: "abc", id: ""}], from: 6, to: 12}
           ]
  end

  defp generate_cues(cues) do
    cues
    |> Enum.with_index()
    |> Enum.map(fn {%{from: from, to: to}, index} ->
      %{from: from, to: to, payload: "#{index}"}
    end)
  end

  defp segment_cues(cues, omit_repetition \\ false) do
    buffers =
      Enum.map(cues, fn %{from: from, to: to, payload: payload} ->
        %Buffer{
          pts: Membrane.Time.seconds(from),
          payload: payload,
          metadata: %{to: Membrane.Time.seconds(to)}
        }
      end)

    spec = [
      child(:source, %Membrane.Testing.Source{
        output: buffers,
        stream_format: %Membrane.Text{}
      })
      |> child(:filter, %Aggregator{
        omit_repetition: omit_repetition
      })
      |> child(:sink, %Membrane.Testing.Sink{})
    ]

    Stream.resource(
      fn ->
        Membrane.Testing.Pipeline.start_link_supervised!(spec: spec)
      end,
      fn pid ->
        receive do
          {Membrane.Testing.Pipeline, ^pid,
           {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
            cues =
              buffer.payload
              |> Subtitle.WebVTT.unmarshal!()
              |> get_in([Access.key!(:cues)])
              |> Enum.map(fn x ->
                x
                |> update_in([Access.key!(:from)], fn x -> trunc(x / 1000) end)
                |> update_in([Access.key!(:to)], fn x -> trunc(x / 1000) end)
              end)

            x = %{
              from: Membrane.Time.as_seconds(buffer.pts, :round),
              to: Membrane.Time.as_seconds(buffer.metadata.to, :round),
              cues: cues
            }

            {[x], pid}

          {Membrane.Testing.Pipeline, ^pid, {:handle_element_end_of_stream, {:sink, :input}}} ->
            {:halt, pid}
        end
      end,
      fn pid ->
        Membrane.Testing.Pipeline.terminate(pid)
      end
    )
    |> Enum.into([])
  end
end
