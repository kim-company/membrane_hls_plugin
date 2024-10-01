defmodule Membrane.HLS do
  def serialize_codecs(codecs) do
    codecs
    |> Enum.map(&serialize_codec(&1))
    |> Enum.reject(&is_nil/1)
  end

  defp serialize_codec({:avc1, %{profile: profile, compatibility: compatibility, level: level}}) do
    [profile, compatibility, level]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map_join(&String.pad_leading(&1, 2, "0"))
    |> then(&"avc1.#{&1}")
    |> String.downcase()
  end

  defp serialize_codec({:hvc1, %{profile: profile, level: level}}),
    do: "hvc1.#{profile}.4.L#{level}.B0"

  defp serialize_codec({:mp4a, %{aot_id: aot_id}}), do: String.downcase("mp4a.40.#{aot_id}")

  defp serialize_codec(_other), do: nil
end
