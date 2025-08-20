# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Testing
- `mix test` - Run all tests
- `mix test test/membrane/hls/sink_bin_test.exs` - Run specific test file
- `mix test --only tag_name` - Run tests with specific tag (e.g., `--only tmp_dir`)

### Building & Dependencies
- `mix deps.get` - Fetch dependencies
- `mix compile` - Compile the project
- `mix docs` - Generate documentation

### Running Examples
- `elixir examples/rtmp.exs` - Run RTMP-to-HLS streaming example

## Architecture Overview

This is a Membrane Framework plugin for HLS (HTTP Live Streaming) that provides both source and sink capabilities.

### Core Components

**SinkBin Architecture**: The main `Membrane.HLS.SinkBin` acts as a container that dynamically creates processing pipelines based on input pad configurations:

1. **Input Processing**: Each input pad specifies `encoding` (:AAC, :H264, :TEXT), `container` (:CMAF, :TS, :PACKED_AAC), and `segment_duration`
2. **Pipeline Creation**: Based on these options, different processing chains are built:
   - AAC → Aggregator → PackedAACSink (for PACKED_AAC)
   - AAC → MP4.Muxer.CMAF → CMAFSink (for CMAF)
   - H264 → MP4.Muxer.CMAF → CMAFSink (for CMAF)
   - H264 → MPEG.TS.Muxer → Aggregator → TSSink (for TS)
   - TEXT → WebVTT.CueBuilderFilter → WebVTT.SegmentFilter → WebVTTSink

**HLS.Packager Integration**: All sink elements interact with `HLS.Packager` (from `kim_hls` dependency) which:
- Manages playlist generation and segment metadata
- Handles track registration with codec information
- Coordinates timing and synchronization across multiple tracks
- Supports both live and VOD modes

**Timeline Management**:
- **Shifter Element**: For VOD playlists, shifts timestamps to maintain monotonic PTS across stream restarts
- **Live Mode**: Uses safety delays and periodic playlist synchronization
- **Discontinuities**: Automatically added when packager has existing tracks (stream restarts)

### Source Architecture

The `Membrane.HLS.Source` reads existing HLS streams:
- Spawns `HLS.Tracker` processes for each rendition to monitor playlist updates  
- Downloads segments on-demand based on backpressure
- Converts HLS renditions to appropriate Membrane stream formats

### Key Patterns

**Dynamic Pad Creation**: Pads are added with specific options that determine the entire processing pipeline. The `build_stream` function converts Membrane formats to HLS stream definitions.

**Codec Serialization**: `Membrane.HLS.serialize_codecs/1` converts codec maps to HLS codec strings (e.g., "avc1.64001f", "mp4a.40.2").

**Application Supervision**: The plugin starts supervisors for tracker and task management, enabling concurrent segment processing and playlist monitoring.

**Container Format Flexibility**: The same input stream can be packaged into different containers (CMAF, TS, Packed AAC) by changing pad options, each with optimized processing chains.

### Testing Patterns

Tests use `@tag :tmp_dir` for file-based operations and create complete pipelines with:
- File sources with test fixtures (H.264/AAC in MPEG-TS)
- Demuxing and parsing elements
- SinkBin with different container configurations
- Packager instances with temporary directories

The test structure validates end-to-end functionality from raw media to HLS playlists and segments.