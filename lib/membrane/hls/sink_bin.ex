defmodule Membrane.HLS.SinkBin do
  @moduledoc """
  Bin responsible for receiving audio and video streams, performing payloading and CMAF muxing
    to eventually store them using provided storage configuration.

  ## Input streams
  Parsed H264, H265, AAC or Text video or audio streams are expected to be connected via the `:input` pad.
  The type of stream has to be specified via the pad's `:encoding` option.
  """
  use Membrane.Bin
  alias Membrane.HLS.Packager

  def_options(
    base_manifest_uri: [
      spec: URI.t(),
      description: """
      Base information about the master playlist.
      Example: file://output/stream.m3u8
      """
    ],
    segment_duration: [
      spec: Membrane.Time.t(),
      description: """
      The minimal segment length of the regular segments.
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
    {[], %{opts: opts, packager: nil}}
  end

  @impl true
  def handle_setup(_context, state) do
    {:ok, packager} =
      Packager.start_link(
        storage: state.opts.storage,
        manifest_uri: state.opts.base_manifest_uri
      )

    {[], %{state | packager: packager}}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :AAC} = pad_opts},
        state
      ) do
    IO.inspect(pad_opts, label: "Handle pad added")

    spec = [
      bin_input(pad)
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: state.opts.segment_duration
      })
      |> child({:sink, track_id}, Membrane.Debug.Sink)
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:input, track_id) = pad,
        %{pad_options: %{encoding: :H264} = pad_opts},
        %{packager: packager} = state
      ) do
    # TODO: Get the duration of the media and the max duration of all playlists in the packager
    # to decide if we need to add a filler and restore pts element.
    media =
      Packager.upsert_stream(packager, %HLS.VariantStream{
        uri: Packager.to_variant_uri(pad_opts[:track_name]),
        bandwidth: pad_opts.bandwidth,
        codecs: []
      })

    offset_pts = Packager.get_media_offset(media)

    spec = [
      bin_input(pad)
      # |> child({:restore_pts, track_id}, %ShiftPts{duration: 100})
      # |> child({:fill, track_id}, %SilenceGenerator{duration: 100})
      |> child({:muxer, track_id}, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: state.opts.segment_duration
      })
      |> child({:sink, track_id}, %Membrane.Debug.Sink{
        handle_stream_format: fn format ->
          # todo: format.header should go as the EXT-X-MAP and also be uploaded like a segment
          Packager.upsert_stream(packager, %{
            media
            | resolution: format.resolution,
              codecs: format.codecs
          })
        end,
        handle_buffer: fn buffer ->
          IO.inspect(buffer)
          format = %{header: <<>>}

          # NOTE: As soon as the first put_segment happens, we transition into a "initialized" state where nothing can be updated anymore.

          segment =
            Packager.init_segment(packager, media, %{
              init_section: format.header,
              payload: buffer.payload,
              duration: buffer.metadata.duration
            })

          spawn_link(fn ->
            upload(the(segment(...)))
            Packager.confirm_upload(segment)
          end)
        end
      })
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_playing(_context, state) do
    IO.puts("SinkBin: handle_playing")

    # TODO: check that playlists from the storage match the assigned inputs and define the start_pts (max of all playlists) how many bytes we need to add.
    {[], state}
  end
end
