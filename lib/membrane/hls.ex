defmodule Membrane.HLS do
  require Logger

  def maybe_warn_deprecated_stream_fields(_track_id, stream)
      when not is_struct(stream, HLS.VariantStream),
      do: :ok

  def maybe_warn_deprecated_stream_fields(track_id, %HLS.VariantStream{} = stream) do
    if stream.bandwidth do
      Logger.warning(
        "[DEPRECATED] build_stream for track #{inspect(track_id)} sets VariantStream.bandwidth. " <>
          "Bandwidth is now computed automatically by SinkBin/Packager and user-provided values are ignored over time."
      )
    end

    if stream.codecs not in [nil, []] do
      Logger.warning(
        "[DEPRECATED] build_stream for track #{inspect(track_id)} sets VariantStream.codecs. " <>
          "CODECS are now computed automatically from stream formats when available."
      )
    end

    :ok
  end

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
