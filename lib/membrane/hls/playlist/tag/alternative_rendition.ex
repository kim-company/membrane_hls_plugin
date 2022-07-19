defmodule Membrane.HLS.Playlist.Tag.AlternativeRendition do
  use Membrane.HLS.Playlist.Tag, id: :ext_x_media

  @impl true
  def unmarshal(line) do
    line
    |> capture_attribute_list!(fn
      "TYPE", val -> {:type, rendition_type_to_atom(val)}
      "URI", val -> {:uri, URI.parse(val)}
      "GROUP-ID", val -> {:group_id, val}
      "NAME", val -> {:name, val}
      "LANGUAGE", val -> {:language, val}
      "ASSOC-LANGUAGE", val -> {:assoc_language, val}
      "DEFAULT", val -> {:default, parse_yes_no(val)}
      "AUTOSELECT", val -> {:autoselect, parse_yes_no(val)}
      "FORCED", val -> {:forced, parse_yes_no(val)}
      "INSTREAM-ID", val -> {:instream_id, val}
      "CHARACTERISTICS", val -> {:characteristics, val}
      "CHANNELS", val -> {:channels, val}
      _key, _val -> :skip
    end)
  end

  defp parse_yes_no("YES"), do: true
  defp parse_yes_no("NO"), do: false

  def rendition_type_to_atom("SUBTITLES"), do: :subtitles
  def rendition_type_to_atom("CLOSED-CAPTIONS"), do: :closed_captions
  def rendition_type_to_atom("AUDIO"), do: :audio
  def rendition_type_to_atom("VIDEO"), do: :video
end
