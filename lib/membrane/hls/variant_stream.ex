defmodule Membrane.HLS.VariantStream do
  alias Membrane.HLS.Playlist.Tag
  alias Membrane.HLS.AlternativeRendition

  @type t :: %__MODULE__{
          uri: URI.t(),
          bandwidth: pos_integer(),
          average_bandwidth: pos_integer(),
          codecs: [String.t()],
          resolution: {pos_integer(), pos_integer()},
          frame_rate: float(),
          hdcp_level: :none | :type_0,
          audio: Tag.group_id_t(),
          video: Tag.group_id_t(),
          subtitles: Tag.group_id_t(),
          closed_captions: Tag.group_id_t(),
          alternatives: %{required(AlternativeRendition.type_t()) => [AlternativeRendition.t()]}
        }
  @enforce_keys [:uri, :bandwidth, :codecs]
  @optional_keys [
    :average_bandwidth,
    :resolution,
    :frame_rate,
    :audio,
    :video,
    :subtitles,
    :closed_captions,
    hdcp_level: :none
  ]
  defstruct @enforce_keys ++ @optional_keys ++ [alternatives: %{}]

  def from_tag(%Tag{id: id, attributes: attrs}) do
    if id != Tag.VariantStream.id() do
      raise ArgumentError, "Cannot convert tag #{inspect(id)} to a variant stream instance"
    end

    mandatory =
      @enforce_keys
      |> Enum.map(fn key -> {key, Map.fetch!(attrs, key)} end)
      |> Enum.into(%{})

    optional =
      @optional_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(attrs, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    struct(__MODULE__, Map.merge(optional, mandatory))
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

  defp associated_group_ids(stream) do
    [:video, :audio, :subtitles, :closed_captions]
    |> Enum.reduce([], fn rendition_type, acc ->
      case Map.get(stream, rendition_type) do
        nil -> acc
        id when is_binary(id) -> [id | acc]
      end
    end)
  end
end
