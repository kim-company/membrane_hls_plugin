# What's Next - Phase 2 Roadmap

**Current Status**: ✅ Phase 1 Complete - Production ready for VOD workflows
**Date**: 2025-10-30

---

## Phase 1 Completion Summary ✅

**Achievements**:
- ✅ 15 RFC 8216 compliance tests (all passing)
- ✅ 9 controlled test fixtures created
- ✅ 50s target duration issue resolved (framerate mismatch)
- ✅ Realistic segment durations tested (2-10s)
- ✅ Production ready for VOD workflows

**Test Suite Status**:
```bash
$ mix test
34 tests, 0 failures ✅
```

---

## Phase 2: External Validation (Next Priority)

**Goal**: Validate HLS output with industry-standard external tools and real players

**Timeline**: 1-2 weeks
**Priority**: High (before large-scale production deployment)

### 2.1 Apple mediastreamvalidator Integration

**What**: Integrate Apple's official HLS validation tool into test suite

**Why**: Apple's tool is the industry standard for HLS validation and catches issues that basic RFC tests might miss

**Requirements**:
- macOS with Xcode Command Line Tools installed
- Access to `mediastreamvalidator` binary

**Implementation**:
```elixir
# File: test/membrane/hls/external_validator_test.exs

@tag :external_validator
@tag :tmp_dir
test "generated streams pass Apple mediastreamvalidator", %{tmp_dir: tmp_dir} do
  {spec, manifest_uri} = build_realistic_pipeline(tmp_dir)
  # Generate HLS stream...

  # Run Apple's validator
  assert {output, 0} = System.cmd("mediastreamvalidator", [
    "--timeout", "30",
    URI.to_string(manifest_uri)
  ])

  refute output =~ "ERROR"
  refute output =~ "WARNING"
end
```

**Effort**: 1-2 days

---

### 2.2 FFmpeg Validation

**What**: Use FFmpeg to decode and validate HLS streams

**Why**: Ensures streams can be decoded without errors by a widely-used media tool

**Implementation**:
```elixir
test "FFmpeg can decode generated stream without errors", %{tmp_dir: tmp_dir} do
  playlist_path = Path.join(tmp_dir, "stream.m3u8")

  # Try to decode the stream to null output
  assert {output, 0} = System.cmd("ffmpeg", [
    "-i", playlist_path,
    "-f", "null",
    "-"
  ])

  refute output =~ "Invalid"
  refute output =~ "Error"
end
```

**Effort**: 1 day

---

### 2.3 hls.js Playback Tests

**What**: Automated browser-based playback testing using hls.js

**Why**: Validates that streams actually play in real web players (Chrome, Firefox, etc.)

**Requirements**:
- Headless browser (Puppeteer/Playwright)
- Local HTTP server to serve HLS files
- hls.js library

**Implementation Approach**:
1. Generate HLS stream to temp directory
2. Start local HTTP server
3. Launch headless browser
4. Load page with hls.js player
5. Verify playback starts within 5s
6. Check for JavaScript errors

**Effort**: 2-3 days

---

### 2.4 Third-Party Validation Tools

**Optional but recommended**:

- **HLS Analyzer**: https://github.com/epiclabs-io/hls-analyzer
- **Online validators**: For manual spot-checks during development

---

## Phase 2 Success Criteria

**Minimum**:
- [ ] Apple mediastreamvalidator passes on VOD streams
- [ ] FFmpeg can decode streams without errors
- [ ] At least one playback test working

**Recommended**:
- [ ] hls.js playback tests for multiple scenarios
- [ ] Validation integrated into CI/CD
- [ ] Validator tests documented in README

---

## Phase 3: Real-World Scenarios (Future)

**Not urgent, but important for comprehensive testing**:

### Live Streaming Tests
- EXT-X-MEDIA-SEQUENCE handling
- Sliding window playlists
- DVR window management

### Stress & Longevity Tests
- 24-hour continuous streams
- Multiple concurrent tracks (20+ video, 10+ audio)
- Stream restart with discontinuities

### Failure Mode Tests
- Storage write failures
- Malformed input buffers
- Packager crash recovery

**Timeline**: 2-3 weeks
**Priority**: Medium (nice to have, not blocking)

---

## Recommendations

### For Immediate Production Use (VOD)

You can safely use the HLS plugin for **production VOD workflows** right now with:
- Segment durations: 2-10s ✅
- CMAF or MPEG-TS containers ✅
- H.264 and H.265 codecs ✅
- Multiple audio tracks ✅

### Before Large-Scale Deployment

Complete **Phase 2** (External Validation) to:
- Catch edge cases that RFC tests might miss
- Validate playback across different players
- Build confidence with industry-standard tools

**Recommended timeline**: 1-2 weeks

### For Live Streaming Production

Wait for **Phase 3** (Real-World Scenarios) or run your own live streaming validation tests.

---

## Quick Start Guide for Phase 2

### Option 1: Apple mediastreamvalidator (macOS only)

```bash
# 1. Install Xcode Command Line Tools
xcode-select --install

# 2. Verify mediastreamvalidator is available
which mediastreamvalidator

# 3. Run against your HLS stream
mediastreamvalidator --timeout 30 /path/to/stream.m3u8
```

### Option 2: FFmpeg Validation (Cross-platform)

```bash
# 1. Install FFmpeg
brew install ffmpeg  # macOS
# or apt-get install ffmpeg  # Linux

# 2. Test decoding
ffmpeg -i /path/to/stream.m3u8 -f null -

# Should complete with exit code 0 and no errors
```

### Option 3: Manual Browser Testing

```bash
# 1. Generate HLS stream to a directory
# 2. Start simple HTTP server
python3 -m http.server 8000

# 3. Open http://localhost:8000 in browser with hls.js demo page
# 4. Point player at your .m3u8 file
# 5. Verify playback works
```

---

## Questions to Consider

Before starting Phase 2:

1. **Do you have access to macOS for mediastreamvalidator?**
   - If yes: Start with 2.1 (Apple validator)
   - If no: Start with 2.2 (FFmpeg validation)

2. **Do you need browser playback testing now?**
   - For public-facing VOD: Yes, do 2.3 (hls.js tests)
   - For internal/backend use: Can defer

3. **What's your production timeline?**
   - Shipping in 1-2 weeks: Focus on Apple validator + FFmpeg
   - Shipping in 1+ month: Complete all of Phase 2

4. **Are you using live streaming?**
   - Yes: Consider starting Phase 3 sooner
   - No (VOD only): Phase 2 is sufficient

---

## Related Documentation

- **Phase 1 Complete**: `docs/PHASE_1_COMPLETE.md`
- **Investigation Report**: `docs/SEGMENT_DURATION_INVESTIGATION.md`
- **Full Roadmap**: `docs/RFC8216_COMPLIANCE_ROADMAP.md`

---

## Summary

🎉 **You've completed Phase 1** - the HLS plugin is production-ready for VOD!

**Next recommended action**: Start Phase 2 with Apple mediastreamvalidator or FFmpeg validation to build additional confidence before large-scale deployment.

**Estimated effort**: 1-2 weeks for complete Phase 2 validation suite.
