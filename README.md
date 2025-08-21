# Membrane HLS Plugin
![Hex.pm Version](https://img.shields.io/hexpm/v/membrane_hls_plugin)

Adaptive live streaming plugin (HLS) for the Membrane Framework, used in production.

## Features

### Source Element
- Reads existing HLS streams from master playlists
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

- **Operating Modes**:
  - **Live Mode**: Real-time streaming with sliding window playlists
    - Configurable safety delays
    - Automatic playlist synchronization
    - Discontinuity handling for stream interruptions
  - **VOD Mode**: Video-on-demand with complete playlists

### Advanced Features
- **Codec Serialization**: Automatic codec string generation (avc1, hvc1, mp4a)
- **Segment Management**: Configurable target segment durations
- **Timeline Handling**: PTS shifting and discontinuity markers
- **Multi-track Support**: Audio, video, and subtitle tracks in single pipeline

## Architecture

The plugin is built on the Membrane Framework and integrates with the `kim_hls` library for playlist management:

- `Membrane.HLS.SinkBin` - Main bin for processing input streams into HLS segments
- `Membrane.HLS.Source` - Source element for reading HLS playlists and segments
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
