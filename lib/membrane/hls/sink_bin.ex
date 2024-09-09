defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF muxing
    to eventually store them using provided storage configuration.

  ## Input streams
  Parsed H264, H265, AAC or Text video or audio streams are expected to be connected via the `:input` pad.
  The type of stream has to be specified via the pad's `:encoding` option.
  """
  use Membrane.Bin
  require Logger
  alias Membrane.HLS.Storage

  def_options(
    base_manifest_uri: [
      spec: URI.t(),
      description: """
      Base information about the master playlist.
      Example: file://output/stream
      """
    ],
    segment_duration: [
      spec: Membrane.Time.t(),
      description: """
      The minimal segment length of the regular segments.
      """
    ],
    outputs: [
      spec: :manifests_and_segments | :segments_only | :variant_manifest_and_segments,
      default: :manifests_and_segments,
      description: """
      Allows you to control which kinds of playlists should be written by the sink.
      """
    ],
    storage: [
      spec: Membrane.HLS.Storage,
      required: true,
      description: """
      Implementation of the storage.
      """
    ]
  )

  def_input_pad(:input,
    accepted_format:
      any_of(
        Membrane.AAC,
        Membrane.H264
        # Membrane.Text
      ),
    availability: :on_request,
    options: [
      encoding: [
        spec: :AAC | :H264 | :TEXT,
        description: """
        Encoding type determining which parser will be used for the given stream.
        """
      ],
      track_name: [
        spec: String.t() | nil,
        default: nil,
        description: """
        Name that will be used to name the media playlist for the given track, as well as its header and segments files.
        It must not contain any URI reserved characters
        """
      ]
    ]
  )

  @impl true
  def handle_init(_context, opts) do
    {[], %{opts: opts}}
  end

  @impl true
  def handle_setup(_context, state) do
    # TODO: read the files on the storage for restoration?

    case Storage.get(state.opts.storage, "#{state.opts.base_manifest_uri}.m3u8") do
      {:ok, playlist} ->
        # should be a master playlist, right?
        nil
    end

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, %{pad_options: %{encoding: :AAC}}, state) do
    spec = [
      bin_input(pad)
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: state.opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.Debug.Sink{handle_buffer: &IO.inspect/1})
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, %{pad_options: %{encoding: :H264}}, state) do
    # TODO: If pad was alreay added in previous playlist, check its last pts.

    spec = [
      bin_input(pad)
      # |> child({:restore_pts, track_id}, %ShiftPts{duration: 100})
      # |> child({:fill, track_id}, %SilenceGenerator{duration: 100})
      # TODO: Read storage and inject the buffer pads in front of the video somehow...
      # TODO: Adapt PTS based on the storage's situation
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: state.opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.Debug.Sink{handle_buffer: &IO.inspect/1})
    ]

    {[spec: spec], state}
  end

  # @impl true
  # def handle_playing(_context, state) do
  #   # TODO: check that playlists from the storage match the assigned inputs and define the start_pts (max of all playlists) how many bytes we need to add.
  #   {[], state}
  # end
end
