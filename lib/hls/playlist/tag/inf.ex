defmodule HLS.Playlist.Tag.Inf do
  # NOTE: this segment might also provide a title, which we're ignoring here,
  # see RFC 8216, section 4.3.2.1. Below version 3 this field should be an
  # integer.

  use HLS.Playlist.Tag, id: :extinf

  @impl true
  def unmarshal(data),
    do:
      capture_value!(data, ~s/\\d+\\.?\\d*/, fn raw ->
        raw =
          if String.contains?(raw, ".") do
            raw
          else
            raw <> ".0"
          end

        String.to_float(raw)
      end)
end
