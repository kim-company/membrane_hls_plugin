defmodule Membrane.HLS.SourceBin do
  use Membrane.Bin

  alias HLS.Playlist
  alias HLS.Playlist.Master
  alias HLS.Storage
  alias Membrane.HLS.Format
  alias Membrane.HLS.Source

  @master_check_retry_interval_ms 1_000
  require Membrane.Logger

  def_output_pad(:output,
    availability: :on_request,
    accepted_format:
      %Membrane.RemoteStream{content_format: %format{}}
      when format in [Format.PackedAudio, Format.WebVTT, Format.MPEG]
  )

  def_options(
    storage: [
      spec: Storage.t(),
      description: "HLS.Storage implementation used to obtain playlist contents"
    ],
    master_playlist_uri: [
      spec: URI.t(),
      description: "URI of the master playlist"
    ]
  )

  @impl true
  def handle_init(_ctx, options) do
    {[],
     %{
       storage: options.storage,
       master_playlist_uri: options.master_playlist_uri,
       pad_to_child: %{}
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(self(), :check_master_playlist)
    {[], state}
  end

  @impl true
  def handle_pad_added(pad = {Membrane.Pad, :output, {:rendition, rendition}}, _ctx, state) do
    media_uri = Playlist.build_absolute_uri(state.master_playlist_uri, extract_uri(rendition))
    stream_format = build_stream_format(rendition)
    child_name = {:source, pad}

    spec = [
      child(child_name, %Source{
        storage: state.storage,
        media_playlist_uri: media_uri,
        stream_format: stream_format
      })
      |> via_out(:output)
      |> bin_output(pad)
    ]

    {[
       {:spec, spec}
     ], put_in(state, [:pad_to_child, pad], child_name)}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    case Map.fetch(state.pad_to_child, pad) do
      {:ok, child_name} ->
        {[remove_child: child_name], update_in(state, [:pad_to_child], &Map.delete(&1, pad))}

      :error ->
        {[], state}
    end
  end

  @impl true
  def handle_info(
        :check_master_playlist,
        _ctx,
        state = %{storage: storage, master_playlist_uri: uri}
      ) do
    case Storage.get(storage, uri) do
      {:ok, data} ->
        playlist = Playlist.unmarshal(data, %Master{uri: uri})
        {[{:notify_parent, {:hls_master_playlist, playlist}}], state}

      {:error, reason} ->
        Membrane.Logger.warning("Master playlist check failed: #{inspect(reason)}")

        Membrane.Logger.warning(
          "Master playlist check attempt scheduled in #{@master_check_retry_interval_ms}ms"
        )

        Process.send_after(self(), :check_master_playlist, @master_check_retry_interval_ms)
        {[], state}
    end
  end

  defp extract_uri(%HLS.AlternativeRendition{uri: uri}), do: uri
  defp extract_uri(%HLS.VariantStream{uri: uri}), do: uri

  defp build_stream_format(%HLS.VariantStream{codecs: codecs}), do: %Format.MPEG{codecs: codecs}

  defp build_stream_format(%HLS.AlternativeRendition{type: :subtitles, language: lang}),
    do: %Format.WebVTT{language: lang}

  defp build_stream_format(%HLS.AlternativeRendition{type: :audio}), do: %Format.PackedAudio{}

  defp build_stream_format(rendition),
    do: raise(ArgumentError, "Unable to provide a proper cap for rendition #{inspect(rendition)}")
end
