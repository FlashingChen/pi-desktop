# Pi Desktop

## Platform

Native macOS desktop application.

## Stack

Confirmed: SwiftUI + AppKit. Spawn the installed, unmodified Pi CLI through its official RPC protocol. Embed an original Pi interactive terminal for commands and extension TUI not supported in RPC mode.

## Users

Pi users who want to work across local projects and native Pi sessions from a standalone Mac application.

## Product Purpose

A pure GUI shell that improves presentation and interaction without changing Pi agent behavior.

## Capabilities and Constraints

- Projects contain sessions. Project records contain folder references only.
- GUI and CLI continue the same native Pi session files; no independent session database.
- Preserve Pi models, tools, Skills, Extensions, configuration, commands, and session capabilities.
- Do not modify, replace, or reimplement Pi Agent.
- Do not add permission workflows, Plan Mode, subagents, or other non-Pi functionality.
- Launch independently from Dock, Finder, and Spotlight.
- Installed Pi observed during discovery: 1.4.0. Its local official docs are the integration reference.
- RPC has documented TUI limitations; original interactive Pi is required for complete access.

## Brand Commitments

Confirmed reference: Claude Desktop's Claude Code interface. Modern, refined, minimal, native macOS appearance.

## Workflow

The native implementation uses a graphite canvas, project tabs, an optional session sidebar and a restrained blue-gray accent. Previous floating-card and clay-palette directions are retired; do not reintroduce them.

Design and interaction details live in [DESIGN.md](DESIGN.md).

## Product Principles

- Pi owns all agent behavior and conversation state.
- GUI metadata never becomes a competing session system.
- Native desktop interaction with no prerequisite terminal window.
- Expose real capabilities and honest integration limits.
