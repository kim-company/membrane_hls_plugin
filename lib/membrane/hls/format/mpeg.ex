defmodule Membrane.HLS.Format.MPEG do
  # RFC 8126, section 3.{2-3}
  #
  # NOTE: how to distinguish MPEG-2 to Fragmented MPEG-4 packats from the
  # information contained in the variant stream / rendition?
  defstruct [:codecs]
end
