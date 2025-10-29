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
   - AAC + PACKED_AAC → Aggregator → PackedAACSink
   - AAC + CMAF → MP4.Muxer.CMAF → CMAFSink
   - AAC + TS → MPEG.TS.Muxer → Aggregator → TSSink
   - H264 + CMAF → MP4.Muxer.CMAF → CMAFSink
   - H264 + TS → MPEG.TS.Muxer → Aggregator → TSSink
   - TEXT → WebVTT.Filter → WebVTT.SegmentFilter → WebVTTSink

**HLS.Packager Integration**: All sink elements interact with `HLS.Packager` (from `kim_hls` dependency) which:
- Manages playlist generation and segment metadata
- Handles track registration with codec information
- Coordinates timing and synchronization across multiple tracks
- Supports both live and VOD modes

**Timeline Management**:
- **Shifter Element**: For VOD playlists (non-sliding window), shifts timestamps to maintain monotonic PTS/DTS across stream restarts. Located at `lib/membrane/hls/shifter.ex`
- **Live Mode**: Uses safety delays and periodic playlist synchronization with sliding windows
- **Discontinuities**: Automatically added when packager has existing tracks (indicates stream restarts in live mode)
- **Track Guardrails**: Filler and Trimmer elements ensure audio/video/subtitle tracks are synchronized, adding silence or trimming content to align segments across tracks

### Source Architecture

The `Membrane.HLS.Source` reads existing HLS streams:
- Spawns `HLS.Tracker` processes for each rendition to monitor playlist updates  
- Downloads segments on-demand based on backpressure
- Converts HLS renditions to appropriate Membrane stream formats

### Key Patterns

**Dynamic Pad Creation**: Pads are added with specific options that determine the entire processing pipeline. The `build_stream` callback function converts Membrane stream formats to HLS stream definitions (`HLS.VariantStream` for video tracks, `HLS.AlternativeRendition` for audio/subtitle tracks).

**Codec Serialization**: `Membrane.HLS.serialize_codecs/1` in `lib/membrane/hls.ex` converts codec maps to HLS codec strings:
- avc1 (H.264): `"avc1.{profile}{compatibility}{level}"` (e.g., "avc1.64001f")
- hvc1 (H.265): `"hvc1.{profile}.4.L{level}.B0"`
- mp4a (AAC): `"mp4a.40.{aot_id}"` (e.g., "mp4a.40.2")

**Application Supervision**: The plugin starts an OTP application (`Membrane.HLS.Application`) with supervisors for tracker and task management, enabling concurrent segment processing and playlist monitoring.

**Container Format Flexibility**: The same input stream can be packaged into different containers (CMAF, TS, Packed AAC) by changing the `container` option in pad options, each with optimized processing chains.

### Testing Patterns

Tests use `@tag :tmp_dir` for file-based operations and create complete pipelines with:
- File sources with test fixtures (H.264/AAC in MPEG-TS)
- Demuxing and parsing elements
- SinkBin with different container configurations
- Packager instances with temporary directories

The test structure validates end-to-end functionality from raw media to HLS playlists and segments.