# SnapMark

A tiny macOS menu-bar screenshot app with annotation built in. Press **Ctrl+Shift+5**
anywhere, drag a region, then annotate: arrows, lines, rectangles, ellipses, text,
pen, highlighter, blur-to-redact, and crop. Copy to clipboard or save a PNG.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`) — provides the Swift compiler

## Build & install

```bash
./build.sh
```

This compiles the app and creates `dist/SnapMark.app` (ad-hoc signed).
Drag it to `/Applications`, then launch it. SnapMark lives in the menu bar —
there's no dock icon.

> For "Launch at login" to work reliably, keep SnapMark in `/Applications`.

## Permissions

On first capture, macOS asks for **Screen Recording** permission — every screenshot
tool needs this. Allow it in **System Settings → Privacy & Security →
Screen Recording**, then press Ctrl+Shift+5 again.

No Accessibility permission is needed: the global hotkey uses the classic Carbon
hotkey API, which requires no extra permissions.

## Usage

- **Ctrl+Shift+5** — capture a region (native crosshair UI; Esc cancels)
- Annotate with the floating toolbar: arrow, line, rectangle, ellipse, text, pen,
  highlighter, **counter badges** (numbered steps), eraser, **color picker**
  (eyedropper — click the screenshot to use any color), blur, **spotlight**
  (dims everything except a region), crop
- Toggle **fill** for solid rectangles/ellipses
- **Sketch style** — hand-drawn, pen-like wobble on shapes and arrows, marker font on text
- **⌘C** copy PNG to clipboard · **⌘S** save PNG · **⌘Z / ⇧⌘Z** undo / redo ·
  **Esc** close the editor
- Blur permanently pixellates that part of the image — good for redacting API
  keys, names, addresses, etc.
- Crop clears annotations (undo restores everything, including the crop)
- **Pin to screen** — float the screenshot above all windows; drag to move,
  drag edges to resize, hover for the close button; close them all from the
  menu bar
- Every capture records **metadata**: date/time, macOS user, and the frontmost
  app at capture time — shown in the editor and embedded in saved PNGs
  (title/author/description/creation-time)
- **URL imprint** — capture from Safari, Chrome, Edge, Brave, Arc, Opera or
  Vivaldi and the page URL is stamped onto a caption bar on saved, copied and
  pinned images (toggle in Settings); first use triggers the macOS Automation
  permission prompt, which you must allow

## Notes & limitations

- When built with the macOS 26+ SDK, the floating toolbar and actions render as
  Liquid Glass pills; on older SDKs / macOS they fall back to a frosted material.
  Either way the app still runs on macOS 13+.

- The hotkey is fixed to Ctrl+Shift+5 in `Sources/SnapMark/HotKeyManager.swift`
  (change `kVK_ANSI_5` / the modifiers and rebuild to customize).
- Capture itself is done with the system `screencapture` tool, so quality and the
  selection UI match macOS exactly.
- v1 has no scrolling capture or cloud upload — those are the natural next
  features if you want them.
