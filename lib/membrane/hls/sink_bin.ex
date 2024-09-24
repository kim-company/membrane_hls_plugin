defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF
  muxing to eventually store them using provided storage configuration.
  """
  use Membrane.Bin
  alias HLS.Packager

  def_options(
    manifest_uri: [
      spec: URI.t(),
      description: """
      Destination URI of the manifest.
      Example: file://output/stream.m3u8
      """
    ],
    storage: [
      spec: HLS.Storage,
      required: true,
      description: """
      Implementation of the storage.
      """
    ],
    segment_duration: [
      spec: Membrane.Time.t(),
      description: """
      The length of the regular segments.
      """
    ]
  )

  def_input_pad(:input,
    accepted_format: any_of(Membrane.H264, Membrane.AAC),
    availability: :on_request,
    options: [
      encoding: [
        spec: :AAC | :H264 | :TEXT,
        description: """
        Encoding type determining which parser will be used for the given stream.
        """
      ],
      build_stream: [
        spec:
          (URI.t(), Membrane.CMAF.Track.t() ->
             HLS.VariantStream.t() | HLS.AlternativeRendition.t()),
        description: "Build either a `HLS.VariantStream` or a `HLS.AlternativeRendition`."
      ]
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts, packager_pid: nil, ended_sinks: MapSet.new()}}
  end

  @impl true
  def handle_setup(_context, state) do
    {:ok, packager_pid} =
      Agent.start_link(fn ->
        Packager.new(
          storage: state.opts.storage,
          manifest_uri: state.opts.manifest_uri,
          resume_finished_streams: true
        )
      end)

    {[], %{state | packager_pid: packager_pid}}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: encoding} = pad_opts},
        state
      )
      when encoding in [:H264, :AAC] do
    spec = [
      bin_input(pad)
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: state.opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.HLS.CMAFSink{
        packager_pid: state.packager_pid,
        segment_duration: state.opts.segment_duration,
        build_stream: fn stream_format ->
          uri = Agent.get(state.packager_pid, &Packager.new_variant_uri(&1, "_#{track_id}"))
          pad_opts.build_stream.(uri, stream_format)
        end
      })
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_element_end_of_stream({:sink, _track_id} = sink, _pad, ctx, state) do
    all_sinks =
      ctx.children
      |> Map.keys()
      |> Enum.filter(&match?({:sink, _}, &1))
      |> MapSet.new()

    ended_sinks = MapSet.put(state.ended_sinks, sink)

    if MapSet.equal?(all_sinks, ended_sinks) do
      Agent.update(state.packager_pid, fn packager -> Packager.flush(packager) end)
      {[notify_parent: :end_of_stream], %{state | ended_sinks: ended_sinks}}
    else
      {[], %{state | ended_sinks: ended_sinks}}
    end
  end

  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end
end
