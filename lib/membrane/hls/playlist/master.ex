defmodule Membrane.HLS.Playlist.Master do
  alias Membrane.HLS.VariantStream
  alias Membrane.HLS.AlternativeRendition
  alias Membrane.HLS.Playlist
  alias Membrane.HLS.Playlist.Tag

  @behaviour Membrane.HLS.Playlist

  @type t :: %__MODULE__{
          tags: Playlist.tag_map_t(),
          version: pos_integer(),
          streams: VariantStream.t()
        }
  defstruct [:version, tags: %{}, streams: []]

  @impl true
  def init(tags) do
    [version] = Map.fetch!(tags, Tag.Version.id())

    renditions =
      tags
      |> Map.get(Tag.AlternativeRendition.id(), [])
      |> Enum.map(&AlternativeRendition.from_tag(&1))

    streams =
      tags
      |> Map.get(Tag.VariantStream.id(), [])
      |> Enum.map(&VariantStream.from_tag(&1))
      |> Enum.map(&VariantStream.maybe_associate_alternative_rendition(&1, renditions))

    %__MODULE__{tags: tags, version: version.value, streams: streams}
  end

  @impl true
  def supported_tags() do
    [
      Tag.Version,
      Tag.VariantStream,
      Tag.AlternativeRendition
    ]
  end

  @spec variant_streams(t) :: [VariantStream.t()]
  def variant_streams(%__MODULE__{streams: streams}), do: streams
end
