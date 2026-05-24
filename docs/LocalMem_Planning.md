# LocalMem - Build Planning Document

## Purpose
This document defines how LocalMem should be built from the bottom up.

The goal is to validate the core utility of LocalMem with real agents before investing heavily in a polished macOS application shell.

## Planning Principle
Build the trusted memory and retrieval engine first.

Then prove that agents can use it well through MCP and CLI.

Then build the desktop app that makes it understandable and usable for normal users.

## Why This Order
LocalMem only matters if the core loop works:
- store memory
- retrieve relevant context
- scope access correctly
- let agents use it effectively
- show what was accessed

If this loop is weak, a polished app will not fix the product.

If this loop is strong, the app becomes a trust and usability layer on top of something already valuable.

## Build Strategy

### Phase 1 - Core Engine
Build the local engine first.

Responsibilities:
- memory CRUD
- source registration
- local indexing
- retrieval
- permissions model
- access logging
- export and import foundations

Primary outputs:
- local database schema
- retrieval service
- policy checks for agent access
- durable event logging

### Phase 2 - CLI
Build a simple CLI on top of the core engine.

Why:
- fastest way to test behavior
- easy for pro users
- useful for debugging
- supports automation and scripting

Initial commands:
- `localmem add-memory`
- `localmem search`
- `localmem recent`
- `localmem delete-memory`
- `localmem add-source`
- `localmem list-sources`
- `localmem activity`

CLI success criteria:
- a user can add memories and sources without UI
- a user can inspect search results and recent activity
- the CLI output is clear enough for agent and human testing

### Phase 3 - MCP Server
Build the MCP server after the core and CLI are stable enough.

Why:
- this is the first real proof that LocalMem works with agents
- the MCP surface should be shaped by the core model, not by UI assumptions

Initial MCP tools:
- `memory_store`
- `memory_search`
- `memory_recent`
- `memory_delete`

Behavior rules:
- every MCP call must be attributed to an agent/client
- every retrieval must respect source permissions
- every read and write must be logged
- `memory_recent` is the V1 listing mechanism

### Phase 4 - Agent Validation
Use real agents against the MCP server before building the full app.

Initial targets:
- Claude Desktop
- Codex
- later Hermes / OpenClaw

Questions to answer:
- do agents actually use the tools well
- are results relevant enough
- is the MCP contract sufficient
- should memory and source retrieval remain separate
- what access history is most useful to show

This phase is critical because it validates the actual LocalMem loop with real usage.

### Phase 5 - macOS App
After the engine and MCP loop feel strong, build the macOS app.

The app should not invent a second system.
It should expose and manage the core system already proven through CLI and MCP.

Main UI areas:
- Home
- Sources
- Memory
- Agents
- Activity
- Settings

Main user actions:
- add folder or document
- add memory
- grant agent access
- inspect recent activity
- pause sharing

### Phase 6 - Polishing and Distribution
After the app is usable:
- improve onboarding
- sign and notarize builds
- prepare direct download distribution
- refine icon and branding
- review App Store feasibility later

## Technical Architecture Direction

### Recommended Initial Stack
Start with a native macOS-first stack that can support both the app and the core local engine.

Recommended direction:
- Swift for app and core implementation
- SQLite as the main store
- FTS5 for search
- MCP server layered on top of the core engine
- CLI sharing the same core services as the app and server

### Important Rule
The app, CLI, and MCP server should all sit on top of the same LocalMem core.

This avoids:
- duplicate logic
- different retrieval behavior by surface
- inconsistent permissions
- mismatched audit history

## Data Model Foundations
The first implementation should center on a few durable concepts:

- `Source`
  A folder, file, or manually entered source of context

- `Memory`
  A durable structured memory entry

- `Agent`
  A connected MCP client or other caller

- `PermissionGrant`
  Which agent can access which source and whether it can write memory

- `AccessEvent`
  A log of reads, searches, writes, deletes, and other actions

This model should stay stable even as the UI evolves.

## What Not To Build First
Do not start with:
- CloudKit sync
- iPhone app
- Windows app
- shared memories
- QR pairing
- semantic retrieval systems
- vector databases
- App Store constraints
- broad connector ecosystem support

These may become important later, but they should not block validating the core engine.

## V1 Validation Goals
The first serious milestone is not a beautiful app.
It is proving that LocalMem is useful when connected to real agents.

We should be able to answer:
- can LocalMem store and retrieve useful memory
- can it scope access correctly
- can an agent use it without awkward prompting
- can a user understand what happened afterward

## Milestone Plan

### Milestone 1 - Core Storage and Search
- define schema
- implement memory CRUD
- implement source registration
- implement local search
- implement access event logging

### Milestone 2 - CLI
- wire core functions into CLI
- support source and memory operations
- support search and recent activity inspection

### Milestone 3 - MCP
- expose the first four MCP tools
- add client attribution
- enforce permissions
- log read and write behavior

### Milestone 4 - Real Agent Testing
- connect Claude Desktop
- test common retrieval and store flows
- refine tool contracts

### Milestone 5 - macOS App Shell
- basic app navigation
- sources and memory management
- activity feed
- agent permission screens

### Milestone 6 - Product Polish
- onboarding
- icon
- menu bar app
- signed builds

## Success Criteria

### Technical
- one core engine powers CLI, MCP, and app
- retrieval is useful enough for real agent sessions
- audit logging is clear and accurate
- permissions are enforced consistently

### Product
- users feel safer than broad cloud connectors
- users understand what was read by which agent
- users can share only selected sources
- LocalMem feels like a control layer, not hidden infrastructure

## Long-Term Extensions
Future work can include:
- export and import bundles
- Windows support
- Apple ecosystem sync where appropriate
- trusted device pairing by code or QR
- explicit shared memory spaces

These should be built on top of a strong and proven core, not before it.
