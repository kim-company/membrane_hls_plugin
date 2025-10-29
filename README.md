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

## Usage

### Basic Example: Creating HLS Stream

```elixir
# In your pipeline
child(:sink, %Membrane.HLS.SinkBin{
  storage: HLS.Storage.File.new(),
  manifest_uri: URI.new!("file:///tmp/stream.m3u8"),
  target_segment_duration: Membrane.Time.seconds(6)
})
```

### Adding Tracks

Tracks are automatically registered when streams are connected to input pads:

```elixir
# H.264 Video Track (CMAF)
get_child(:video_source)
|> via_in(Pad.ref(:input, "video_720p"),
  options: [
    encoding: :H264,
    segment_duration: Membrane.Time.seconds(6),
    build_stream: fn %Membrane.CMAF.Track{} = format ->
      %HLS.VariantStream{
        uri: nil,
        bandwidth: 2_500_000,
        resolution: format.resolution,
        codecs: Membrane.HLS.serialize_codecs(format.codecs),
        audio: "program_audio"
      }
    end
  ]
)
|> get_child(:sink)

# AAC Audio Track (CMAF)
get_child(:audio_source)
|> via_in(Pad.ref(:input, "audio_128k"),
  options: [
    encoding: :AAC,
    segment_duration: Membrane.Time.seconds(6),
    build_stream: fn %Membrane.CMAF.Track{} = format ->
      %HLS.AlternativeRendition{
        name: "Audio (EN)",
        type: :audio,
        group_id: "program_audio",
        language: "en",
        channels: to_string(format.codecs.mp4a.channels),
        default: true,
        autoselect: true
      }
    end
  ]
)
|> get_child(:sink)
```

### Container Format Options

```elixir
# CMAF (default - fragmented MP4)
encoding: :H264  # Uses CMAF automatically

# MPEG-TS
encoding: :H264,
container: :TS

# Packed AAC
encoding: :AAC,
container: :PACKED_AAC

# WebVTT Subtitles
encoding: :TEXT
```

### Live Streaming Mode

```elixir
child(:sink, %Membrane.HLS.SinkBin{
  storage: HLS.Storage.File.new(),
  manifest_uri: URI.new!("file:///tmp/live.m3u8"),
  target_segment_duration: Membrane.Time.seconds(6),
  mode: {:live, Membrane.Time.seconds(18)},  # safety_delay
  max_segments: 10  # Sliding window size
})
```

### Configuration Options

- `storage` (required) - HLS.Storage implementation (File, S3, etc.)
- `manifest_uri` (required) - Base URI for the master playlist
- `target_segment_duration` (required) - Target duration for each segment
- `max_segments` (optional) - Maximum segments in playlist (enables sliding window)
- `mode` (optional) - `:vod` (default) or `{:live, safety_delay}`
- `resume_finished_tracks` (optional, default: `true`) - Allow resuming finished tracks
- `restore_pending_segments` (optional, default: `false`) - Restore pending segments on resume

### RFC 8216 Compliance

The plugin automatically logs RFC 8216 compliance warnings:

- **Error level**: Violations that may break playback
  - Segment duration exceeds target duration
  - Timestamp drift across variant streams

- **Warning level**: Best practice violations
  - Unsynchronized discontinuities
  - Track behind sync point

## Architecture

The plugin is built on the Membrane Framework and integrates with the `kim_hls` library for playlist management:

- `Membrane.HLS.SinkBin` - Main bin for processing input streams into HLS segments
- `Membrane.HLS.Source` - Source element for reading HLS playlists and segments
- Various sink implementations for different container formats
- Automatic codec detection and stream format handling
- Async segment uploads with Task.Supervisor for optimal performance

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
