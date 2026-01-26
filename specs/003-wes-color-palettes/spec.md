# Feature Specification: Wes Color Palettes

**Feature Branch**: `003-wes-color-palettes`
**Created**: 2026-01-26
**Status**: Draft
**Input**: User description: "Wes Color Palettes - Add three cinematic color grading presets (Budapest Rose, Fantastic Mr Yellow, Darjeeling Mint) with 5-color palette-based grading, skin tone preservation, and matching background swatches"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Apply Cinematic Color Palette (Priority: P1)

A user wants to give their slideshow a distinctive cinematic look inspired by Wes Anderson's visual style. They select one of the three color palettes from the Color menu to transform their photos with a cohesive color grade.

**Why this priority**: Core feature value - applying the color palettes is the primary user action this feature enables.

**Independent Test**: Can be fully tested by selecting any palette from the Color menu and verifying photos display with the expected color grading characteristics.

**Acceptance Scenarios**:

1. **Given** a slideshow with photos loaded, **When** user selects "Budapest Rose" from the Color menu, **Then** the slideshow renders with warm pastel tones, rose-pulled midtones, and purple-cooled shadows
2. **Given** a slideshow with photos loaded, **When** user selects "Fantastic Mr Yellow" from the Color menu, **Then** the slideshow renders with warm autumnal tones, yellow-dominant midtones, and fox-red accent bias
3. **Given** a slideshow with photos loaded, **When** user selects "Darjeeling Mint" from the Color menu, **Then** the slideshow renders with cool-leaning tones, mint-green pulls, and preserved warm accents
4. **Given** a slideshow with any Wes palette applied, **When** viewing photos containing people, **Then** skin tones appear natural and are not shifted toward the palette's dominant color

---

### User Story 2 - Combine Palette with Matching Background (Priority: P2)

A user wants to enhance the cinematic aesthetic by pairing their chosen color palette with a complementary background color that matches the palette's design intent.

**Why this priority**: Enhances the visual cohesion of the feature but is optional - palettes work independently of background choice.

**Independent Test**: Can be fully tested by selecting a matching background swatch and verifying it displays correctly during slideshow transitions.

**Acceptance Scenarios**:

1. **Given** "Budapest Rose" palette is applied, **When** user selects the Warm Cream background swatch (RGB 221,214,144), **Then** the background displays that exact color during transitions
2. **Given** "Fantastic Mr Yellow" palette is applied, **When** user selects the Paper Cream background swatch (RGB 242,223,208), **Then** the background displays that exact color during transitions
3. **Given** "Darjeeling Mint" palette is applied, **When** user selects the Dusty Gold background swatch (RGB 209,156,47), **Then** the background displays that exact color during transitions

---

### User Story 3 - Switch Between Palettes and Other Color Effects (Priority: P3)

A user experimenting with different looks switches between Wes palettes and existing color effects (Monochrome, Silvertone, Sepia) to compare results.

**Why this priority**: Supports user exploration but is a standard menu interaction pattern already established in the app.

**Independent Test**: Can be fully tested by cycling through all color options and verifying each applies correctly without artifacts from previous selection.

**Acceptance Scenarios**:

1. **Given** "Budapest Rose" is applied, **When** user switches to "Fantastic Mr Yellow", **Then** the new palette applies immediately with no visual remnants of the previous palette
2. **Given** any Wes palette is applied, **When** user switches to "Monochrome", **Then** the standard monochrome effect applies cleanly
3. **Given** "Sepia" effect is applied, **When** user switches to "Darjeeling Mint", **Then** the palette applies correctly without sepia color contamination

---

### Edge Cases

- What happens when palette is applied to already-desaturated or very low-saturation source images?
  - Palette should still apply its characteristic tonal shifts without producing muddy or undefined colors
- How does the system handle photos that are primarily one color (e.g., sunset photos already orange)?
  - Palette grading should enhance rather than fight the existing dominant color
- What happens when combining a Wes palette with patina effects (35mm, Aged Film, VHS)?
  - Both effects should stack: palette grading applies first (scene pass), then patina effects apply (post-processing pass)

## Requirements *(mandatory)*

### Functional Requirements

#### Color Palette Application

- **FR-001**: System MUST provide three new color effect options in the Color menu: "Budapest Rose", "Fantastic Mr Yellow", and "Darjeeling Mint"
- **FR-002**: System MUST append these options after existing color effects (None, Monochrome, Silvertone, Sepia) without grouping or separation
- **FR-003**: Each palette MUST apply color grading based on exactly 5 anchor colors as specified below
- **FR-004**: System MUST preserve natural skin tones when applying any palette

#### Budapest Rose Palette Behavior

- **FR-005**: System MUST pull midtones toward Dominant Rose (RGB 255,216,236)
- **FR-006**: System MUST bias existing reds toward Accent Red (RGB 229,0,12)
- **FR-007**: System MUST cool shadows toward Royal Purple (RGB 120,66,131)
- **FR-008**: System MUST reduce overall saturation to approximately 75% (pastel range)
- **FR-009**: System MUST soften contrast by approximately 10%

#### Fantastic Mr Yellow Palette Behavior

- **FR-010**: System MUST pull yellows toward Dominant Yellow (RGB 255,201,7)
- **FR-011**: System MUST bias reds toward Fox Red (RGB 198,32,39)
- **FR-012**: System MUST warm browns toward Autumn Brown (RGB 195,112,33)
- **FR-013**: System MUST de-emphasize greens slightly (avoid modern neon appearance)
- **FR-014**: System MUST maintain moderate contrast (preserve texture in fur/foliage)

#### Darjeeling Mint Palette Behavior

- **FR-015**: System MUST pull greens and cyans toward Dominant Mint (RGB 73,153,124)
- **FR-016**: System MUST nudge blues toward Railway Blue (RGB 2,122,176)
- **FR-017**: System MUST preserve warm accents toward Spice Red (RGB 174,57,24)
- **FR-018**: System MUST cool highlights slightly and warm shadows gently
- **FR-019**: System MUST apply a mild S-curve contrast adjustment

#### Background Swatches

- **FR-020**: System MUST add three new background color swatches to the Background menu
- **FR-021**: Budapest Rose background swatch MUST be RGB(221,214,144)
- **FR-022**: Fantastic Mr Yellow background swatch MUST be RGB(242,223,208)
- **FR-023**: Darjeeling Mint background swatch MUST be RGB(209,156,47)
- **FR-024**: Background swatches MUST NOT auto-link with color palette selection (independent choices)

#### Grading Behavior (All Palettes)

- **FR-025**: System MUST bias highlights toward lighter palette colors
- **FR-026**: System MUST bias midtones toward the dominant (first) palette color
- **FR-027**: System MUST bias shadows toward deeper palette colors
- **FR-028**: System MUST NOT perform object segmentation or recoloring - grading only
- **FR-029**: System MUST apply palette effects in the scene composition pass (before patina post-processing)

### Key Entities

- **Color Palette**: A named collection of 5 anchor colors with defined roles (dominant, secondary, accents, background) and associated color behavior rules (saturation, contrast, tonal biases)
- **Background Swatch**: A solid color option (RGB value) available in the Background menu for display during slideshow transitions

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can apply any of the three color palettes with a single menu selection
- **SC-002**: Color grading visually matches the characteristic look of each palette's reference aesthetic (warm/pastel for Budapest Rose, autumnal/storybook for Fantastic Mr Yellow, cool/composed for Darjeeling Mint)
- **SC-003**: Skin tones in photos remain recognizably natural after palette application (not tinted to dominant color)
- **SC-004**: Palette switching is instantaneous with no visual artifacts from previous selection
- **SC-005**: All three matching background swatches are accessible in the Background menu
- **SC-006**: Palettes render correctly in combination with all existing patina effects (35mm, Aged Film, VHS)
- **SC-007**: Palette effects apply consistently to both photos and video frames

## Assumptions

- The existing Color menu infrastructure supports adding new effect options without structural changes
- The Metal shader pipeline can accommodate additional color grading logic in the scene composition pass
- The existing background color picker can accept additional predefined swatch options
- Skin tone preservation can be achieved through luminance-based masking or hue-range exclusion in the grading algorithm
- The color grading approach will use selective color pulls and bias adjustments rather than LUT-based transformations

## Out of Scope

- Automatic palette-background pairing (users choose independently)
- Custom user-defined color palettes
- Per-photo palette overrides
- Palette intensity/strength slider
- Additional Wes Anderson-inspired palettes beyond the three specified
