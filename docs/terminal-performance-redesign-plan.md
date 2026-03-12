# Terminal Performance Redesign Plan

> **Status: Implemented.** This plan was completed across issues #14–#18. The codebase now uses
> xterm for rendering, tmux control mode for streaming, and separate persistent shells for
> control/input. This document is retained as an architectural decision record.

Source material:
- Issue: `#14` - `perf: redesign the tmux terminal pipeline to eliminate lag and hot-path inefficiencies`
- Review: `https://github.com/michnovka/mux-pod/issues/14#issuecomment-4042622568`

## Goal

Fix terminal responsiveness for good when users run high-output tools such as Claude or Codex inside tmux panes.

This plan is intentionally architecture-level. The current terminal bottlenecks are not a single bug; they come from the interaction of:
- snapshot polling with `capture-pane`
- a RichText-based snapshot renderer
- per-key SSH exec calls
- whole-buffer diff and ANSI parse work on every poll

The solution is to move the active terminal path onto a real terminal emulator and a streaming tmux-native transport, while keeping the current low-risk optimizations that already work well.

## Non-Negotiable Product Requirements

MuxPod remains a tmux control app first. The performance redesign must not remove the interaction model that makes tmux usable on a phone-sized screen.

The following are hard requirements:

1. No tmux feature regressions in the active terminal workflow.
2. Vertical scrollback remains easy and fast on Android.
3. Horizontal navigation remains available for narrow screens and wide terminal content.
4. Text selection remains available in a dedicated, reliable mode.
5. Session, window, and pane switching remain tmux-driven.
6. Resize, reconnect, and special-key workflows remain supported.

The redesign is complete only when these behaviors still work in the new terminal pipeline.

## Final Decisions

1. The active terminal will move to an emulator-backed terminal surface.
   The current `AnsiTextView` and `RichText` renderer are not the right foundation for sustained interactive output.

2. tmux control mode is the primary live transport architecture.
   `capture-pane` remains only for bootstrap and resync. If control mode proves incompatible on a target server, pane-scoped streaming remains the fallback path.

3. Input will move to a persistent writer.
   Per-key `tmux send-keys` exec calls must be removed from the active terminal path.

4. The reconnect state machine will be extended, not rewritten.
   The existing SSH reconnect flow is good enough to build on.

5. Provider and app-wide cleanup will be targeted, not a broad rewrite.
   We will preserve the current `ValueNotifier` isolation, scoped `Consumer` usage, lazy tab initialization, and the current reconnect structure.

## Proven Problems To Fix

These are the problems that are clearly real and worth solving in the main implementation path:

1. `capture-pane -e -S -1000` polling is the dominant steady-state cost.
2. `AnsiTextView` reparses ANSI text and rebuilds terminal line widgets repeatedly.
3. Cursor rendering depends on `TextPainter.layout()` in the hot path.
4. Input uses one SSH exec channel per key or command send.
5. `TerminalDiff` still does O(n) line split and hash work per poll cycle.
6. The existing persistent shell can only run one command at a time, so a streaming redesign must not force input, keepalive, and control commands through the same single-command channel.
7. Hot-path logging is too verbose for terminal and tmux payloads.

## Existing Optimizations To Preserve

These are already good and should survive the redesign:

1. `_TerminalViewData` and `ValueNotifier` keep the parent terminal screen from rebuilding on every update.
2. `Consumer` scoping and `select(...)` usage already limit rebuild scope better than a naive Riverpod design would.
3. The current polling path already batches three tmux queries into one persistent-shell command. That is worth preserving in any temporary bridge state.
4. The 60 FPS frame-skip throttle is useful and should be preserved in the new terminal update path where it still applies.
5. The reconnect and network-pause logic in `ssh_provider.dart` is already structured as a usable state machine.

## Target End-State Architecture

### 1. Active Terminal Runtime

Introduce a dedicated active-terminal runtime for the current connection and pane.

Recommended structure:
- `TerminalSessionController`
- `TmuxControlClient`
- `TerminalSurfaceAdapter`
- `TmuxSnapshotBootstrap`

Responsibilities:
- own the active tmux control-mode session
- own the active terminal emulator instance
- stream pane output notifications directly into the emulator
- send user input directly to the PTY writer
- use snapshot bootstrap for connect, reconnect, and pane-switch resync
- keep a separate control path for tmux commands and metadata queries during migration
- coordinate reconnect and resync

### 2. Renderer

Replace `AnsiTextView` with an emulator-backed terminal widget.

Primary candidate:
- `xterm`

Selection criteria:
- incremental terminal buffer updates
- proper cursor and scrollback handling
- selectable text
- Android support
- controllable font and theme integration
- support for special keys and paste

The emulator layer must replace:
- ANSI regex parsing in the hot path
- `RichText` line reconstruction
- manual cursor overlay with `TextPainter`
- `TerminalDiff` as part of normal rendering

The renderer migration must preserve current mobile ergonomics:
- vertical scroll through scrollback/history
- horizontal navigation for overflowed terminal content on narrow screens
- explicit text selection behavior suitable for touch devices

Vertical scrollback and text selection are expected to come from the emulator layer.
Horizontal navigation must be preserved intentionally, either through an emulator-compatible horizontal viewport strategy or an equivalent interaction model. It is not acceptable to regress this behavior accidentally during the emulator swap.

### 3. Streaming Transport

The active terminal should run through a long-lived tmux control-mode session.

Primary model:
- open an interactive SSH shell with terminal type `dumb`
- start `tmux -C attach-session` inside that shell
- parse `%output pane-id value` notifications
- feed the active pane's decoded output directly into the emulator
- use `capture-pane` only to seed the emulator on connect, reconnect, and pane switch

Important constraint:
- do not reuse the current single-command persistent shell for terminal I/O
- keep control-mode streaming and persistent-shell control commands on separate channels

### 4. Control Path

Keep a separate tmux control path for commands that should not be typed into the terminal stream.

Examples:
- list sessions, windows, panes
- select pane
- select window
- switch session
- enter or exit copy mode if still needed
- targeted metadata queries during reconnect or manual refresh

This control path can initially use:
- the existing `execPersistent`
- or a second dedicated persistent shell

It should remain serialized and explicit. The active terminal PTY and the control channel must not block each other.

### 5. Metadata Sync

Metadata should become mostly action-driven instead of timer-driven.

Rules:
- do a full tmux tree fetch on connect
- do a full tmux tree fetch on reconnect completion
- do a full tmux tree fetch on explicit manual refresh
- after app-initiated tmux actions, update state from targeted control responses
- only fall back to broad resync when desync is detected

This means the current 10-second tree refresh timer can leave the hot path.

### 6. Reconnect

Keep the current SSH reconnect flow and extend it for the new transport.

Reconnect responsibilities:
- restore SSH transport
- recreate the streaming PTY session
- recreate the control path
- resync session, window, and pane state
- restore the active target
- resend terminal size
- restore input handling

Do not rewrite the reconnect policy from scratch.

## Delivery Plan

## Phase 0 - Validation And Guardrails

Goal:
Lock the implementation direction before changing the hot path.

Tasks:
- verify the chosen terminal emulator package against Android requirements
- verify `dartssh2` capabilities for a long-lived PTY plus a concurrent control channel
- define the public interfaces for terminal surface, streaming transport, and control transport
- add measurement hooks for:
  - poll duration
  - payload bytes
  - render/update frequency
  - input latency
  - reconnect recovery time

Exit criteria:
- emulator package choice is locked
- streaming PTY design is confirmed feasible with `dartssh2`
- new terminal interfaces are defined

## Phase 1 - Emulator Surface Swap

Goal:
Remove the RichText terminal renderer from the active path.

Tasks:
- add the emulator dependency and a wrapper adapter
- integrate the emulator widget into `TerminalScreen`
- map theme, font family, font size, and cursor visibility into the emulator
- preserve terminal chrome:
  - header
  - pane indicator
  - special keys bar
  - pane navigation gestures where still applicable
- keep the current transport temporarily if needed while the renderer is swapped

Important note:
- this phase may temporarily bridge snapshot updates into the emulator while transport is still being replaced
- if that bridge is too awkward or unstable, Phase 1 and Phase 2 can be merged into a single implementation slice

Exit criteria:
- `AnsiTextView` is no longer the active renderer
- ANSI parse and `TextPainter` cursor work are removed from the main render path

## Phase 2 - Streaming PTY Transport And Persistent Input

Goal:
Remove active-pane snapshot polling and per-key exec calls.

Tasks:
- add a dedicated tmux control-mode session for the active terminal
- attach or reattach that control client to the active session
- feed active-pane control-mode output directly into the emulator
- route all normal input through the PTY writer
- route paste through buffered chunked writes
- keep snapshot bootstrap for connect, reconnect, and pane switch
- keep control actions on a sidecar persistent channel during migration
- remove per-key exec usage from:
  - `_sendKeyData`
  - `_sendKey`
  - `_sendSpecialKey`

Explicit design rule:
- the active PTY and the control path must be separate because the current persistent shell only supports one in-flight command

Exit criteria:
- no steady-state `capture-pane` polling for the active pane
- no per-key SSH exec calls in the active terminal path
- terminal output is driven by tmux control-mode pane output, not repeated pane snapshots

## Phase 3 - tmux State Sync Redesign

Goal:
Replace timer-driven tmux state refresh with targeted sync and recovery.

Tasks:
- remove the 10-second tree refresh from normal terminal use
- update session/window/pane state from explicit control responses after app-initiated actions
- keep manual refresh as an explicit resync tool
- implement desync detection and targeted recovery
- add a low-frequency fallback resync only if real gaps remain after testing

Optional track:
- evaluate tmux control mode for richer async metadata on supported servers
- only pursue this if the streaming PTY plus sidecar control path still leaves important metadata gaps

Exit criteria:
- timer-driven full-tree refresh is no longer part of normal active terminal operation
- metadata stays correct through normal pane, window, and session actions

## Phase 4 - Focused Cleanup

Goal:
Remove legacy hot-path code and fix the proven secondary inefficiencies.

Tasks:
- delete or retire:
  - `AnsiTextView`
  - hot-path `AnsiParser` usage
  - `TerminalDiff` from active rendering
  - snapshot-only terminal code that is no longer needed
- remove raw tmux payload logging from hot paths
- wire `scrollbackLines` into the real terminal buffer
- batch or debounce `ActiveSessionsNotifier` persistence where it is still noisy
- narrow broad `activeSessionsProvider` watchers in offscreen or list UIs where cheap selectors are enough
- avoid redundant provider invalidation after forms that already update in-memory state

Out of scope for this phase:
- broad provider architecture rewrites
- startup bootstrapping changes unless they directly block the new terminal path

Exit criteria:
- the legacy snapshot renderer and its helpers are out of the active path
- only proven cleanup items are changed

## Phase 5 - Tests, Benchmarks, And Rollout

Goal:
Prevent regressions and prove the redesign actually fixed the problem.

Tasks:
- add unit tests for:
  - streaming transport lifecycle
  - control channel behavior
  - reconnect and resync
  - input queue semantics
  - pane switching and resize handling
- add integration tests for:
  - terminal startup
  - reconnect recovery
  - session and pane switching
- add performance measurements for:
  - sustained output throughput
  - typing latency under concurrent output
  - paste latency
  - reconnect time
  - memory and CPU behavior during long sessions

Exit criteria:
- benchmark results are recorded
- the new path is measurably better than the snapshot path
- legacy path can be safely removed or permanently disabled

## Acceptance Criteria

The redesign is done only when all of the following are true:

1. The active terminal is rendered by a real emulator-backed surface.
2. The active terminal no longer uses steady-state `capture-pane` polling.
3. The active terminal no longer sends one SSH exec call per key input.
4. The active terminal path no longer depends on whole-buffer ANSI parsing and `RichText` reconstruction.
5. `TerminalDiff` O(n) split and hash work is removed from the active terminal hot path.
6. The active PTY stream and the tmux control path do not contend on the same single-command shell.
7. The 10-second full tree refresh timer is no longer part of normal active terminal use.
8. Reconnect restores the terminal cleanly without falling back to the old snapshot architecture.
9. Hot-path logging no longer dumps large tmux or terminal payloads.
10. Terminal responsiveness is clearly improved under sustained high-output tmux workloads.
11. Users can still navigate terminal content effectively on a phone:
    - vertical scrollback works
    - horizontal navigation works
    - text can be selected and copied reliably

## Implementation Notes

1. The safest critical path is:
   emulator-backed terminal first, tmux control-mode streaming second, pipe-pane or snapshot fallback only if compatibility requires it.

2. If Phase 1 reveals that an emulator bridge over the old snapshot transport is too awkward, collapse Phase 1 and Phase 2 into one milestone.

3. We should not spend time rewriting provider structure that already works unless profiling shows it is still materially visible after the terminal path is fixed.

4. The issue is not one function or one widget. We should expect this work to touch:
   - terminal UI
   - SSH transport
   - tmux control services
   - reconnect orchestration
   - tests and benchmarks
