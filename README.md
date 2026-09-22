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

This runs the **dev checks**, compiles the app, and creates
`dist/SnapMark.app` (ad-hoc signed). Drag it to `/Applications`, then launch
it. SnapMark lives in the menu bar — there's no dock icon.

> For "Launch at login" to work reliably, keep SnapMark in `/Applications`.

### Dev checks & logs

Every build runs three checks automatically:

1. **Static audit** (`tools/audit.py`) — verifies Apple-Intelligence/Translation
   code is properly availability-guarded, `#if/#endif` and brackets balance,
   and flags risky `try!`/`fatalError` calls. No SDK needed.
2. **`swift build`** — full compile.
3. **`swift test`** — unit tests for the PII redaction logic (Luhn, email/phone/
   card/API-key/name detection), Drive folder-URL parsing, stamp settings
   save/load, and filename generation. Skip with `SKIP_TESTS=1 ./build.sh`.

All output is saved to `dist/logs/build-<timestamp>.log` and
`dist/logs/test-<timestamp>.log`, starting with your macOS/Xcode/Swift/SDK
versions. If a check fails, the script points you at the exact log file —
send that file to Bell and he'll fix it.

## Permissions

On first capture, macOS asks for **Screen Recording** permission — every screenshot
tool needs this. Allow it in **System Settings → Privacy & Security →
Screen Recording**, then press Ctrl+Shift+5 again.

No Accessibility permission is needed: the global hotkey uses the classic Carbon
hotkey API, which requires no extra permissions.

## Usage

- **Ctrl+Shift+5** — capture a region (native crosshair UI; Esc cancels)
- **Ctrl+Shift+6** — OCR a region straight to the clipboard
- Annotate with the floating toolbar: arrow, line, rectangle, ellipse, **diamond**,
  text, pen, highlighter, **counter badges** (numbered steps), eraser, **color picker**
  (eyedropper — click the screenshot to use any color), blur, **spotlight**
  (dims everything except a region), crop
- **Excalidraw-style editing**: the select tool (default) lets you click to select,
  ⇧-click or drag a marquee for multi-select, drag to move, drag corner handles to
  resize, double-click text to edit it in place, ⌫ to delete, ⌘A to select all —
  every move/resize/edit is undoable
- **Hand-drawn look** (on by default): wobbly sketch strokes, Marker Felt text, plus
  Excalidraw-style **stroke styles** (solid / dashed / dotted) and **fill styles**
  (none / solid / hachure / cross-hatch) for shapes
- **⌘C** copy PNG to clipboard · **⌘S** save PNG · **⌘U** upload to Google Drive
  and copy the share link · **⌘Z / ⇧⌘Z** undo / redo · **Esc** close the editor
- Saved files are named `SnapMark_<site-or-app>_<timestamp>.png`, e.g.
  `SnapMark_example.com_2026-09-21_08.44.20.png`
- Blur permanently pixellates that part of the image — good for redacting API
  keys, names, addresses, etc.
- Crop clears annotations (undo restores everything, including the crop)
- **Pin to screen** — float the screenshot above all windows; drag to move,
  drag edges to resize, hover for the close button; close them all from the
  menu bar
- Every capture records **metadata**: date/time, macOS user, and the frontmost
  app at capture time — shown in the editor and embedded in saved PNGs
  (title/author/description/creation-time)
- **Metadata stamp** — a configurable badge burned onto saved, copied, pinned
  and uploaded images. Toggle and reorder fields (username, app name, page URL,
  date/time, custom text), pick the corner, size, and background opacity — with
  a live preview in Settings. If you capture from Safari, Chrome, Edge, Brave,
  Arc, Opera or Vivaldi but the URL can't be read (usually a denied Automation
  permission), the editor shows a warning with a shortcut to fix it.

## Google Drive upload

The editor's **Upload** button (⌘U) uploads the annotated PNG to your Google
Drive and copies the share link to the clipboard.

One-time setup in **Settings → Google Drive**:

1. In Google Cloud Console, create a **Desktop app** OAuth client
   (APIs & Services → Credentials).
2. Paste the client ID into SnapMark Settings.
3. Click **Connect Google Drive** and sign in — the refresh token is stored in
   your Keychain, the client ID in app preferences, nothing else.
4. Optionally paste a Drive folder URL or ID to upload into that folder, and
   choose whether uploaded links are public (anyone with the link) or private
   to you.

The app only ever sees files it created itself (`drive.file` scope).

## On-device AI

Everything here runs on your Mac — no network, no accounts, no API keys.

- **Ctrl+Shift+6** — capture a region and copy its text straight to the clipboard
  (Apple Vision OCR), with a small confirmation toast
- In the editor, the **✨ menu**: **Redact faces**, **Redact personal info**
  (emails, phone numbers, credit-card numbers, API keys, person names — found
  with Vision OCR plus on-device named-entity recognition), **Copy text from
  image**
- **QR codes** in a screenshot are detected automatically and shown as chips
  with Open/Copy actions (toggle in Settings)
- **Translate text…** (macOS 15+) — OCRs the screenshot and translates it
  on-device; target language in Settings
- **Apple Intelligence extras** (macOS 26+, Apple Silicon): **Summarize text**
  and **Save with AI-suggested name…**, powered by the on-device model

`build.sh` weak-links the newer system frameworks, so the app still builds and
launches on older macOS — the extras simply stay hidden until the OS supports
them.

## Notes & limitations

- When built with the macOS 26+ SDK, the floating toolbar and actions render as
  Liquid Glass pills; on older SDKs / macOS they fall back to a frosted material.
  Either way the app still runs on macOS 13+.

- The hotkeys are fixed to Ctrl+Shift+5 / Ctrl+Shift+6 in `Sources/SnapMark/HotKeyManager.swift`
  (change `kVK_ANSI_5` / `kVK_ANSI_6` and rebuild to customize).
- Capture itself is done with the system `screencapture` tool, so quality and the
  selection UI match macOS exactly.
- v1 has no scrolling capture — the natural next feature if you want it.
