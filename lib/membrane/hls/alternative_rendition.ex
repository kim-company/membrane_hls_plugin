defmodule Membrane.HLS.AlternativeRendition do
  alias Membrane.HLS.Playlist.Tag

  @type type_t :: :subtitles | :audio | :video | :cc
  @type t :: %__MODULE__{
          type: type_t(),
          group_id: Tag.group_id_t(),
          name: String.t(),
          uri: URI.t(),
          language: String.t(),
          assoc_language: String.t(),
          autoselect: boolean(),
          forced: boolean(),
          default: boolean(),
          instream_id: String.t(),
          channels: String.t(),
          characteristics: String.t()
        }

  @enforce_keys [:type, :group_id, :name]
  @optional_keys [
    :uri,
    :language,
    :assoc_language,
    :autoselect,
    :default,
    :forced,
    :instream_id,
    :channels,
    :characteristics
  ]

  defstruct @enforce_keys ++ @optional_keys ++ [attributes: %{}]

  def from_tag(%Tag{id: id, attributes: attrs}) do
    if id != Tag.AlternativeRendition.id() do
      raise ArgumentError, "Cannot convert tag #{inspect(id)} to a alternative rendition instance"
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
end
