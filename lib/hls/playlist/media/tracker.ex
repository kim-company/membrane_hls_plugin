defmodule HLS.Playlist.Media.Tracker do
  use GenServer

  alias HLS.Storage
  alias HLS.Playlist.Media
  alias HLS.Segment

  defstruct [:storage, following: %{}]

  @type target_t :: URI.t()

  @max_initial_live_segments 3

  defmodule Tracking do
    defstruct [:ref, :target, :follower, started: false, next_seq: 0]
  end

  def initial_live_buffer_size(), do: @max_initial_live_segments

  def start_link(storage = %Storage{}, opts \\ []) do
    GenServer.start_link(__MODULE__, storage, opts)
  end

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @spec follow(pid(), target_t()) :: reference()
  def follow(pid, target) do
    GenServer.call(pid, {:follow, target})
  end

  @impl true
  def init(storage) do
    {:ok, %__MODULE__{storage: storage}}
  end

  @impl true
  def handle_call({:follow, target}, {from, _}, state) do
    tracking = %Tracking{ref: make_ref(), target: target, follower: from}
    following = Map.put(state.following, tracking.ref, tracking)
    state = %__MODULE__{state | following: following}
    {:reply, tracking.ref, state, {:continue, {:refresh, tracking}}}
  end

  @impl true
  def handle_continue({:refresh, tracking}, state) do
    handle_refresh(tracking, state)
  end

  @impl true
  def handle_info({:refresh, tracking}, state) do
    handle_refresh(tracking, state)
  end

  defp handle_refresh(tracking, state) do
    uri = tracking.target
    playlist = Storage.get_media_playlist!(state.storage, uri)
    segs = Media.segments(playlist)

    # Determine initial sequence number, sending the start_of_track message if
    # needed.
    tracking =
      if tracking.started do
        tracking
      else
        next_seq =
          if !playlist.finished && length(segs) > @max_initial_live_segments do
            playlist.media_sequence_number + (length(segs) - @max_initial_live_segments)
          else
            playlist.media_sequence_number
          end

        send(tracking.follower, {:start_of_track, tracking.ref, next_seq})
        %Tracking{tracking | next_seq: next_seq, started: true}
      end

    {segs, last_seq} =
      segs
      |> Enum.map_reduce(0, fn seg, _ ->
        seg = Segment.update_absolute_sequence(seg, playlist.media_sequence_number)
        {seg, seg.absolute_sequence}
      end)

    # Send new segments only
    segs
    |> Enum.filter(fn seg -> seg.absolute_sequence >= tracking.next_seq end)
    |> Enum.map(fn seg -> {:segment, tracking.ref, seg} end)
    |> Enum.each(&send(tracking.follower, &1))

    # Schedule a new refresh if needed
    tracking = %Tracking{tracking | next_seq: last_seq + 1}

    if playlist.finished do
      send(tracking.follower, {:end_of_track, tracking.ref})
    else
      wait = playlist.target_segment_duration * 1_000
      Process.send_after(self(), {:refresh, tracking}, wait)
    end

    following = Map.put(state.following, tracking.ref, tracking)
    {:noreply, %__MODULE__{state | following: following}}
  end
end
