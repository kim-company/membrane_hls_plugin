defmodule Membrane.HLS.AACFiller do
  use Membrane.Filter

  def_input_pad(:input,
    accepted_format: Membrane.AAC
  )

  def_output_pad(:output,
    accepted_format: Membrane.RemoteStream
  )

  def_options(
    duration: [
      spec: Membrane.Time.t()
    ]
  )

  def handle_init(_ctx, opts) do
    {[], %{duration: opts.duration, format: nil, filled: false}}
  end

  def handle_stream_format(:input, format, _ctx, state) do
    {[forward: %Membrane.RemoteStream{content_format: Membrane.AAC}], %{state | format: format}}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    buffer = %{buffer | pts: nil, dts: nil}

    if state.filled do
      {[forward: buffer], state}
    else
      format = state.format

      silence_buffer =
        if Membrane.Time.as_milliseconds(state.duration, :round) > 0 do
          duration =
            Membrane.Time.as_seconds(state.duration)
            |> Ratio.to_float()

          {silence, 0} =
            System.cmd(
              "ffmpeg",
              ~w(-f lavfi -i anullsrc=r=#{format.sample_rate} -ac #{format.channels} -t #{duration} -c:a aac -f adts -)
            )

          %Membrane.Buffer{
            payload: silence
          }
        else
          nil
        end

      {[buffer: {:output, List.wrap(silence_buffer) ++ [buffer]}], %{state | filled: true}}
    end
  end
end
