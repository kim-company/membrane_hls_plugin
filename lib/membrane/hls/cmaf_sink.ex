defmodule Membrane.HLS.CMAFSink do
  use Membrane.Sink
  alias HLS.Packager

  def_input_pad(
    :input,
    accepted_format: Membrane.CMAF.Track
  )

  def_options(
    packager_pid: [
      spec: pid(),
      description: "PID of the packager."
    ],
    track_id: [
      spec: String.t(),
      description: "ID of the track."
    ],
    build_stream: [
      spec:
        (URI.t(), Membrane.CMAF.Track.t() -> HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
      description: "Build the stream with the given stream format"
    ],
    target_segment_duration: [
      spec: Membrane.Time.t()
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts, upload_tasks: %{}}}
  end

  def handle_stream_format(:input, format, _ctx, state) do
    track_id = state.opts.track_id

    target_segment_duration =
      Membrane.Time.as_seconds(state.opts.target_segment_duration, :exact)
      |> Ratio.ceil()

    Agent.update(state.opts.packager_pid, fn packager ->
      packager =
        if Packager.has_track?(packager, track_id) do
          Packager.discontinue_track(packager, track_id)
        else
          uri = Packager.new_variant_uri(packager, track_id)

          Packager.add_track(
            packager,
            track_id,
            codecs: Membrane.HLS.serialize_codecs(format.codecs),
            stream: state.opts.build_stream.(uri, format),
            segment_extension: ".mp4",
            target_segment_duration: target_segment_duration
          )
        end

      Packager.put_init_section(packager, track_id, format.header)
    end)

    {[], state}
  end

  def handle_buffer(:input, buffer, _ctx, state) do
    {ref, upload_fun} =
      Agent.get_and_update(state.opts.packager_pid, fn packager ->
        {packager, {ref, upload_fun}} =
          Packager.put_segment_async(
            packager,
            state.opts.track_id,
            buffer.payload,
            Membrane.Time.as_seconds(buffer.metadata.duration) |> Ratio.to_float()
          )

        {{ref, upload_fun}, packager}
      end)

    task = Task.async(upload_fun)

    {[], put_in(state, [:upload_tasks, task.ref], ref)}
  end

  def handle_info({task_ref, :ok}, _ctx, state) do
    Process.demonitor(task_ref, [:flush])

    {job_ref, state} = pop_in(state, [:upload_tasks, task_ref])

    Agent.update(state.opts.packager_pid, fn packager ->
      Packager.ack_segment(packager, state.opts.track_id, job_ref)
    end)

    {[], state}
  end
end
