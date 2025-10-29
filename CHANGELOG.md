# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] - 2025-01-XX

### 🚨 BREAKING CHANGES

This is a major architectural change that replaces the GenServer-based packager with a pure functional implementation.

#### Removed

- **GenServer-based `HLS.Packager`**: The entire GenServer implementation has been removed
  - `HLS.Packager.start_link/1` no longer exists
  - All GenServer callbacks (`handle_cast`, `handle_call`, `handle_info`) removed
  - Process-based state management removed
  - Automatic async segment uploads removed
  - No more `GenServer.call/cast` for operations

#### Changed

- **Complete API Overhaul**: `HLS.Packager` is now a pure functional module returning state + actions

**Before (GenServer):**
```elixir
{:ok, pid} = HLS.Packager.start_link(
  storage: storage,
  manifest_uri: uri,
  max_segments: 10
)

:ok = HLS.Packager.add_track(pid, "video", opts)
:ok = HLS.Packager.put_segment(pid, "video", payload, 6.0)
:timer.sleep(100)  # Wait for async upload
:ok = HLS.Packager.sync(pid, 3)
```

**After (Functional):**
```elixir
{:ok, state} = HLS.Packager.new(
  manifest_uri: uri,
  max_segments: 10
)

{state, []} = HLS.Packager.add_track(state, "video", opts)

{state, [action]} = HLS.Packager.put_segment(state, "video", duration: 6.0)
# Caller uploads: Storage.put(storage, action.uri, payload)
{state, actions} = HLS.Packager.confirm_upload(state, action.id)
# Caller executes write actions

{state, actions} = HLS.Packager.sync(state, 3)
# Caller executes actions
```

**Migration Guide:**

1. **Replace `start_link/1` with `new/1`**
   - Remove `:storage` option (caller manages storage)
   - Returns `{:ok, state}` instead of `{:ok, pid}`

2. **Thread state explicitly through all operations**
   - All functions now return `{new_state, actions}`
   - State must be passed to next operation

3. **Implement action executor**
   - Functions return actions instead of performing I/O
   - Caller must execute `UploadSegment`, `WritePlaylist`, `DeleteSegment`, etc.
   - See test suite `ActionExecutor` for reference implementation

4. **Remove GenServer calls**
   - No more `GenServer.call(pid, ...)` or `GenServer.cast(pid, ...)`
   - Direct function calls: `Packager.function(state, ...)`

5. **Handle async uploads explicitly**
   - Old: `put_segment/4` uploaded asynchronously
   - New: `put_segment/3` returns `UploadSegment` action, caller uploads, then calls `confirm_upload/2`

6. **Update flush behavior**
   - Signature changed to `flush(state)` instead of `flush(pid)`
   - Returns actions to execute instead of performing operations

#### Added

- **Action-Based Architecture**: All I/O operations return actions for caller execution
  - `HLS.Packager.Action.UploadSegment` - Upload media segment
  - `HLS.Packager.Action.UploadInitSection` - Upload initialization section
  - `HLS.Packager.Action.WritePlaylist` - Write playlist to storage
  - `HLS.Packager.Action.DeleteSegment` - Delete old segment
  - `HLS.Packager.Action.DeleteInitSection` - Delete orphaned init section
  - `HLS.Packager.Action.DeletePlaylist` - Remove playlist file
  - `HLS.Packager.Action.Warning` - RFC 8216 compliance warnings (NEW)

- **RFC 8216 Compliance Warning System**: Automatic detection of violations returned as actions
  - **Segment Exceeds Target Duration** (`:segment_exceeds_target_duration`)
    - Severity: `:error` - RFC violation that may break playback
    - Detected in `put_segment/3` when duration > target duration
    - Returns detailed context: track_id, duration, target_duration, segment_index

  - **Timestamp Drift Detection** (`:timestamp_drift_detected`)
    - Severity: `:error` - RFC violation requiring matching timestamps across variant streams
    - Detected in `sync/2` when variant streams have misaligned program-date-time values
    - Returns drift details: position, timestamps for all tracks, drift in seconds

  - **Unsynchronized Discontinuities** (`:unsynchronized_discontinuity`)
    - Severity: `:warning` - Best practice violation for discontinuity synchronization
    - Detected in `discontinue/1` when tracks have different segment counts
    - Returns segment counts for all tracks

  - **Track Behind Sync Point** (`:track_behind_sync_point`)
    - Severity: `:warning` - Helpful for detecting upload/encoding delays
    - Detected in `sync/2` when track doesn't have enough segments
    - Returns available segments, sync point, missing segment count

- **Warning Action Details**:
  ```elixir
  %HLS.Packager.Action.Warning{
    severity: :error | :warning | :info,
    code: :segment_exceeds_target_duration | :timestamp_drift_detected | ...,
    message: "Human-readable description",
    details: %{...}  # Contextual information for debugging
  }
  ```

- **Flexible Warning Handling**: Caller decides how to handle warnings
  ```elixir
  # Strict mode - abort on errors
  {state, actions} = Packager.put_segment(state, "video", duration: 7.0)
  case Enum.find(actions, &match?(%Action.Warning{severity: :error}, &1)) do
    nil -> execute_actions(actions)
    warning -> {:error, warning}
  end

  # Lenient mode - log and monitor
  {state, actions} = Packager.sync(state, 5)
  actions
  |> Enum.filter(&match?(%Action.Warning{}, &1))
  |> Enum.each(&Logger.warning("[#{&1.code}] #{&1.message}"))
  ```

- **Explicit State Management**: State is immutable and threaded through operations
  - `HLS.Packager.Track` struct exposed for inspection
  - `t()` type spec for packager state
  - All state transformations are pure functions

- **Comprehensive RFC 8216 Compliance Tests**: 13 new compliance tests
  - Playlist format validation (#EXTM3U, UTF-8 encoding)
  - Target duration immutability
  - Segment duration constraints
  - Monotonic sequence number enforcement
  - Discontinuity handling validation
  - Timestamp synchronization across variant streams
  - Discontinuity sequence synchronization
  - Playlist modification rules enforcement

- **New API Functions**:
  - `new/1` - Create new packager state
  - `resume/1` - Resume from existing playlists (caller loads playlists)
  - `confirm_upload/2` - Confirm segment upload completion
  - `confirm_init_upload/2` - Confirm init section upload
  - `put_init_section/2` - Prepare init section upload (returns action)

#### Benefits of Functional Approach

✅ **Testability**: Pure functions, no mocking needed, deterministic behavior
✅ **Composability**: Can be used in any context (GenServers, Tasks, Agents, etc.)
✅ **Explicit Control**: Caller controls all I/O, timing, and concurrency
✅ **No Hidden State**: All state explicit, easier debugging and reasoning
✅ **Lower Overhead**: No process per packager, reduced memory usage
✅ **Better Error Handling**: Errors propagate naturally, no process crashes

#### Trade-offs

⚠️ **More Boilerplate**: Caller must implement action execution and state threading
⚠️ **Manual Concurrency**: No built-in async uploads, caller manages concurrency
⚠️ **State Management**: Must track state explicitly across operations

#### Unchanged

- **HLS.Tracker**: GenServer-based tracker unchanged (use for monitoring live streams)
- **HLS.Storage**: Storage protocol and implementations unchanged
- **HLS.Playlist**: Playlist marshaling/unmarshaling unchanged
- **HLS.Segment**: Segment representation unchanged
- **Exception Definitions**: All `HLS.Packager.*Error` exceptions retained

### Technical Details

- Removed ~1600 lines of GenServer implementation
- Added ~1000 lines of pure functional implementation + warning system
- 37 comprehensive tests with full RFC 8216 compliance validation (including 6 warning system tests)
- Zero external state dependencies
- All operations are referentially transparent
- Warning system adds ~150 lines of validation logic

### Upgrade Path

For applications requiring the old GenServer behavior:

1. Create a wrapper GenServer that uses the functional packager internally
2. Store state in GenServer and execute actions in callbacks
3. See migration guide above for API mapping

Example wrapper pattern:
```elixir
defmodule MyApp.PackagerServer do
  use GenServer

  def handle_call({:put_segment, track_id, duration}, _from, state) do
    {new_state, actions} = HLS.Packager.put_segment(state.packager, track_id, duration: duration)
    # Execute actions...
    {:reply, :ok, %{state | packager: new_state}}
  end
end
```

## [2.5.10] - Previous Release

See git history for previous versions.
