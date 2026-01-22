<!--
SYNC IMPACT REPORT
==================
Version change: N/A → 1.0.0 (Initial adoption)

Modified principles: None (initial version)
Added sections:
  - Core Principles (5 principles)
  - Architecture Constraints section
  - Development Workflow section
  - Governance section

Templates status:
  ✅ plan-template.md - Compatible (has Constitution Check section)
  ✅ spec-template.md - Compatible (user stories structure aligns)
  ✅ tasks-template.md - Compatible (phase-based task organization aligns)

Follow-up TODOs: None
-->

# SoftBurn Constitution

## Core Principles

### I. Swift Concurrency Discipline

All state management MUST follow strict actor isolation:
- **@MainActor** for all UI state (views, observable objects, user-facing state)
- **Background actors** for heavy operations (face detection, thumbnail generation, caching)
- **Sendable types** for all data crossing actor boundaries (MediaItem, SlideshowDocument)

Rationale: Swift 6 concurrency compliance ensures data race safety and predictable threading behavior. Violating this leads to runtime crashes in strict mode.

### II. Metal-Unified Rendering

All slideshow rendering MUST use the unified Metal pipeline:
- No dual rendering paths (SwiftUI path deprecated)
- Two-pass architecture: scene composition → optional patina post-processing
- Video player pooling to prevent hardware decoder exhaustion

Rationale: Unified pipeline eliminates code duplication, ensures consistent visual output, and enables GPU-accelerated effects for all media types.

### III. Zero External Dependencies

The project MUST use only built-in Apple frameworks:
- SwiftUI, AppKit, Metal, Vision, AVFoundation are approved
- No SPM packages, CocoaPods, or Carthage dependencies permitted
- All functionality built on native macOS APIs

Rationale: Reduces maintenance burden, eliminates supply chain vulnerabilities, and ensures long-term compatibility with macOS updates.

### IV. Non-Destructive Editing

User modifications MUST be stored as metadata, never applied destructively:
- Rotation stored as 0/90/180/270° metadata, not file modification
- Face detection cached in `.softburn` files, not baked into images
- All transformations reversible without source file access

Rationale: Preserves original media integrity and enables undo/redo without file system operations.

### V. Spec-First Development

New features MUST have specifications in `/specs` before implementation:
- Feature specs define requirements and success criteria
- Implementation plans reference specs
- Changes to existing features require spec amendments

Rationale: Prevents scope creep, ensures stakeholder alignment, and creates documentation as a natural byproduct.

## Architecture Constraints

### Layered Architecture

The codebase follows a strict layered architecture with dependencies flowing downward:

```
UI Layer (SwiftUI)
    ↓ depends on
State Management Layer (@MainActor observables)
    ↓ depends on
Rendering & Effects Layer (Metal pipeline)
    ↓ depends on
Services Layer (background actors)
    ↓ depends on
Data & Persistence Layer (models, documents)
```

- Upper layers MAY depend on lower layers
- Lower layers MUST NOT depend on upper layers
- Cross-layer dependencies MUST go through defined interfaces

### File Organization

Feature-based folder structure MUST be maintained:
- `App/` - Entry point and lifecycle only
- `Models/` - Pure data types (Codable, Sendable)
- `State/` - Observable state management
- `Views/` - UI components organized by feature
- `Rendering/` - Metal pipeline and shaders
- Root files (`Info.plist`, `*.entitlements`, `Assets.xcassets`) MUST NOT be moved

### Performance Boundaries

- Face detection: Maximum 3 concurrent operations
- Main thread: MUST NOT block during import/export
- Thumbnail generation: Lazy, on-demand only
- Video metadata: Cached to avoid repeated AVAsset introspection

## Development Workflow

### Adding Features

1. Create specification in `/specs/[feature-name]/spec.md`
2. Get spec approval before implementation
3. Create implementation plan referencing spec
4. Follow phased task execution (setup → foundational → user stories)
5. Test on multiple macOS versions if changing UI

### Adding Effects

- **Color effects** (monochrome, sepia, silvertone): Add shader logic to `SlideshowShaders.metal`
- **Patina effects** (film simulation): Add shader functions to `PatinaShaders.metal`, update `SlideshowSettings`
- Use `EffectTuningView` debug window for live parameter adjustment

### Modifying Metal Pipeline

Changes to `MetalSlideshowRenderer.swift` or shader files MUST:
- Preserve two-pass architecture
- Support both photo and video inputs
- Handle rotation metadata correctly
- Maintain 60fps target on supported hardware

## Governance

This constitution supersedes conflicting practices elsewhere in the codebase. All code reviews MUST verify compliance with these principles.

### Amendment Procedure

1. Propose amendment with rationale
2. Document in constitution with version increment
3. Update dependent templates if affected
4. Update CLAUDE.md if architectural guidance changes

### Versioning Policy

- **MAJOR**: Principle removal or incompatible redefinition
- **MINOR**: New principle or section added
- **PATCH**: Clarifications, wording fixes

### Compliance Review

New features and significant changes MUST pass Constitution Check before implementation (see plan-template.md).

**Version**: 1.0.0 | **Ratified**: 2026-01-21 | **Last Amended**: 2026-01-21
