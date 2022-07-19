defmodule Membrane.HLS.Playlist.Tag.SegmentURI do
  @behaviour Membrane.HLS.Playlist.Tag
  alias Membrane.HLS.Playlist.Tag

  @impl true
  def has_uri?(), do: true

  @impl true
  def id(), do: :uri

  @impl true
  def is_multiline?(), do: false

  @impl true
  def match?(line), do: !String.starts_with?(line, "#")

  @impl true
  def unmarshal(line), do: URI.parse(line)

  @impl true
  def init(uri = %URI{}, sequence) do
    %Tag{
      id: id(),
      class: :media_segment,
      value: uri,
      sequence: sequence,
    }
  end
end
