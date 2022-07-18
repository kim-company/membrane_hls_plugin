defmodule Membrane.HLS.Playlist do
  @moduledoc """
  HLS Playlist parses based on RFC 8216.
  """

  alias Membrane.HLS.Playlist.Tag

  @type tag_map_t :: %{required(Tag.tag_id_t()) => [Tag.t()]}

  @doc """
  Returns a list of modules implementing the tag behaviour that are used to
  define the playlist.
  """
  @callback supported_tags() :: [Tag.behaviour_t()]
  @callback init(tag_map_t()) :: struct()

  @doc """
  Given a valid playlist file and a playlist module implementation, returns the
  deserialized list of tags.
  """
  def unmarshal(data = "#EXTM3U" <> _rest, playlist_impl) do
    unmarshalers = playlist_impl.supported_tags()

    data
    # carriage return + line feed should be supported as well, see RFC
    # 8216, 4.1
    |> String.split("\n", trim: true)
    |> Enum.reduce({[], nil}, fn
      line, acc = {marshaled, nil} ->
        matching_unmarshaler =
          Enum.find(unmarshalers, fn unmarshaler ->
            unmarshaler.match?(line)
          end)

        if matching_unmarshaler == nil do
          # Ignore each line that we do not recognize.
          acc
        else
          if matching_unmarshaler.is_multiline?() do
            {marshaled, {matching_unmarshaler, line}}
          else
            {[matching_unmarshaler.unmarshal(line) | marshaled], nil}
          end
        end

      line, {marshaled, {matching_unmarshaler, old_line}} ->
        {[matching_unmarshaler.unmarshal([old_line, line]) | marshaled], nil}
    end)
    |> elem(0)
    |> Enum.group_by(fn tag -> tag.id end)
    |> playlist_impl.init()
  end

  def unmarshal(data, _playlist_impl) do
    raise ArgumentError, "Input data is not a valid M3U file: #{inspect(data)}"
  end
end
