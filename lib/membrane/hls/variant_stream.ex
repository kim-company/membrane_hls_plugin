defmodule Membrane.HLS.VariantStream do
  alias Membrane.HLS.Playlist.Tag
  alias Membrane.HLS.Playlist.Tag
  alias Membrane.HLS.AlternativeRendition

  @type t :: %__MODULE__{
    attributes: Tag.attribute_list_t(),
    alternatives: %{required(AlternativeRendition.type_t()) => [AlternativeRendition.t()]}
  }
  defstruct [attributes: %{}, alternatives: %{}]

  def from_tag(%Tag{id: id, attributes: attrs}) do
    if id != Tag.VariantStream.id() do
      raise ArgumentError, "Cannot convert tag #{inspect id} to a variant stream instance"
    end

    %__MODULE__{
      attributes: attrs,
    }
  end

  @spec alternative_renditions(t(), AlternativeRendition.type_t()) :: [AlternativeRendition.t()]
  def alternative_renditions(%__MODULE__{alternatives: alts}, alt_type) do
    Map.get(alts, alt_type, [])
  end

  def maybe_associate_alternative_rendition(stream, renditions) do
    group_ids = associated_group_ids(stream)

    alternatives =
    renditions
    |> Enum.filter(fn rendition -> Enum.member?(group_ids, rendition.group_id) end)
    |> Enum.group_by(fn rendition -> rendition.type end)

    alternatives = Map.merge(stream.alternatives, alternatives, fn _k, v1, v2 -> v1 ++ v2 end)
    %__MODULE__{stream | alternatives: alternatives}
  end

  defp associated_group_ids(%__MODULE__{attributes: attrs}) do
    [:video, :audio, :subtitles, :closed_captions]
    |> Enum.reduce([], fn rendition_type, acc ->
      case Map.get(attrs, rendition_type) do
        nil -> acc
        id when is_binary(id) -> [id | acc]
      end
    end)
  end
end
