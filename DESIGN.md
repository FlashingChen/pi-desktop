---
name: Pi Desktop
description: Native macOS Pi workspace; graphite canvas with project tabs and optional session sidebar.
colors:
  canvas: "#fcfcfc"
  sidebar: "#f0f2f4"
  surface: "#ffffff"
  text: "#242628"
  secondary: "#60666b"
  accent: "#476781"
  user-bubble: "#eff1f2"
  code: "#f3f4f5"
  line: "#e3e5e7"
  selected: "#dce5ec"
typography:
  body:
    fontFamily: "system"
    fontSize: "14pt"
  label:
    fontFamily: "system"
    fontSize: "12pt"
  metadata:
    fontFamily: "system"
    fontSize: "11pt"
  code:
    fontFamily: "system monospace"
    fontSize: "12pt"
  pi-mark:
    fontFamily: "Georgia-Italic"
rounded:
  control: "6pt"
  composer: "12pt"
  code: "10pt"
  user-bubble: "14pt"
spacing:
  composer-inset: "15pt"
  column-gutter: "40pt"
  message-gap: "32pt"
---

# Pi Desktop · Direction C

## Approved composition

Source of truth is `Sources/PiDesktop` plus this document. Do not reintroduce the superseded floating-card composition or its clay palette.

This is a native macOS SwiftUI/AppKit application, not a web renderer. It presents installed, unmodified Pi through its RPC interface and original terminal. Do not add agent, approval, planning, or subagent behaviors.

## Canvas and navigation

Use a flat full-window reading canvas with a 53pt toolbar. Projects are horizontally scrolling tabs; a 2pt underline marks the current project. Keep the selected tab visible and truncate long folder names. Native macOS traffic-light space remains clear. The default window is 1280 × 800pt, minimum 820 × 640pt.

The 238pt session sidebar starts closed and opens with the toolbar control or Cmd-K. Cmd-K also focuses search. Preserve projects and sessions as a hierarchy in the sidebar. While it is closed, toolbar actions still expose new conversation, open project, original Pi CLI, search and settings. Native menu commands retain keyboard shortcuts.

The reading column and composer share a maximum 740pt width with 40pt horizontal gutters; they contract with window space. The central work surface has no outer rounded card, backdrop gradient or decorative shadow.

## Appearance

Dark is the initial preference. Settings switches between dark, light and system appearance immediately, independently of Pi connection settings.

Dark colors: canvas `#23272d`, sidebar `#20242a`, surface `#2b3037`, text `#e5e9ed`, secondary `#a4adb7`, line `#3a424b`, user bubble `#30363e`, code `#292f37`, selection `#3c4856`, accent `#9eb5c8`, and text on accent `#1d252b`. Light counterparts are in frontmatter and `Theme`.

Use system type for interface/prose and system monospace for code/paths. Only the π mark uses Georgia Italic. Interface icons are native SF Symbols. The semantic accent replaces the previous `clay` token. Keep user messages in tonal bubbles; assistant prose remains on the canvas.

## Composer and command completion

The AppKit text input preserves marked IME text. Enter sends; Shift-Enter inserts a newline. Once a project is selected, drafts are editable while connecting; sending waits for authoritative Pi state and history. Draft text uses an independent DraftBuffer observable object so typing does not invalidate the conversation, execution grouping or Markdown. Drafts/images survive session round trips in memory. Edits during internal session transitions are disabled while an existing connected session is being switched.

Command completion is a distinct layer above the entire composer, aligned to its leading edge and capped at 490pt width. Bound its height by available space and scroll candidates. `/` alone lists commands; prefix matches rank first. ↑↓ selects, Enter/Tab fills, Escape closes without deleting the draft. Command names and descriptions occupy separate lines; source labels and keyboard hints stay secondary. Expose All / Skills / Extensions / Prompts with actual counts. Preserve sourceInfo path and package for provenance. Open/refresh reads the native Pi catalogue; query filtering uses a pre-normalized local index with no debounce or request per letter. Hover never changes keyboard selection. Candidate rendering and scroll targets use the canonical source/name ID exclusively; never overlay a positional .id(index). Use immediate rows for this small filtered catalogue. Sequential-render snapshot tests must match a fresh list for the same query; a correct count or successful Tab completion alone does not validate the displayed row. A catalogue refresh failure preserves the last successful list and exposes a retry indicator. Model selection, thinking levels, attachments, abort and native Pi queue choices remain functional.

Model, command and statistics discovery publishes independently in the background. Failure in optional discovery must not disconnect a ready session. Status text is factual; do not substitute demo performance claims or fake readiness.

## Conversation and execution

Keep prose and inline/fenced Markdown selectable, with code copy controls and horizontally scrolling code. Preserve native images, tool results, thinking and Bash output.

Each user turn has one collapsed execution summary, including reasoning from the final assistant message. Reasoning has a single entry; tool calls and results pair by toolCallId, preserving orphan results and distinct calls of the same tool. Prose stays visible after the summary. Arguments/output materialize on expansion. Previews cap large output at 16,000 characters with full-content copying. A running marker belongs only to the latest execution group. Respect Reduce Motion.

Streaming follows only while the reader remains near the bottom. Scrolling upward exposes jump-to-latest. Main history is always read from native Pi; there is no competing GUI history database or arbitrary cached-session fallback.

## Interaction and verification

`InteractionStyles.swift` defines shared hover, pressed, selected, disabled and focus feedback. AppKit tracking areas do not consume clicks. Copy shows completion feedback. Native menus, sheets and terminal retain their platform semantics.

The JSONL decoder scans each newly received byte once; it never rescans the full partial response per pipe chunk. The native opt-in startup benchmark has a 2000 ms local regression ceiling; multi-MB framing has an independent guard.

Native layout tests render the actual SwiftUI/AppKit tree with synthetic fixture data at 1280 × 800 and 820 × 640 in both appearances, including command completion and the welcome state. These are layout evidence, not provider output or full accessibility certification. Core, native input, hover, draft, session-cancellation and large-history tests pass. The original Pi smoke test makes no model request.

The build artifact is `build/Pi Desktop.app`. Packaging uses local ad hoc signing and is not notarized. Original CLI access covers Pi's interactive commands and extension TUI limitations.
