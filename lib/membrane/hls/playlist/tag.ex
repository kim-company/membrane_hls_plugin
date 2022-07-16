defmodule Membrane.HLS.Playlist.Tag do

  @type tag_id_t ::
  # appear in both master and media playlists
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

  @type attribute_t :: {atom(), any()}
  @type attribute_list_t :: [attribute_t]

  @type t :: %__MODULE__{
    id: tag_id_t,
    value: any(),
    attributes: attribute_list_t,
  }

  @type behaviour_t :: module()

  @callback match?(String.t()) :: boolean()
  @callback is_multiline?() :: boolean()
  @callback unmarshal(String.t() | [String.t()]) :: t()

  @enforce_keys [:id]
  defstruct @enforce_keys ++ [:value, attributes: []]
end
