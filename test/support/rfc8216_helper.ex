defmodule Membrane.HLS.RFC8216Helper do
  @moduledoc """
  Test helpers for RFC 8216 (HLS) compliance testing.

  Provides utilities to:
  - Capture and validate warning logs
  - Parse and validate HLS playlists
  - Check segment timing compliance
  - Validate codec strings
  """

  require ExUnit.Assertions
  import ExUnit.Assertions

  @doc """
  Captures log messages during test execution.

  Returns a list of log entries with level and message.

  ## Example

      logs = capture_logs(fn ->
        # code that emits logs
      end)

      assert Enum.any?(logs, &(&1.message =~ "RFC8216 Violation"))
  """
  def capture_logs(fun) do
    ExUnit.CaptureLog.capture_log(fun)
  end

  @doc """
  Asserts that a warning with the given pattern was logged.

  ## Example

      assert_warning_logged(logs, ~r/segment_exceeds_target_duration/)
  """
  def assert_warning_logged(logs, pattern) when is_binary(logs) do
    assert logs =~ pattern,
           "Expected warning matching #{inspect(pattern)}, but not found in logs:\n#{logs}"
  end

  @doc """
  Asserts that an error-level RFC violation was logged.
  """
  def assert_rfc_violation_logged(logs, code) when is_atom(code) do
    pattern = "[HLS RFC8216 Violation] #{code}:"
    assert_warning_logged(logs, pattern)
  end

  @doc """
  Asserts that no warnings were logged.
  """
  def assert_no_warnings(logs) when is_binary(logs) do
    refute logs =~ "[HLS RFC8216 Violation]",
           "Expected no RFC violations, but found warnings in logs:\n#{logs}"

    refute logs =~ "[HLS]",
           "Expected no HLS warnings, but found warnings in logs:\n#{logs}"
  end

  @doc """
  Reads and parses an HLS master playlist from a URI.

  Returns {:ok, playlist_content} or {:error, reason}.
  """
  def read_master_playlist(%URI{} = uri) do
    path = uri_to_path(uri)

    case File.read(path) do
      {:ok, content} -> {:ok, parse_master_playlist(content)}
      error -> error
    end
  end

  @doc """
  Reads and parses an HLS media playlist from a URI.

  Returns {:ok, playlist_content} or {:error, reason}.
  """
  def read_media_playlist(%URI{} = uri) do
    path = uri_to_path(uri)

    case File.read(path) do
      {:ok, content} -> {:ok, parse_media_playlist(content)}
      error -> error
    end
  end

  @doc """
  Validates that a playlist starts with #EXTM3U (RFC 8216 requirement).
  """
  def assert_valid_playlist_header(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: false)
    first_line = List.first(lines)

    assert first_line == "#EXTM3U",
           "Playlist MUST start with #EXTM3U, but first line was: #{inspect(first_line)}"
  end

  @doc """
  Validates that a media playlist has required tags.
  """
  def assert_required_media_playlist_tags(content) when is_binary(content) do
    assert content =~ "#EXT-X-VERSION:",
           "Media playlist MUST have #EXT-X-VERSION tag"

    assert content =~ "#EXT-X-TARGETDURATION:",
           "Media playlist MUST have #EXT-X-TARGETDURATION tag"
  end

  @doc """
  Validates that a VOD playlist has EXT-X-ENDLIST.
  """
  def assert_vod_playlist_complete(content) when is_binary(content) do
    assert content =~ "#EXT-X-PLAYLIST-TYPE:VOD",
           "VOD playlist MUST have #EXT-X-PLAYLIST-TYPE:VOD tag"

    assert content =~ "#EXT-X-ENDLIST",
           "VOD playlist MUST have #EXT-X-ENDLIST tag"
  end

  @doc """
  Extracts segment durations from a media playlist.

  Returns a list of durations in seconds (as floats).
  """
  def extract_segment_durations(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#EXTINF:"))
    |> Enum.map(fn line ->
      [_, duration_str] = String.split(line, ":", parts: 2)
      [duration_str, _] = String.split(duration_str, ",", parts: 2)
      String.to_float(duration_str)
    end)
  end

  @doc """
  Extracts target duration from a media playlist.

  Returns the target duration in seconds (as integer).
  """
  def extract_target_duration(content) when is_binary(content) do
    case Regex.run(~r/#EXT-X-TARGETDURATION:(\d+)/, content) do
      [_, duration] -> String.to_integer(duration)
      nil -> raise "No EXT-X-TARGETDURATION found in playlist"
    end
  end

  @doc """
  Validates that all segments are within target duration (RFC 8216 requirement).
  """
  def assert_segments_within_target(content) when is_binary(content) do
    durations = extract_segment_durations(content)
    target = extract_target_duration(content)

    Enum.each(durations, fn duration ->
      assert duration <= target,
             "Segment duration #{duration}s exceeds target duration #{target}s (RFC 8216 violation)"
    end)
  end

  @doc """
  Validates that EXT-X-TARGETDURATION equals the ceiling of the maximum segment duration.
  """
  def assert_correct_target_duration(content) when is_binary(content) do
    durations = extract_segment_durations(content)
    target = extract_target_duration(content)
    max_duration = Enum.max(durations, fn -> 0.0 end)
    expected_target = ceil(max_duration)

    assert target == expected_target,
           "EXT-X-TARGETDURATION should be #{expected_target} (ceiling of max segment #{max_duration}s), but was #{target}"
  end

  @doc """
  Validates that CMAF playlists have EXT-X-MAP tags.
  """
  def assert_cmaf_has_init_section(content) when is_binary(content) do
    assert content =~ "#EXT-X-MAP:",
           "CMAF playlist MUST have #EXT-X-MAP tag for initialization section"
  end

  @doc """
  Validates H.264 codec string format (avc1.PPCCLL).
  """
  def assert_valid_h264_codec(codec_string) when is_binary(codec_string) do
    assert codec_string =~ ~r/^avc1\.[0-9A-Fa-f]{6}$/,
           "H.264 codec string MUST follow avc1.PPCCLL format, but was: #{codec_string}"
  end

  @doc """
  Validates AAC codec string format (mp4a.40.OT).
  """
  def assert_valid_aac_codec(codec_string) when is_binary(codec_string) do
    assert codec_string =~ ~r/^mp4a\.40\.\d+$/,
           "AAC codec string MUST follow mp4a.40.OT format, but was: #{codec_string}"
  end

  @doc """
  Extracts codec strings from a master playlist variant stream line.
  """
  def extract_codecs_from_variant(line) when is_binary(line) do
    case Regex.run(~r/CODECS="([^"]+)"/, line) do
      [_, codecs] -> String.split(codecs, ",")
      nil -> []
    end
  end

  @doc """
  Checks if a playlist contains discontinuity tags.
  """
  def has_discontinuity?(content) when is_binary(content) do
    content =~ "#EXT-X-DISCONTINUITY"
  end

  # Private helpers

  defp uri_to_path(%URI{scheme: "file", path: path}) do
    path
  end

  defp uri_to_path(%URI{scheme: nil, path: path}) do
    path
  end

  defp parse_master_playlist(content) do
    %{
      variant_streams: extract_variant_streams(content),
      alternative_renditions: extract_alternative_renditions(content)
    }
  end

  defp parse_media_playlist(content) do
    %{
      version: extract_version(content),
      target_duration: extract_target_duration(content),
      segments: extract_segments(content),
      is_vod: content =~ "#EXT-X-PLAYLIST-TYPE:VOD",
      is_live: not (content =~ "#EXT-X-ENDLIST"),
      has_end_list: content =~ "#EXT-X-ENDLIST"
    }
  end

  defp extract_variant_streams(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#EXT-X-STREAM-INF:"))
  end

  defp extract_alternative_renditions(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#EXT-X-MEDIA:"))
  end

  defp extract_version(content) do
    case Regex.run(~r/#EXT-X-VERSION:(\d+)/, content) do
      [_, version] -> String.to_integer(version)
      nil -> nil
    end
  end

  defp extract_segments(content) do
    content
    |> String.split("\n")
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [line1, _line2] -> String.starts_with?(line1, "#EXTINF:") end)
    |> Enum.map(fn [extinf, uri] ->
      duration =
        case Regex.run(~r/#EXTINF:([\d.]+),/, extinf) do
          [_, dur] -> String.to_float(dur)
          nil -> 0.0
        end

      %{duration: duration, uri: String.trim(uri)}
    end)
  end
end
