# App Store screenshots

The App Store frames are generated, not hand-made. A caption change is an edit to
`frames.json` and one command — never a redraw.

```
store-assets/
  frames.json        every visual decision: copy, layout, crop, theme
  raw/en-US/         raw window captures (input, never edited)
Tools/StoreFrames/   the renderer (Swift + CoreGraphics, no dependencies)
fastlane/screenshots/en-US/   generated output — what `fastlane deliver` uploads
```

## Run it

```sh
./scripts/screenshots.sh          # capture raw windows (needs a GUI login + signed build)
./scripts/store-frames.sh --open  # build the captioned frames, then open them
```

Other useful runs:

| Command | Effect |
|---------|--------|
| `./scripts/store-frames.sh --only tunnels` | Render one frame, for a fast look at a copy change |
| `./scripts/store-frames.sh --list` | Print the shot order and every caption |
| `./scripts/store-frames.sh --probe` | Report the window box detected in each raw capture |
| `./scripts/store-frames.sh --size 1440x900` | Render the smaller accepted canvas |

The output directory is swept on a full run: a PNG the spec did not produce is
deleted, because `fastlane deliver` would otherwise upload it.

## What the design follows

Both patterns that work on the Mac App Store put the app window on a designed
background and say what the shot proves. Termius sets a bold two-tone headline at
the top and lets the window bleed off the bottom edge. Core Tunnel puts a plain
caption under a window on a desktop wallpaper. This set uses the first pattern,
because a bold headline survives the thumbnail size a shopper actually sees first.

Rules the spec keeps to:

- One claim per shot, in the headline. The sub-caption carries the proof.
- The window sits at the same height in every frame, so the gallery lines up even
  when one headline wraps and another does not.
- The first three shots do the selling. They are the config editor, tunnels and
  version history.
- One background family across all eight, so the set reads as one product.
- No claim the shot does not show.

## Editing the spec

`defaults` sets the look; a shot overrides only what it needs.

| Field | Meaning |
|-------|---------|
| `headline` / `accent` | Two-tone headline. `accent` goes on its own line unless `accentInline` is true |
| `sub` | One short supporting sentence, on a narrower measure than the headline |
| `badge` | Small eyebrow pill above the headline |
| `layout` | `headlineTop`, `captionBottom`, `sideLeft`, `sideRight` |
| `crop` | `"auto"` detects the window, or `[x, y, w, h]` in source pixels, top-left origin |
| `windowScale` | Window width as a fraction of the canvas |
| `windowTop` | Where the window's top edge sits, as a fraction of canvas height |
| `spotlight` | `[x, y, w, h]` in post-crop pixels — dims everything outside it |
| `callouts` | Named labels pinned to parts of the UI — see below |
| `insets` | Magnified detail card cut from the window, with a title |

## Callouts — putting names on the UI

A bare screenshot shows a shopper what the app looks like. A named one tells them
what they are looking at. Every shot carries two or three:

```json
{ "text": "Per-tunnel console", "detail": "Every handshake and retry",
  "shortcut": "⌘K", "at": [0.93, 0.62], "side": "right" }
```

| Field | Meaning |
|-------|---------|
| `text` | The feature name. Two or three words — it wraps, but short reads better |
| `detail` | One short supporting line |
| `shortcut` | The real keyboard shortcut, in a mono chip |
| `at` | The point being named, in fractions of the **window's** own size |
| `side` | `left` or `right` — which margin the card sits in |

Three rules keep them readable:

1. **Cards live in the margin, never over the window.** A label that covers the
   thing it names is worse than no label. The card shrink-wraps to the space
   beside the window, so a long name wraps instead of growing into the UI.
2. **Aim at a clear corridor.** The leader runs horizontally from the card to
   `at`, so everything between the window edge and that point gets a line through
   it. Target `x` around 0.03 for a left card and 0.93–0.96 for a right one, and
   pick the `y` of the row you mean.
3. **Never invent a shortcut.** Shortcuts come from the `.keyboardShortcut(…)`
   calls in `RootScene.swift`.

`spotlight` and `insets` are available but earn their place rarely — an inset
magnifying a region that already sits right beside it just clutters the frame.
Check the render before keeping one.

Use `--probe` before writing a `crop` by hand. Auto-detection reads flatness, not
colour distance, because the app's chrome is the same colour as the padding around
it, and a colour test eats into the window.
