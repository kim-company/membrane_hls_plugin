defmodule Membrane.HLS.Playlist.Tags.AlternativeRendition do
  use Membrane.HLS.Playlist.Tag, id: :ext_x_media

  @impl true
  def unmarshal(line) do
    attrs =
      line
      |> capture_attribute_list!(fn
        "TYPE", val -> {:type, rendition_type_to_atom(val)}
        "URI", val -> {:uri, URI.parse(val)}
        "GROUP-ID", val -> {:group_id, val}
        "NAME", val -> {:name, val}
        "LANGUAGE", val -> {:language, val}
        _key, _val -> :skip
      end)

    %Tag{id: id(), attributes: attrs}
  end

  def rendition_type_to_atom("SUBTITLES"), do: :subtitles
  def rendition_type_to_atom("CLOSED-CAPTIONS"), do: :closed_captions
  def rendition_type_to_atom("AUDIO"), do: :audio
  def rendition_type_to_atom("VIDEO"), do: :video
end
