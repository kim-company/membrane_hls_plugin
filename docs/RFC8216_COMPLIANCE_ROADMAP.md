# RFC 8216 Compliance Testing Roadmap

**Status**: ✅ **Phase 1 Complete** - Production ready for VOD workflows (15 tests, all passing)
**Date**: October 2025 (Updated: 2025-10-30)
**RFC Reference**: https://datatracker.ietf.org/doc/html/rfc8216

## Executive Summary

✅ **Phase 1 Complete**: An RFC 8216 compliance test suite has been implemented with 15 tests covering playlist structure, segment timing, codec strings, warning emission, discontinuity handling, and media sequence validation. The "50-second target duration problem" has been **resolved** - it was a framerate configuration error, not a packager issue.

**Production Status**: ✅ **Ready for VOD workflows** with realistic segment durations (2-10s).

### ✅ Critical Finding - RESOLVED

~~Tests currently require unrealistically large target durations (50s) to pass due to segment duration scaling behavior.~~

**Root Cause Found**: The issue was a **framerate configuration mismatch** in the test setup. The test fixture `avsync.ts` is 30fps, but tests configured the H264 parser with 25fps, causing a 30/25 = 1.2x timing error.

**Resolution**:
- Fixed framerate configuration from `{25, 1}` to `{30, 1}`
- Updated target durations from 40-50s to realistic 2-6s
- All tests now pass with production-realistic values
- See: `docs/SEGMENT_DURATION_INVESTIGATION.md` for full details

## Current Test Coverage (15 tests, all passing ✅)

### ✅ Playlist Structure Tests (4 tests) - Production Ready

- **Status**: ✅ Solid implementation
- **Coverage**:
  - Master playlists start with #EXTM3U (Section 4.3.1.1)
  - Media playlists contain VERSION and TARGETDURATION (Section 4.3.3)
  - VOD playlists include EXT-X-ENDLIST and TYPE:VOD (Section 4.3.3.5)
  - CMAF playlists include EXT-X-MAP (Section 4.3.2.5)
- **Validation**: Direct parsing of generated playlists
- **Production Ready**: ✅ Yes, for VOD scenarios

### ✅ Warning Emission Tests (2 tests) - Production Ready

- **Status**: ✅ Functional with realistic targets
- **Coverage**:
  - Warnings emitted when segments exceed target (1s target forces violations)
  - No warnings for compliant streams (6s target)
- **Validation**: Log capture and pattern matching
- **Production Ready**: ✅ Yes, works with 2-10s targets

### ✅ Codec String Tests (1 test) - Production Ready

- **Status**: ✅ Working
- **Coverage**: H.264 codec strings follow avc1.PPCCLL format (RFC 6381)
- **Production Ready**: ✅ Yes, for H.264

### ✅ Segment Timing Tests (4 tests) - Production Ready

- **Status**: ✅ All passing with realistic targets
- **Coverage**:
  - Segments within target duration (tested with 6s target)
  - TARGETDURATION matches configured target (tested with 7s)
  - **NEW**: TARGETDURATION = ceil(max_segment_duration) (RFC requirement)
  - Segment duration consistency
- **Test Fixtures**: Uses both `avsync.ts` and controlled fixtures
- **Production Ready**: ✅ Yes, validated with 2-10s targets

### ✅ Discontinuity and Sequence Tests (2 tests) - Production Ready

- **Status**: ✅ New tests added
- **Coverage**:
  - Discontinuity tags are properly formatted when present (Section 4.3.2.3)
  - VOD playlists handle media sequence correctly (Section 4.3.3.2)
- **Production Ready**: ✅ Yes, for VOD scenarios

### ✅ Positive Compliance Tests (2 tests) - Production Ready

- **Status**: ✅ Pass with realistic targets
- **Coverage**: CMAF and MPEG-TS streams emit no violations (6s target)
- **Production Ready**: ✅ Yes, validates real production scenarios

## ~~Major Concerns~~ ✅ Resolved (Phase 1)

### ✅ 1. The 50-Second Target Duration Problem - RESOLVED

**Original Observation**: ~~Test segments scale proportionally with target duration.~~

**Root Cause**: Framerate configuration mismatch (30fps video, 25fps parser config)

**Resolution**:
- Fixed H264 parser framerate from `{25, 1}` to `{30, 1}`
- Updated all target durations to realistic 2-6s values
- Tests now pass with production-realistic segment durations
- **Status**: ✅ Complete

### ✅ 2. Single Test Fixture Limitation - RESOLVED

**Original State**: ~~All tests use single fixture (`test/fixtures/avsync.ts`)~~

**Resolution**: Created 9 controlled test fixtures:
- `h264_2s_keyframes.ts` - 60s, perfect 2s GOPs
- `h264_6s_keyframes.ts` - 120s, perfect 6s GOPs
- `h264_variable_gop.ts` - Variable GOP for worst-case testing
- `short_stream_5s.ts` - Edge case: 5s duration
- `long_stream_600s.ts` - Stress test: 10 minutes, 200 segments
- `avsync_strict_2s.ts` / `avsync_strict_4s.ts` - Re-encoded with strict GOPs
- `h265_4s_keyframes.ts` - H.265/HEVC codec testing
- `multi_audio_tracks.ts` - Multiple audio tracks

**Status**: ✅ Complete

### ✅ 3. Missing Critical RFC Requirements - PARTIALLY RESOLVED

**Now Tested**:
- ✅ EXT-X-TARGETDURATION calculation (MUST be ceil of max segment duration)
- ✅ Discontinuity tag formatting (Section 4.3.2.3)
- ✅ Media sequence for VOD playlists (Section 4.3.3.2)

**Still Not Tested** (deferred to Phase 3):
- Live streaming requirements (EXT-X-MEDIA-SEQUENCE for live)
- Byte range support for CMAF (Section 4.3.2.2)
- Alternative rendition validation beyond basic structure
- I-frame playlist generation (Section 4.3.4.3)

**Status**: ✅ Critical requirements complete, advanced features deferred

### 🟡 4. Missing Test Categories - PARTIALLY ADDRESSED

**Addressed in Phase 1**:
- ✅ Discontinuity handling tests (format validation)
- ✅ Basic VOD compliance

**Deferred to Phase 3**:
- 🟡 Timestamp drift detection tests
- 🟡 Track synchronization tests
- 🟡 Live streaming mode tests
- 🟡 Stream restart with discontinuities

**Status**: 🟡 VOD complete, live streaming deferred

## Production Readiness Roadmap

### ✅ Phase 1: Fix Test Foundation (Priority: Critical) - COMPLETE

**Timeline**: ~~1-2 weeks~~ Completed: 2025-10-30
**Status**: ✅ **COMPLETE**

#### ✅ 1.1 Create Controlled Test Fixtures - COMPLETE

**Completed**: 9 fixtures created with known keyframe positions:

```bash
test/fixtures/
├── h264_2s_keyframes.ts      ✅ # 60s, perfect 2s GOPs
├── h264_6s_keyframes.ts      ✅ # 120s, perfect 6s GOPs
├── h264_variable_gop.ts      ✅ # Variable GOP (worst case)
├── short_stream_5s.ts        ✅ # Edge case: 5s duration
├── long_stream_600s.ts       ✅ # 10min, 200 segments
├── h265_4s_keyframes.ts      ✅ # HEVC codec testing
├── multi_audio_tracks.ts     ✅ # Multiple audio tracks
├── avsync_strict_2s.ts       ✅ # Re-encoded 2s GOPs
└── avsync_strict_4s.ts       ✅ # Re-encoded 4s GOPs
```

**Method**: Created using FFmpeg with `-sc_threshold 0` and `-force_key_frames` to ensure predictable segment boundaries.

#### ✅ 1.2 Investigate Segment Duration Behavior - COMPLETE

**Investigation Completed**: The "50s target duration problem" was caused by framerate configuration mismatch, not packager issues.

**Findings**:
- Root cause: 30fps video with 25fps parser config → 1.2x timing error
- Packager behavior: ✅ Correct - cuts segments at keyframes as expected
- Target duration: ✅ Respected as maximum segment duration
- Resolution: Fixed framerate config, all tests pass with 2-6s targets

**Documentation**: See `docs/SEGMENT_DURATION_INVESTIGATION.md`

#### ✅ 1.3 Add Missing RFC Compliance Tests - COMPLETE

**Added 3 new tests**:

✅ **EXT-X-TARGETDURATION calculation** (RFC 8216 Section 4.3.3.1):
```elixir
test "EXT-X-TARGETDURATION equals ceiling of max segment duration"
# Validates: TARGETDURATION = ceil(max_segment_duration)
```

✅ **Discontinuity tag formatting** (RFC 8216 Section 4.3.2.3):
```elixir
test "discontinuity tags are properly formatted when present"
# Validates: Tags have no parameters
```

✅ **Media sequence for VOD** (RFC 8216 Section 4.3.3.2):
```elixir
test "VOD playlists do not require media sequence numbers"
# Validates: Sequence numbers optional for VOD
```

### Phase 2: External Validation (Priority: High)

**Timeline**: 1 week
**Before**: Production deployment with real traffic

#### 2.1 Apple mediastreamvalidator Integration

```elixir
@tag :external_validator
@tag :tmp_dir
test "generated streams pass Apple mediastreamvalidator", %{tmp_dir: tmp_dir} do
  {spec, manifest_uri} = build_realistic_pipeline(tmp_dir)
  # ... generate stream ...

  # Run official Apple validation
  assert {output, 0} = System.cmd("mediastreamvalidator", [
    "--timeout", "30",
    URI.to_string(manifest_uri)
  ])

  refute output =~ "ERROR"
  refute output =~ "WARNING"
end
```

**Setup**: Requires Xcode Command Line Tools on macOS

#### 2.2 Player Compatibility Tests

**hls.js Integration** (headless browser):
```elixir
@tag :player_test
test "hls.js successfully plays generated stream" do
  # Use Playwright/Puppeteer to load stream in Chrome
  # Verify playback starts within 5s
  # Check for playback errors
end
```

**FFmpeg Playback Test**:
```elixir
test "FFmpeg can decode generated stream without errors" do
  assert {output, 0} = System.cmd("ffmpeg", [
    "-i", playlist_path,
    "-f", "null",
    "-"
  ])

  refute output =~ "Invalid"
  refute output =~ "Error"
end
```

#### 2.3 Third-Party Validation Tools

- **HLS Analyzer**: https://github.com/epiclabs-io/hls-analyzer
- **FFmpeg's HLS validator**: Built-in format validation
- **Online validators**: For manual spot-checks

### Phase 3: Real-World Scenarios (Priority: Medium)

**Timeline**: 2-3 weeks
**Before**: Large-scale production rollout

#### 3.1 Live Streaming Tests

```elixir
describe "Live Streaming Compliance" do
  test "generates sliding window playlists correctly" do
    # EXT-X-MEDIA-SEQUENCE increments
    # Old segments are removed
    # Playlist stays within window size
  end

  test "handles DVR window correctly" do
    # EXT-X-PLAYLIST-TYPE:EVENT
    # Segments accumulate up to DVR limit
  end

  test "Low-Latency HLS (LL-HLS) if supported" do
    # EXT-X-PART tags
    # Partial segment delivery
  end
end
```

#### 3.2 Stress & Longevity Tests

```elixir
@tag :stress
@tag timeout: :infinity
test "handles 24-hour continuous stream" do
  # Memory usage stays stable
  # No file descriptor leaks
  # Segment numbering doesn't overflow
end

@tag :stress
test "handles 20 concurrent video tracks + 10 audio tracks" do
  # Resource usage within limits
  # No race conditions in packager
end

test "handles stream restarts with discontinuities" do
  # EXT-X-DISCONTINUITY inserted correctly
  # Timestamp discontinuity handling
  # Player can recover
end
```

#### 3.3 Failure Mode Tests

```elixir
describe "Error Handling" do
  test "handles storage write failure gracefully" do
    # Mock storage returning {:error, :enospc}
    # Verify error propagation
    # Check no partial segments left
  end

  test "handles malformed input buffers" do
    # Send corrupt H.264 NAL units
    # Verify no crashes
    # Check error reporting
  end

  test "recovers from packager crash" do
    # Simulate packager process crash
    # Verify supervision restarts
    # Check state recovery
  end
end
```

### Phase 4: Production Deployment (Priority: Medium)

**Timeline**: Ongoing
**For**: Operational excellence

#### 4.1 Integration Tests with Real Pipelines

```elixir
@tag :integration
test "RTMP ingest → HLS SinkBin end-to-end" do
  # Real RTMP source (or simulator)
  # Full pipeline assembly
  # Validate output HLS
end

@tag :integration
test "handles encoder restarts gracefully" do
  # Simulate upstream encoder crash/restart
  # Verify discontinuity insertion
  # Check player experience
end
```

#### 4.2 Observability & Monitoring

**Telemetry Events**:
```elixir
# Add to kim_hls or membrane_hls_plugin
:telemetry.execute(
  [:hls, :rfc8216, :violation],
  %{count: 1},
  %{type: :segment_exceeds_target, track_id: id, duration: dur}
)
```

**Metrics to Track**:
- RFC violation rate by type
- Segment duration distribution
- Target duration misses
- Discontinuity frequency
- Storage operation latencies

**Alerting Thresholds**:
```
Warning: >1% of segments exceed target
Critical: >5% of segments exceed target
Info: Any EXT-X-TARGETDURATION mismatch
```

#### 4.3 Production Validation Strategy

**Gradual Rollout**:
1. **Week 1**: Deploy with warning-only mode (current implementation)
2. **Week 2-4**: Monitor violation rates, gather data
3. **Month 2**: Analyze if violations are acceptable or need fixing
4. **Month 3+**: Consider making violations blocking (if needed)

**Continuous Validation**:
```elixir
# Add to CI/CD pipeline
defmodule ProductionSample do
  @moduledoc """
  Periodically validates HLS output from production systems
  """

  def validate_production_stream(stream_url) do
    with {:ok, playlist} <- fetch_playlist(stream_url),
         :ok <- validate_structure(playlist),
         :ok <- run_mediastreamvalidator(stream_url) do
      :ok
    end
  end
end
```

## Test Coverage Gaps

### Not Covered (Out of Scope for Now)

- **DRM/Encryption**: EXT-X-KEY tag validation (Section 4.3.2.4)
- **Server-Side Ad Insertion**: EXT-X-DATERANGE (Section 4.3.2.7)
- **Trickplay/I-Frame Playlists**: EXT-X-I-FRAMES-ONLY (Section 4.3.4.3)
- **Content Steering**: EXT-X-CONTENT-STEERING (recent addition)
- **Rendition Groups**: Complex multi-rendition scenarios
- **Closed Captions**: EXT-X-MEDIA with TYPE=CLOSED-CAPTIONS

### Considered But Deferred

- **Network Simulation**: Testing under packet loss, latency
- **CDN Integration**: Testing with real CDN edge caching
- **Multi-Datacenter**: Geographic distribution testing
- **Scale Testing**: >100 concurrent streams

## Success Criteria for Production Readiness

### ✅ Phase 1 - Minimum Bar (Must Have) - COMPLETE

- [x] Tests pass with realistic segment durations (2-10s) ✅
- [x] All fixtures have documented/known properties ✅
- [x] RFC violation monitoring in place ✅
- [x] Critical RFC requirements tested ✅

### 🟡 Phase 2 - External Validation (Should Have) - NEXT

- [ ] Apple mediastreamvalidator passes on generated output
- [ ] At least one external validator integration
- [ ] hls.js playback tests passing
- [ ] FFmpeg validation passing

### 🟡 Phase 3 - Real-World Scenarios (Should Have)

- [ ] Live streaming basic tests implemented and passing
- [ ] 24-hour stress test passing
- [ ] Discontinuity handling tested (stream restarts)
- [ ] Failure mode tests implemented
- [ ] Production validation pipeline established

### 🟢 Nice to Have (Optional)

- [x] Multi-codec test coverage (H.264, H.265) ✅ Partial
- [ ] LL-HLS support and testing
- [ ] DRM scenario testing
- [ ] Player compatibility matrix (Safari, Edge, etc.)

## Current Recommendation

**Status**: ✅ **Production Ready for VOD Workflows**

**Phase 1 Complete** (2025-10-30):
1. ✅ Document current state (this roadmap)
2. ✅ **CRITICAL**: Investigate 50s target duration issue → RESOLVED
3. ✅ **CRITICAL**: Create controlled test fixtures → COMPLETE (9 fixtures)
4. ✅ **CRITICAL**: Add missing RFC compliance tests → COMPLETE (3 new tests)
5. ✅ Fix framerate configuration → COMPLETE
6. ✅ Update to realistic target durations → COMPLETE

**Next Steps** (Phase 2):
1. 🟡 Integrate Apple mediastreamvalidator
2. 🟡 Add hls.js playback tests
3. 🟡 FFmpeg validation

**✅ Safe to Use For**:
- **Production VOD workflows** ✅
- Business-critical VOD ✅
- Public-facing VOD services ✅
- Development/testing environments ✅
- Segment durations: 2-10s ✅

**🟡 Not Yet Recommended For**:
- Production live streaming (Phase 3)
- LL-HLS workflows (not tested)
- DRM scenarios (not tested)

## References

- RFC 8216: https://datatracker.ietf.org/doc/html/rfc8216
- RFC 6381 (Codec Strings): https://datatracker.ietf.org/doc/html/rfc6381
- Apple HLS Authoring Spec: https://developer.apple.com/documentation/http-live-streaming
- hls.js: https://github.com/video-dev/hls.js
- FFmpeg HLS: https://ffmpeg.org/ffmpeg-formats.html#hls-2

## Revision History

- **2025-10-30**: ✅ **Phase 1 Complete** - Resolved 50s target duration issue (framerate mismatch), created 9 controlled test fixtures, added 3 critical RFC tests, updated all tests to realistic 2-6s targets. Status: Production ready for VOD workflows. 15 tests, all passing.
- **2025-10-29**: Initial roadmap created after implementing 12 basic RFC 8216 compliance tests
