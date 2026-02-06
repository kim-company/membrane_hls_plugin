defmodule Membrane.HLS.Source do
  @moduledoc """
  Source element that reads a single media playlist and emits segment payloads.

  ## Operation
  - For VOD playlists (`#EXT-X-ENDLIST` or `:vod` type), segments are served
    on demand until the playlist is exhausted, then EOS is emitted.
  - For live/event playlists, the playlist is polled and new segments are
    enqueued as they appear. Demand still controls when segments are downloaded
    and sent downstream.

  ## Stream format
  This element does not parse media; it forwards raw segment payloads.
  Callers must provide `stream_format` describing the segment container:
  - `%Membrane.HLS.Format.MPEG{}` for MPEG-TS
  - `%Membrane.HLS.Format.PackedAudio{}` for packed AAC
  - `%Membrane.HLS.Format.WebVTT{}` for WebVTT

  ## Notes
  - Segment metadata (`HLS.Segment`) is attached to each buffer.
  - `poll_interval_ms` is intended for tests; production should rely on
    playlist target duration.
  """
  use Membrane.Source

  alias HLS.Playlist
  alias HLS.Playlist.Media
  alias HLS.Storage
  alias Membrane.Buffer
  alias Membrane.HLS.Format
  alias Membrane.HLS.TaskSupervisor

  @playlist_retry_interval_ms 1_000
  @poll_min_interval_ms 500
  require Membrane.Logger

  def_output_pad(:output,
    flow_control: :manual,
    availability: :always,
    accepted_format:
      %Membrane.RemoteStream{content_format: %format{}}
      when format in [Format.PackedAudio, Format.WebVTT, Format.MPEG]
  )

  def_options(
    storage: [
      spec: Storage.t(),
      description: "HLS.Storage implementation used to obtain playlist contents"
    ],
    media_playlist_uri: [
      spec: URI.t(),
      description: "URI of the media playlist"
    ],
    stream_format: [
      spec: struct(),
      description: "Stream format describing the media playlist contents (`%Membrane.HLS.Format.PackedAudio{}`, `%Membrane.HLS.Format.WebVTT{}`, or `%Membrane.HLS.Format.MPEG{}`)"
    ],
    poll_interval_ms: [
      spec: non_neg_integer() | nil,
      default: nil,
      description: """
      Optional poll interval override (milliseconds) for live playlists.
      When nil, the target duration derived from the playlist is used.
      """
    ]
  )

  @impl true
  def handle_init(_ctx, options) do
    {[],
     %{
       storage: options.storage,
       media_playlist_uri: options.media_playlist_uri,
       stream_format: options.stream_format,
       poll_interval_ms: options.poll_interval_ms,
       mode: nil,
       target_duration_ms: nil,
       next_sequence: nil,
       pending: :queue.new(),
       ready: :queue.new(),
       download: nil,
       finished: false
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    actions = [
      {:stream_format, {:output, %Membrane.RemoteStream{content_format: state.stream_format}}}
    ]

    send(self(), :refresh_playlist)
    {actions, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    {actions, state} =
      get_and_update_in(state, [:ready], fn q ->
        case :queue.out(q) do
          {{:value, action}, q} -> {[action], q}
          {:empty, q} -> {[], q}
        end
      end)

    {actions, state} =
      cond do
        not is_nil(state.download) ->
          {actions, state}

        not :queue.is_empty(state.pending) ->
          {actions, schedule_download!(state, state.storage)}

        not :queue.is_empty(state.ready) ->
          {actions ++ [{:redemand, :output}], state}

        state.finished ->
          {actions ++ [{:end_of_stream, :output}], state}

        true ->
          {actions, state}
      end

    {actions, state}
  end

  @impl true
  def handle_info(:refresh_playlist, _ctx, state) do
    case Storage.get(state.storage, state.media_playlist_uri) do
      {:ok, data} ->
        playlist = Playlist.unmarshal(data, %Media{uri: state.media_playlist_uri})
        {actions, state} = handle_playlist_update(playlist, state)
        {actions, schedule_next_refresh(state)}

      {:error, reason} ->
        Membrane.Logger.warning("Media playlist check failed: #{inspect(reason)}")

        Membrane.Logger.warning(
          "Media playlist check attempt scheduled in #{@playlist_retry_interval_ms}ms"
        )

        Process.send_after(self(), :refresh_playlist, @playlist_retry_interval_ms)
        {[], state}
    end
  end

  def handle_info({task_ref, {:segment, {:data, binary}}}, _ctx, state) do
    Process.demonitor(task_ref, [:flush])
    action = {:buffer, {:output, %Buffer{payload: binary, metadata: state.download.segment}}}

    state =
      state
      |> update_in([:ready], fn q -> :queue.in(action, q) end)
      |> put_in([:download], nil)

    {[{:redemand, :output}], state}
  end

  def handle_info({:DOWN, _task_ref, _, _, reason}, _ctx, state) do
    Membrane.Logger.warning("HLS could not get next segment: #{inspect(reason)}")
    state = put_in(state, [:download], nil)
    {[{:redemand, :output}], state}
  end

  defp schedule_download!(%{download: nil, media_playlist_uri: media_uri} = state, storage) do
    {{:value, segment}, queue} = :queue.out(state.pending)

    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        uri = Media.build_segment_uri(media_uri, segment.uri)
        Membrane.Logger.debug("Getting segment: #{to_string(uri)}")

        case Storage.get(storage, uri) do
          {:ok, data} -> {:segment, {:data, data}}
          {:error, reason} -> raise RuntimeError, "Storage.get failed: #{inspect(reason)}"
        end
      end)

    %{state | pending: queue, download: %{task_ref: task.ref, segment: segment}}
  end

  defp handle_playlist_update(%Media{} = playlist, state) do
    mode =
      state.mode ||
        if playlist.finished or playlist.type == :vod do
          :vod
        else
          :live
        end

    next_sequence = state.next_sequence || playlist.media_sequence_number
    start_sequence = max(next_sequence, playlist.media_sequence_number)

    new_segments =
      playlist.segments
      |> Enum.filter(&(&1.absolute_sequence >= start_sequence))

    next_sequence =
      case List.last(new_segments) do
        nil -> start_sequence
        segment -> segment.absolute_sequence + 1
      end

    state =
      state
      |> update_in([:pending], fn q ->
        Enum.reduce(new_segments, q, fn segment, acc -> :queue.in(segment, acc) end)
      end)
      |> Map.merge(%{
        mode: mode,
        finished: playlist.finished,
        next_sequence: next_sequence,
        target_duration_ms: playlist.target_segment_duration * 1_000
      })

    actions = if new_segments == [], do: [], else: [{:redemand, :output}]
    {actions, state}
  end

  defp schedule_next_refresh(state) do
    case {state.mode, state.finished} do
      {:live, false} ->
        interval =
          state.poll_interval_ms ||
            max(state.target_duration_ms || @poll_min_interval_ms, @poll_min_interval_ms)

        _ref = Process.send_after(self(), :refresh_playlist, interval)
        state

      _other ->
        state
    end
  end
end
