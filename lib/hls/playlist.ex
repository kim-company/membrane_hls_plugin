defmodule HLS.Playlist do
  @moduledoc """
  HLS Playlist parses based on RFC 8216.
  """

  alias HLS.Playlist.Tag

  @type tag_map_t :: %{required(Tag.tag_id_t() | {pos_integer(), :segment}) => [Tag.t()]}

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

    init_tag = fn module, data, sequence ->
      value_or_attrs = module.unmarshal(data)
      tag = module.init(value_or_attrs, sequence)
      n = if module.has_uri?(), do: sequence + 1, else: sequence
      {tag, n}
    end

    data
    # carriage return + line feed should be supported as well, see RFC
    # 8216, 4.1
    |> String.split("\n", trim: true)
    |> Enum.reduce({[], 0, nil}, fn
      line, acc = {marshaled, n, nil} ->
        matching_unmarshaler =
          Enum.find(unmarshalers, fn unmarshaler ->
            unmarshaler.match?(line)
          end)

        if matching_unmarshaler == nil do
          # Ignore each line that we do not recognize.
          acc
        else
          if matching_unmarshaler.is_multiline?() do
            {marshaled, n, {matching_unmarshaler, line}}
          else
            {tag, n} = init_tag.(matching_unmarshaler, line, n)
            {[tag | marshaled], n, nil}
          end
        end

      line, {marshaled, n, {matching_unmarshaler, old_line}} ->
        {tag, n} = init_tag.(matching_unmarshaler, [old_line, line], n)
        {[tag | marshaled], n, nil}
    end)
    |> elem(0)
    |> Enum.group_by(fn tag ->
      if tag.class == :media_segment do
        {tag.sequence, :segment}
      else
        tag.id
      end
    end)
    |> playlist_impl.init()
  end

  def unmarshal(data, _playlist_impl) do
    raise ArgumentError, "Input data is not a valid M3U file: #{inspect(data)}"
  end
end
