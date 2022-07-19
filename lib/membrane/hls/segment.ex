defmodule Membrane.HLS.Segment do
  alias Membrane.HLS.Playlist.Tag

  @enforce_keys [:uri, :duration]
  @type t :: %__MODULE__{
    uri: URI.t(),
    duration: float(),
  }

  defstruct @enforce_keys ++ [
    relative_sequence: 0,
  ]

  @spec from_tags([Tag.t()]) :: t()
  def from_tags(tags) do
    sequence = Enum.reduce(tags, nil, fn
      tag, nil ->
        tag.sequence
      tag, seq -> 
        if tag.sequence != seq do
          raise ArgumentError, "Attempted creating Segment with tags belonging to different sequence windows: have #{inspect tag.sequence}, want #{inspect seq}"
        end
        seq
    end)

    duration = Enum.find(tags, fn tag -> tag.id == Tag.Inf.id() end)
    uri = Enum.find(tags, fn tag -> tag.id == Tag.SegmentURI.id() end)

    %__MODULE__{
      uri: uri.value,
      duration: duration.value,
      relative_sequence: sequence,
    }
  end
end
