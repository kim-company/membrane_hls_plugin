defmodule Membrane.HLS.AlternativeRendition do
  alias Membrane.HLS.Playlist.Tags
  alias Membrane.HLS.Playlist.Tag

  @type type_t :: :subtitles | :audio | :video | :cc
  @type t :: %__MODULE__{
    attributes: Tag.attribute_list_t(),
    type: type_t(),
    group_id: String.t()
  }
  defstruct [:type, :group_id, attributes: %{}]

  def from_tag(%Tag{id: id, attributes: attrs}) do
    if id != Tags.AlternativeRendition.id() do
      raise ArgumentError, "Cannot convert tag #{inspect id} to a alternative rendition instance"
    end

    %__MODULE__{
      attributes: attrs,
      type: attrs.type,
      group_id: attrs.group_id,
    }
  end
end
