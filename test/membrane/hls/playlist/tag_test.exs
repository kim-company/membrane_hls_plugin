defmodule Membrane.HLS.Playlist.TagTest do
  use ExUnit.Case
  alias Membrane.HLS.Playlist.Tag

  describe "Parse attribute list" do
    test "of stream alternative tag" do
      input =
        ~s/BANDWIDTH=1478400,AVERAGE-BANDWIDTH=1425600,CODECS="avc1.4d4029,mp4a.40.2",RESOLUTION=854x480,FRAME-RATE=30.000/

      assert Tag.parse_attribute_list(input) == %{
               "BANDWIDTH" => "1478400",
               "AVERAGE-BANDWIDTH" => "1425600",
               "CODECS" => "avc1.4d4029,mp4a.40.2",
               "RESOLUTION" => "854x480",
               "FRAME-RATE" => "30.000"
             }
    end
  end
end
