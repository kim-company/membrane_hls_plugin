# RFC 8216 Compliance Testing Roadmap

**Status**: Initial test suite implemented (12 tests, all passing)
**Date**: October 2025
**RFC Reference**: https://datatracker.ietf.org/doc/html/rfc8216

## Executive Summary

An initial RFC 8216 compliance test suite has been implemented with 12 tests covering basic playlist structure, segment timing, codec strings, and warning emission. While these tests provide a foundation for regression testing, **significant additional work is required before production deployment**.

### Critical Finding

Tests currently require unrealistically large target durations (50s) to pass due to segment duration scaling behavior. Production HLS typically uses 2-10s segments. This indicates either:
- Packager behavior that needs investigation/tuning
- Test fixture limitations
- Gap in understanding of actual vs expected behavior

## Current Test Coverage

### ✅ High Confidence Areas

#### 1. Playlist Structure Tests (4 tests)
- **Status**: Solid implementation
- **Coverage**:
  - Master playlists start with #EXTM3U (Section 4.3.1.1)
  - Media playlists contain VERSION and TARGETDURATION (Section 4.3.3)
  - VOD playlists include EXT-X-ENDLIST and TYPE:VOD (Section 4.3.3.5)
  - CMAF playlists include EXT-X-MAP (Section 4.3.2.5)
- **Validation**: Direct parsing of generated playlists
- **Production Ready**: Yes, for VOD scenarios

#### 2. Warning Emission Tests (2 tests)
- **Status**: Functional
- **Coverage**:
  - Warnings emitted when segments exceed target
  - No warnings for compliant streams
- **Validation**: Log capture and pattern matching
- **Production Ready**: Mechanism works, but see concerns below

#### 3. Codec String Tests (1 test)
- **Status**: Working
- **Coverage**: H.264 codec strings follow avc1.PPCCLL format (RFC 6381)
- **Production Ready**: Yes, for H.264

### ⚠️ Medium Confidence Areas

#### 4. Segment Timing Tests (3 tests)
- **Status**: Pass but with workarounds
- **Coverage**:
  - Segments within target duration
  - TARGETDURATION matches configured target
  - Segment duration consistency
- **Concerns**:
  - Requires 50s target (unrealistic for production)
  - Only tests with single fixture (`avsync.ts`)
  - Doesn't verify RFC requirement: TARGETDURATION = ceil(max_segment_duration)
- **Production Ready**: No - needs investigation

#### 5. Positive Compliance Tests (2 tests)
- **Status**: Pass with large targets
- **Coverage**: CMAF and MPEG-TS streams emit no violations
- **Concerns**: Same as segment timing tests
- **Production Ready**: No - validates mechanism, not realistic scenarios

## Major Concerns

### 🚨 1. The 50-Second Target Duration Problem

**Observation**: Test segments scale proportionally with target duration.
- Target 2s → Segments ~2.4s (violation)
- Target 7s → Segments ~7.2s (violation)
- Target 22s → Segments ~24s (violation)
- Target 50s → Segments ~36s (pass)

**Impact**: Not testing realistic production scenarios (2-10s segments).

**Required Actions**:
1. Investigate packager segment cutting behavior
2. Determine if this is expected or bug
3. Document relationship between target_duration and actual segments
4. Consider if kim_hls packager needs configuration/tuning

### 🚨 2. Single Test Fixture Limitation

**Current State**: All tests use single fixture (`test/fixtures/avsync.ts`)

**Risks**:
- Unknown keyframe interval in fixture
- May not represent production media characteristics
- No testing of edge cases (short streams, variable GOPs, etc.)

**Required Actions**: Create controlled test fixtures (see Phase 1 below)

### 🚨 3. Missing Critical RFC Requirements

**Not Tested**:
- EXT-X-TARGETDURATION calculation (MUST be ceil of max segment duration)
- Discontinuity sequence numbering (Section 4.3.2.3)
- Live streaming requirements (EXT-X-MEDIA-SEQUENCE)
- Byte range support for CMAF (Section 4.3.2.2)
- Alternative rendition validation beyond basic structure
- I-frame playlist generation (Section 4.3.4.3)

### 🚨 4. Missing Test Categories from Original Plan

**Planned but Not Implemented**:
- Discontinuity handling tests
- Timestamp drift detection tests
- Track synchronization tests
- Live streaming mode tests (only VOD tested)

## Production Readiness Roadmap

### Phase 1: Fix Test Foundation (Priority: Critical)

**Timeline**: 1-2 weeks
**Blocker**: Must complete before production use

#### 1.1 Create Controlled Test Fixtures

```bash
# Required fixtures
test/fixtures/
├── h264_2s_keyframes.ts      # Predictable 2s GOP, known segment boundaries
├── h264_6s_keyframes.ts      # Realistic 6s segments
├── h264_variable_gop.ts      # Variable GOP size (worst case)
├── short_stream_5s.ts        # Edge case: very short content
├── long_stream_600s.ts       # 10min stream for stress testing
├── h265_4s_keyframes.ts      # HEVC codec validation
└── multi_audio_tracks.ts     # Multiple audio renditions
```

**Creation Method**:
```bash
# Use FFmpeg to create controlled fixtures
ffmpeg -f lavfi -i testsrc=duration=60:size=1280x720:rate=30 \
       -f lavfi -i sine=frequency=440:duration=60 \
       -c:v libx264 -g 60 -keyint_min 60 -sc_threshold 0 \
       -c:a aac -b:a 128k \
       test/fixtures/h264_2s_keyframes.ts
```

#### 1.2 Investigate Segment Duration Behavior

**Tasks**:
1. Add debug logging to packager to understand segment cutting decisions
2. Compare kim_hls behavior with reference implementations
3. Document expected vs actual segment durations
4. File issue if packager behavior is incorrect

**Investigation Questions**:
- Does packager respect target_duration as max or average?
- How does it handle keyframe positions relative to target?
- Is there configuration to tune segment cutting behavior?

#### 1.3 Add Missing RFC Compliance Tests

**High Priority**:
```elixir
test "EXT-X-TARGETDURATION equals ceiling of max segment duration" do
  # RFC 8216 Section 4.3.3.1: MUST be equal to ceiling of max segment
  max_segment = Enum.max(extract_segment_durations(playlist))
  target = extract_target_duration(playlist)
  assert target == ceil(max_segment)
end

test "discontinuity sequence numbers are monotonically increasing" do
  # RFC 8216 Section 4.3.2.3
end

test "media sequence numbers in live playlist" do
  # RFC 8216 Section 4.3.3.2: required for live/event playlists
end
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

### Minimum Bar (Must Have)

- [ ] Tests pass with realistic segment durations (2-10s)
- [ ] All fixtures have documented/known properties
- [ ] Apple mediastreamvalidator passes on generated output
- [ ] Live streaming basic tests implemented and passing
- [ ] At least one external validator integration
- [ ] RFC violation monitoring in place

### Recommended (Should Have)

- [ ] hls.js playback tests passing
- [ ] 24-hour stress test passing
- [ ] Discontinuity handling tested
- [ ] Failure mode tests implemented
- [ ] Production validation pipeline established

### Nice to Have (Optional)

- [ ] Multi-codec test coverage (H.265, AV1)
- [ ] LL-HLS support and testing
- [ ] DRM scenario testing
- [ ] Player compatibility matrix (Safari, Edge, etc.)

## Current Recommendation

**Status**: ⚠️ **Not Production Ready**

**Next Steps** (in order):
1. ✅ Document current state (this roadmap)
2. 🔴 **CRITICAL**: Investigate 50s target duration issue
3. 🔴 **CRITICAL**: Create controlled test fixtures
4. 🔴 **CRITICAL**: Integrate mediastreamvalidator
5. 🟡 Add missing RFC compliance tests (TARGETDURATION calculation)
6. 🟡 Implement live streaming tests
7. 🟢 Add player compatibility tests
8. 🟢 Set up production monitoring

**Safe to Use For**:
- Development/testing environments
- Non-critical VOD workflows
- Internal experimentation

**Not Recommended For**:
- Production live streaming
- Business-critical VOD
- Public-facing services
- SLA-backed deployments

## References

- RFC 8216: https://datatracker.ietf.org/doc/html/rfc8216
- RFC 6381 (Codec Strings): https://datatracker.ietf.org/doc/html/rfc6381
- Apple HLS Authoring Spec: https://developer.apple.com/documentation/http-live-streaming
- hls.js: https://github.com/video-dev/hls.js
- FFmpeg HLS: https://ffmpeg.org/ffmpeg-formats.html#hls-2

## Revision History

- **2025-10-29**: Initial roadmap created after implementing 12 basic RFC 8216 compliance tests
