---
name: PrivacyPods
description: A dark menu bar app whose one real visual is the blurred, covered screen.
colors:
  true-black: "#000000"
  white: "#FFFFFF"
  hairline: "rgba(255, 255, 255, 0.14)"
  attention-orange: "#FF9F0A"
  night-glass: "#0F0F0F"
  glass-scrim: "rgba(15, 15, 15, 0.35)"
  glass-scrim-notice: "rgba(15, 15, 15, 0.6)"
  soft-white: "rgba(255, 255, 255, 0.72)"
typography:
  headline:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    fontFeature: "tnum"
  callout:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 400
  overlay-notice:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 600
  store-display:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "64px"
    fontWeight: 700
    lineHeight: 1.04
    letterSpacing: "-0.03em"
  store-body:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 400
    lineHeight: 1.38
  store-wordmark:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "22px"
    fontWeight: 600
    letterSpacing: "-0.01em"
rounded:
  icon-squircle: "22.4%"
  store-screen: "22px"
  store-window: "14px"
spacing:
  title-gap: "4px"
  row-y: "7px"
  notice-gap: "8px"
  row-x: "12px"
  pane-top: "12px"
  pane-x: "20px"
  section-gap: "24px"
  row-min-height: "30px"
components:
  pane:
    backgroundColor: "{colors.true-black}"
    textColor: "{colors.white}"
    padding: "12px 20px 20px"
  pane-section-title:
    textColor: "{colors.white}"
    typography: "{typography.title}"
  pane-row:
    textColor: "{colors.white}"
    typography: "{typography.body}"
    padding: "7px 0"
    height: "30px"
  pane-notice:
    textColor: "{colors.attention-orange}"
    typography: "{typography.callout}"
    padding: "7px 0"
  status-headline:
    textColor: "{colors.white}"
    typography: "{typography.headline}"
  overlay-sheet:
    backgroundColor: "{colors.night-glass}"
    textColor: "{colors.white}"
    typography: "{typography.overlay-notice}"
---

# Design System: PrivacyPods

## Overview

**Creative North Star: "Frosted Glass at Night"**

The product's one real visual is the covered screen: a live capture, blurred until it can't be read, with a thin dark scrim over it. Everything else is the night around that glass. Windows are true black with white text and the title bar merges into the content, so the chrome steps back and only the facts are left. Nothing competes with the blur for attention, and nothing is drawn that the blur itself doesn't need.

The interface is dense and terse in the macOS manner: one fact per row, label on the left and value on the right, with hairlines between rows instead of cards. Controls are stock AppKit and SwiftUI, native and invisible. The brand comes through in three things only: the black, the eye glyph in the menu bar, and the copy. Color is close to absent. One orange marks things that need fixing, and it never appears for any other reason.

The store images use the same world at poster scale. They show a black field with one soft light behind the product, big tight SF Pro Display headlines, and real renders of the app on a fake Mac.

**Key Characteristics:**
- True black windows with the title bar merged in; white text throughout.
- Hairline-separated rows, never cards, grouped fills or section backgrounds.
- One accent (Attention Orange), only for things to fix, always paired with an icon or a count.
- The covered screen is a captured frame plus a flat scrim, never live vibrancy.
- SF Symbols eye family as the identity; dimming means the user chose that state.
- Windows size to their content: no scroll views, nothing below the fold.

## Colors

The palette is black and white, plus a near-black for covered screens and one signal color.

### Primary
- **Attention Orange** (system orange, dark appearance): The only accent. It marks a thing to fix: a counted permission row, a failed lock time, the "N things to fix below" line, and warning notices. It always comes with an `exclamationmark.triangle.fill` icon or a count in the headline, so the color is never the only cue. Uses `Color.orange` / `NSColor.systemOrange` so it follows Increase Contrast.

### Neutral
- **True Black**: Background of every window (Status, Settings) and of the title bar that merges into it. It is also the store-image field.
- **White**: All text, labels, values and section titles. Rows don't fade their values to gray; a view that needs one value quieter or louder colors it explicitly.
- **Hairline** (white at 14%): The 1px rule under every section title and every row. It is the only divider in the system.
- **Night Glass**: The opaque fill of a covered display, shown when there is no captured frame (no Screen Recording, or a failed stream). Deliberately not pure black.
- **Glass Scrim** (Night Glass at 35%): The flat tint over a blurred capture.
- **Glass Scrim, Notice** (Night Glass at 60%): The darker tint used when a display carries a notice line, so the white text can be read over a pale blurred frame. Darker also means more opaque, so it only ever hides more.
- **Soft White** (white at 72%): Store-image body copy only. The app itself doesn't use it.

### Named Rules
**The One Signal Rule.** Attention Orange means "something here needs fixing" and nothing else. Never use it for emphasis, branding, selection or decoration, and never let it carry meaning without an icon or a count beside it.

**The Not Dead Black Rule.** A covered display is Night Glass, never pure #000. A pure black display looks broken, and often the covered display is the only thing the user can see.

## Typography

**Display Font:** SF Pro Display (system), store images and the overlay notice only
**Body Font:** SF Pro Text (system font at macOS sizes)

**Character:** It is the system font at the system's own small sizes, so the app reads like part of macOS. Size jumps are few and weight does most of the work. In the store images the same family turns bold and tightly tracked for posters.

### Hierarchy
- **Headline** (semibold, 17px): The Status window's first line, which says what the app is doing right now ("Looking at Built-in Retina Display"). Marked as a header for VoiceOver.
- **Title** (semibold, 13px): Section titles in Settings and Status (Blur, Lock, Permissions), with the hairline directly under them.
- **Body** (regular, 13px, tabular digits): Row labels and values. Values use monospaced digits so times and percentages don't jitter.
- **Callout** (regular, 12px): Notices and explanatory lines under a setting.
- **Caption** (regular, 10px): Permission rationale under a permission title, shown only when there is something to decide.
- **Overlay notice** (semibold, 17px, centered, max 80% of the display width): The one line on a covered display that says why it is blind, with a soft black text shadow instead of a backing plate.
- **Store display** (bold, 64px, line height 1.04, tracking -0.03em; 56px on stacked slides): Store headlines like "Look away. Your screen blurs."
- **Store body** (regular, 24px, line height 1.38, Soft White): One or two plain sentences under the headline.

### Named Rules
**The System Size Rule.** In the app, use the system text sizes and weights. Don't add a brand face, and don't add sizes between the ones above.

## Layout

The app has three surfaces: the menu bar item and its menu, the Status window (520pt wide) and the Settings window (480pt wide). Windows are fixed-width panes that take their height from their content (`sizingOptions = .preferredContentSize`). A notice row appearing or going resizes the window instead of scrolling it.

A pane has 20px of horizontal padding, 12px at the top and 20px at the bottom, with 24px between sections. A section is its title, 4px of space, a hairline, then its rows. A row is the label on the left, filling the width, then the value or control on the right, 12px apart, with 7px of vertical padding, at least 30px tall, and a hairline under it. Explanations and button rows that follow a row sit 8px below it, with buttons pushed to the trailing edge.

The overlay covers each display edge to edge, one window per display, with any notice centered.

Store slides are 1440×900 rendered at 2x. They use 96px side padding, a 470px copy column and a 72px gap to the visual. Stacked slides put the visual below the copy.

### Named Rules
**The Nothing Below the Fold Rule.** Windows have no scroll view. If content doesn't fit, cut it or move it; don't add scrolling.

## Elevation & Depth

The app is flat. Windows, sections and rows have no shadows, fills or layers; hierarchy comes from type weight and hairlines. The system's own window shadow is the only elevation in the app chrome.

Depth belongs to the overlay, which is a stack of literal layers: Night Glass at the bottom, the blurred capture (Gaussian, 70pt by default, clamped at the edges so no dark frame bleeds in), a flat scrim, and an optional notice line. A covered display fades in and out over 150ms with ease-out, and instantly when Reduce Motion is on.

The store images add one structural shadow under the fake screen and windows, plus one soft radial light behind the product.

### Named Rules
**The Glass Never Leaks Rule.** A covered screen is a captured frame, blurred, under a flat scrim. Never use `NSGlassEffectView`, vibrancy or any live backdrop material on the overlay, because those refract whatever is behind the window. Without a capture, show opaque Night Glass with one line saying why, never the live screen.

**The One Glow Rule.** A store image gets one soft white radial light behind the product (10% white, fading out by 70%). It gets no other decorative light, gradient or texture. The colored wallpaper inside the fake screen is content being blurred, not decoration.

## Shapes

The app adds no shapes of its own. Corners come from macOS: window corners, push buttons, switches and menus are all system-drawn. Rows and sections are square, open strips separated by hairlines.

The app icon is a black squircle (corner radius 22.4% of its inset square) with an `eye.fill` that is half sharp, half blurred, drawn from SF Symbols by `scripts/icon/render.swift`. Store mock screens have a 22px radius with a 10px dark bezel, and window renders sit at 14px.

## Components

All controls are native and invisible: stock AppKit and SwiftUI with no custom styling. The brand never comes from restyling a control.

### Buttons
- **Shape:** System push button (macOS rounded rect), regular size.
- **Style:** Default dark-appearance push button. Titles name the action exactly: "Lock Now to Test", "Allow…", "Open System Settings…", "Try Again", "Dismiss". An ellipsis means the button opens something else.
- **Placement:** Inline at the end of a row when it fixes that row; otherwise trailing in an 8px-gap row under the explanation.

### Rows (`LabeledContent` with the pane row style)
- **Style:** Label on the left, value or control on the right, hairline under, values in tabular digits. Using `LabeledContent` keeps the label tied to its control for VoiceOver.
- **State:** A value turns Attention Orange only when the headline counts it as a thing to fix.

### Notices
- **Warning:** `exclamationmark.triangle.fill` plus one callout-size line, both Attention Orange, 7px vertical padding. Only for things the headline counts. If there is a fix, its button goes on the trailing side of the same line.
- **Info:** `info.circle` plus one callout-size line, both white. For something worth saying that is not counted as a thing to fix, like a display that overlaps the one you are looking at, or one with no anchor yet. Same layout and trailing button as a warning.

### Lead Lines
- **Style:** one callout-size sentence directly under a section title, laid out as a row with a hairline under it, saying what the rows below are about (Settings > Tracking explains anchors). At most one per section.

### Setup Steps
- **Style:** a "Steps" section in the Status window, shown only until first-run setup is finished. Each step is a row: a tabular-digit number in an 18px column, the step in body text, one caption line saying how or why, and its state or control on the right.
- **Order:** each step waits for the one before it, disabled with "Available once your AirPods are connected." The choice with no default is a segmented control with neither segment selected.

### Toggles and Pickers
- **Toggle:** System switch, label hidden (the row label is the label).
- **Picker:** System pop-up, label hidden. Presets are written the way people say them ("±30°", "After 2 minutes").
- **Slider:** System slider, 140px wide, with its value shown as a percentage.

### Menu Bar Item
- **Style:** A template SF Symbol from the eye family. `eye` means protecting, `eye.slash` means the screen is blurred, `eye.half.closed` means it can't see you yet, and `eye.trianglebadge.exclamationmark` means it needs attention. Dimmed `pause.circle` means paused, and dimmed `eye.slash.circle` means blur and lock are both off.
- **Menu:** The status line at the top in semibold menu font, with what it costs the screens and the next step in regular menu font under it, wrapped at 260px, never in a tooltip. Then setup steps and fixes, then actions, then windows (with PrivacyPods Help after About), then Quit.

### Overlay Sheet (signature component)
Night Glass fill, the blurred capture, the scrim, and an optional centered notice line (17px semibold white, black text shadow at 80% with a 6px blur, wrapping at 80% of the display width). The notice is announced to VoiceOver once per change of wording. It is never interactive and never takes focus.

## Do's and Don'ts

### Do:
- **Do** set every window to True Black with the title bar transparent and dark-appearance, so the title bar merges into the content.
- **Do** separate sections and rows with the white-at-14% hairline, and nothing else.
- **Do** pair every Attention Orange element with `exclamationmark.triangle.fill` or a count in the headline.
- **Do** use a white `info.circle` notice for anything worth a line that the headline does not count.
- **Do** split a status into its title and its effect ("Screens readable.") rather than adding the effect to the title in brackets.
- **Do** keep each issue in one place, in its own section next to the button that fixes it; the headline only counts them.
- **Do** use the system font at system sizes, with tabular digits for any value that changes.
- **Do** dim the menu bar icon only for states the user chose (paused, everything off).
- **Do** respect Reduce Motion: the 150ms overlay fade becomes instant.

### Don't:
- **Don't** use grouped `Form` sections, cards, rounded fills or section backgrounds. They break the black.
- **Don't** use Attention Orange, or any other color, for emphasis, selection or decoration.
- **Don't** put `NSGlassEffectView`, vibrancy or a live material on the overlay.
- **Don't** make a covered display pure black, and never show the live screen when capture is unavailable.
- **Don't** restyle native buttons, switches, pickers or menus.
- **Don't** add scroll views to the Status or Settings windows.
- **Don't** add decorative light, gradients or texture to store images beyond the one radial glow.
