defmodule Membrane.HLS.Playlist.Media do
  alias Membrane.HLS.Playlist.Tag
  alias Membrane.HLS.Segment

  @behaviour Membrane.HLS.Playlist

  @type t :: %__MODULE__{
    tags: Playlist.tag_map_t(),
    version: pos_integer(),
    target_segment_duration: pos_integer(),
    media_sequence_number: pos_integer(),
    finished: boolean(),
    segments: [Segment.t()]
  }

  defstruct [:version, :target_segment_duration, :media_sequence_number, :finished, tags: %{}, segments: []]

  @impl true
  def init(tags) do
    [version] = Map.fetch!(tags, Tag.Version.id())
    [segment_duration] = Map.fetch!(tags, Tag.TargetSegmentDuration.id())
    [sequence_number] = Map.fetch!(tags, Tag.MediaSequenceNumber.id())
    finished = case Map.get(tags, Tag.EndList.id()) do
      nil -> false
      [endlist] -> endlist.value
    end

    segments =
      tags
      |> Enum.filter(fn
        {{_, :segment}, _val} -> true
        _other -> false
      end)
      |> Enum.map(fn {{seq, _}, val} -> {seq, val} end)
      |> Enum.into([])
      |> Enum.sort()
      |> Enum.map(fn {_, val} -> Segment.from_tags(val) end)

    %__MODULE__{
      tags: tags,
      version: version.value,
      target_segment_duration: segment_duration.value,
      media_sequence_number: sequence_number.value,
      finished: finished,
      segments: segments,
    }
  end

  @impl true
  def supported_tags() do
    [
      Tag.Version,
      Tag.TargetSegmentDuration,
      Tag.MediaSequenceNumber,
      Tag.EndList,
      Tag.Inf,
      Tag.SegmentURI,
    ]
  end

  @spec segments(t) :: [Segment.t()]
  def segments(%__MODULE__{segments: segs}), do: segs
end
