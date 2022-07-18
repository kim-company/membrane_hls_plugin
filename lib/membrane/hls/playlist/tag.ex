defmodule Membrane.HLS.Playlist.Tag do
  # appear in both master and media playlists
  @type tag_id_t ::
          :ext_m3u
          | :ext_x_version

          # media segments tags
          | :extinf
          | :ext_x_byterange
          | :ext_x_discontinuity
          | :ext_x_key
          | :ext_x_map
          | :ext_x_program_date_time
          | :ext_x_daterange

          # media playlist tags
          | :ext_x_targetduration
          | :ext_x_media_sequence
          | :ext_x_discontinuity_sequence
          | :ext_x_endlist
          | :ext_x_playlist_type
          | :ext_x_i_frames_only

          # master playlist tags
          | :ext_x_media
          | :ext_x_stream_inf
          | :ext_x_i_frame_stream_inf
          | :ext_x_session_data
          | :ext_x_session_key

          # appear in either master or media playlist, not both
          | :ext_x_independent_segments
          | :ext_x_start

  @type attribute_list_t :: %{required(atom()) => any()}

  @type t :: %__MODULE__{
          id: tag_id_t,
          value: any(),
          attributes: attribute_list_t
        }

  @type behaviour_t :: module()

  @callback match?(String.t()) :: boolean()
  @callback unmarshal(String.t() | [String.t()]) :: t()
  @callback is_multiline?() :: boolean()
  @callback id() :: tag_id_t()

  @enforce_keys [:id]
  defstruct @enforce_keys ++ [:value, attributes: []]

  defmacro __using__(id: tag_id) do
    quote do
      @behaviour Membrane.HLS.Playlist.Tag
      alias Membrane.HLS.Playlist.Tag

      @impl true
      def id(), do: unquote(tag_id)

      @impl true
      def is_multiline?(), do: false

      @impl true
      def match?(line) do
        prefix = Membrane.HLS.Playlist.Tag.marshal_id(unquote(tag_id))
        String.starts_with?(line, prefix)
      end

      @spec capture_value!(String.t(), String.t(), (String.t() -> any)) :: any
      def capture_value!(data, match_pattern, parser_fun) do
        Membrane.HLS.Playlist.Tag.capture_value!(data, unquote(tag_id), match_pattern, parser_fun)
      end

      def capture_attribute_list!(data, field_parser_fun) do
        Membrane.HLS.Playlist.Tag.capture_attribute_list!(data, unquote(tag_id), field_parser_fun)
      end

      defoverridable Membrane.HLS.Playlist.Tag
    end
  end

  @spec marshal_id(tag_id_t()) :: String.t()
  def marshal_id(id) do
    id
    |> Atom.to_string()
    |> String.replace("_", "-", global: true)
    |> String.upcase()
    |> then(&Enum.join(["#", &1]))
  end

  @spec capture_attribute_list!(
          String.t(),
          tag_id_t(),
          (String.t(), String.t() -> :skip | {atom(), any})
        ) :: %{required(atom()) => any}
  def capture_attribute_list!(data, tag_id, field_parser_fun) do
    marshaled_tag_id = marshal_id(tag_id)
    regex = Regex.compile!("#{marshaled_tag_id}:(?<target>.*)")
    %{"target" => attribute_list_raw} = Regex.named_captures(regex, data)

    attribute_list_raw
    |> parse_attribute_list()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case field_parser_fun.(key, value) do
        :skip -> acc
        {key, value} -> Map.put_new(acc, key, value)
      end
    end)
  end

  @spec parse_attribute_list(String.t()) :: %{required(String.t()) => String.t()}

  @doc """
  Parses an attribute list string as specified in RFC 8216, section 4.2
  """
  def parse_attribute_list(data) do
    buf = {[], []}

    # possible states:
    # - key: parsing key
    # - val: parsing value
    # - qval: parsing quoted value
    state = {:key, buf, %{}}

    put_key_val = fn {keybuf, valbuf}, acc ->
      key = keybuf |> Enum.reverse() |> Enum.join()
      val = valbuf |> Enum.reverse() |> Enum.join()
      Map.put(acc, key, val)
    end

    {_, buf, parsed} =
      data
      |> String.codepoints()
      |> Enum.reduce(state, fn
        "=", {:key, buf, acc} ->
          {:val, buf, acc}

        cp, {:key, {keybuf, valbuf}, acc} ->
          {:key, {[cp | keybuf], valbuf}, acc}

        "\"", {:val, buf, acc} ->
          {:qval, buf, acc}

        "\"", {:qval, buf, acc} ->
          {:val, buf, acc}

        ",", {:val, buf, acc} ->
          {:key, {[], []}, put_key_val.(buf, acc)}

        cp, {state, {keybuf, valbuf}, acc} when state in [:val, :qval] ->
          {state, {keybuf, [cp | valbuf]}, acc}
      end)

    # Last holded value is still in the buffer at this point
    put_key_val.(buf, parsed)
  end

  @spec capture_value!(String.t(), tag_id_t(), String.t(), (String.t() -> any)) :: any
  def capture_value!(data, tag_id, match_pattern, parser_fun) do
    marshaled_tag_id = marshal_id(tag_id)
    regex = Regex.compile!("#{marshaled_tag_id}:(?<target>#{match_pattern})")
    %{"target" => raw} = Regex.named_captures(regex, data)

    parser_fun.(raw)
  end
end
