# Implementation Plan: Open Recent

**Branch**: `001-open-recent` | **Date**: 2026-01-22 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-open-recent/spec.md`

## Summary

Add "Open Recent" functionality to SoftBurn that displays the 5 most recently opened slideshows in the File menu and both toolbar variants (legacy and LiquidGlass). The feature persists the recent list across app restarts using UserDefaults, handles missing files gracefully, and includes a "Clear List" action.

## Technical Context

**Language/Version**: Swift 5.9+ with strict concurrency (Swift 6 compatible)
**Primary Dependencies**: SwiftUI, AppKit, Foundation (all built-in macOS frameworks)
**Storage**: UserDefaults via @AppStorage with JSON-encoded array
**Testing**: XCTest (existing project pattern)
**Target Platform**: macOS 13+ (with LiquidGlass enhancements on macOS 26+)
**Project Type**: Single macOS desktop application
**Performance Goals**: Menu renders instantly; recent list persists reliably
**Constraints**: Maximum 5 items; @MainActor concurrency model; sandboxed file access
**Scale/Scope**: Single-user desktop app with up to 5 recent slideshow entries

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Status**: PASS (N/A - Constitution not configured for this project)

The project's constitution file (`/.specify/memory/constitution.md`) contains template placeholders and has not been configured with project-specific principles. No gate violations can occur.

**Post-Phase 1 Re-check**: PASS (no constraints violated)

## Project Structure

### Documentation (this feature)

```text
specs/001-open-recent/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
SoftBurn/
├── App/
│   └── SoftBurnApp.swift           # UPDATE: Add Open Recent menu to CommandGroup
├── State/
│   ├── SlideshowSettings.swift     # REFERENCE: Pattern for @AppStorage persistence
│   ├── SlideshowState.swift        # REFERENCE: Observable state pattern
│   └── RecentSlideshowsManager.swift  # NEW: Manage recent slideshows list
├── Models/
│   └── RecentSlideshow.swift       # NEW: Data model for recent entry
└── Views/
    └── Main/
        └── ContentView.swift       # UPDATE: Add toolbar submenu + handlers
```

**Structure Decision**: Single macOS app following existing feature-based folder structure. New state manager follows `SlideshowSettings.swift` pattern for @AppStorage persistence.

## Complexity Tracking

> No complexity violations - design follows existing patterns.
