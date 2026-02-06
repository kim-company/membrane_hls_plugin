# Membrane HLS Plugin
![Hex.pm Version](https://img.shields.io/hexpm/v/membrane_hls_plugin)

Adaptive live streaming plugin (HLS) for the Membrane Framework, used in production.

## Features

### Source Elements
- `Membrane.HLS.Source` reads a single media playlist (VOD or live/event) and emits raw segment payloads
- `Membrane.HLS.SourceBin` reads a master playlist and exposes renditions as dynamic output pads
- Supports multiple renditions (video, audio, subtitles)
- Handles dynamic playlist updates for live streams
- Built-in storage abstraction for different backends

### Sink Element (SinkBin)
- **Multiple Container Formats**:
  - CMAF segments (default) - Modern fragmented MP4
  - MPEG-TS segments - Traditional transport stream
  - Packed AAC - Audio-only streams
  - **AAC over TS** - ⚠️ **Experimental**: Audio streams packed in Transport Stream containers
  - WebVTT - Subtitle tracks

- **Stream Types Supported**:
  - H.264 video encoding
  - AAC audio encoding  
  - Text subtitles (WebVTT format)

- **Operating Modes** (via `playlist_mode`):
  - `:vod` - segments are synced as soon as the next segment group is ready
  - `{:event, safety_delay}` - live event playlists synced on a target-duration cadence
  - `{:sliding, max_segments, safety_delay}` - live playlists with rolling window support

### Advanced Features
- **Codec Serialization**: Automatic codec string generation (avc1, hvc1, mp4a)
- **Automatic Master Metadata**: BANDWIDTH/AVERAGE-BANDWIDTH and CODECS are computed by SinkBin/Packager when possible
- **Deprecation Notice**: Manually setting `HLS.VariantStream.bandwidth` and `HLS.VariantStream.codecs` in `build_stream` is deprecated
- **Segment Management**: Configurable target segment durations
- **Multi-track Support**: Audio, video, and subtitle tracks in single pipeline

### Timing Contract and Policies
- **Upstream timestamps are authoritative**: SinkBin does not shift, trim, or synthesize PTS/DTS.
- **Alignment required**: Tracks that produce segments at a sync point must be time-aligned
  (minor AAC/H264 cut differences are tolerated by the packager).
- **RFC-compliant output**: discontinuities are inserted when needed; playlists remain spec compliant.
- **Error policy**:
  - `:vod` is strict and fails fast on packager errors.
  - `:event`/`:sliding` are tolerant to recoverable timing issues but fail fast on missing
    mandatory track segments to avoid silent stalls.

## Architecture

The plugin is built on the Membrane Framework and integrates with the `kim_hls` library for playlist management:

- `Membrane.HLS.SinkBin` - Main bin for processing input streams into HLS segments (accepts `manifest_uri`, `playlist_mode`, and `HLS.Storage`)
- `Membrane.HLS.Source` - Source element for a single media playlist
- `Membrane.HLS.SourceBin` - Bin wrapper that discovers renditions from a master playlist

### Source Behavior
- `Membrane.HLS.Source` is demand-driven for VOD playlists and polls live/event playlists for new segments.
- Segment payloads are forwarded as-is; callers provide `stream_format` to describe the container.
- `Membrane.HLS.SourceBin` handles master playlist discovery and spins up one `Membrane.HLS.Source`
  per rendition, emitting them via dynamic output pads.
- Various sink implementations for different container formats
- Automatic codec detection and stream format handling

## Dependencies

Key dependencies include:
- `membrane_core` - Core Membrane Framework
- `kim_hls` - HLS playlist and segment management
- `membrane_mp4_plugin` - MP4/CMAF container support
- `membrane_aac_plugin` - AAC audio processing
- `membrane_h26x_plugin` - H.264/H.265 video processing
- `membrane_mpeg_ts_plugin` - MPEG-TS container support

## Copyright and License
Copyright 2025, [KIM Keep In Mind GmbH](https://www.keepinmind.info/)
Licensed under the [Apache License, Version 2.0](LICENSE)
