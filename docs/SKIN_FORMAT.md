# Controller skin format (`.gcskin`)

A skin is **one JSON file** with the extension `.gcskin`. Users import skins from the Files app. The app validates each skin before using it. Source: `Packages/GCControls/Sources/GCControlsCore/Skin.swift`.

## Top level

| Key | Type | Notes |
|---|---|---|
| `formatVersion` | int | Currently `1`. Newer versions are rejected with a clear message. |
| `identifier` | string | Unique, e.g. `com.example.sunset`. Re-importing the same identifier replaces the skin. Can't reuse `builtin.*`. |
| `name` | string | Shown in the skin picker. |
| `author` | string? | Optional. |
| `palette` | object | Colors (see below). |
| `portrait` | layout | Bottom-half controller. |
| `landscape` | layout | Full-screen overlay. |
| `images` | {name: base64 PNG}? | Optional custom art, referenced by items. |

## Palette

All values are `"#RRGGBB"` or `"#RRGGBBAA"`:
`backgroundTop`, `backgroundBottom`, `glassHighlight`, `stickBase`, `neutral`, `label`, `buttonA`, `buttonB`, `buttonZ`, `cStick`, `accent`.

## Layout

| Key | Type | Notes |
|---|---|---|
| `mappingSize` | `{width, height}` | Coordinate space for item frames, in points. The built-in skins use 400×420 for portrait and 844×390 for landscape. |
| `items` | [item] | See below. |
| `defaultOpacity` | 0…1 | Portrait `1.0`; the landscape overlay is usually about `0.4`. Users can override it. |
| `showsBackground` | bool | Draws the matte shell with recessed wells. Usually `true` for portrait and `false` for landscape. |
| `backgroundImage` | string? | Optional image name. |

The controller scales uniformly to fit. Each item anchors to its nearest side, determined by its horizontal center in the mapping space:
- left of 42% → the left edge
- right of 58% → the right edge
- otherwise → the center

The layout therefore adapts to every screen width and respects the safe area.

## Item

| Key | Type | Notes |
|---|---|---|
| `id` | string | Unique within the layout. Layout edits are stored by this id. |
| `input` | enum | `a b x y z start dpad mainStick cStick l r menu logo` |
| `shape` | enum | `circle pill roundedRect dpad stick logo` |
| `frame` | `{x, y, width, height}` | In mapping points, origin at the top-left. |
| `color` | string? | A palette role name (e.g. `"buttonA"`) or a hex color. |
| `label` | string? | Drawn debossed on the part. |
| `hitInset` | number? | Extra touch slop around the frame. Default `8`. |
| `image`, `pressedImage` | string? | Names in `images`. These replace the drawn art. |

**Required inputs in both layouts:** `a b x y z start dpad mainStick cStick l r menu`.

Validation rejects a skin if:
- an input is missing
- an id is duplicated
- a frame lies outside the mapping size (5% tolerance)
- an item references an image that isn't included
- the file is larger than 20 MB

## Rules for skin authors (and for us)

- Use original art only: no console-maker logos, trademarks, or traced controller photos.
- Keep the GameCube conventions so that in-game prompts make sense:
  - A is large and green; B is small and red.
  - Z is purple and the C-stick is yellow.
  - X, Y, L, R and Start are neutral.

## Minimal example (abridged)

```json
{
  "formatVersion": 1,
  "identifier": "com.example.sunset",
  "name": "Sunset",
  "palette": { "backgroundTop": "#5A2E3A", "backgroundBottom": "#2A1218", "glassHighlight": "#FFE9E0",
               "stickBase": "#2A1218", "neutral": "#D8C2BC", "label": "#FFFFFF",
               "buttonA": "#3F9D67", "buttonB": "#B64B51", "buttonZ": "#7461B8", "cStick": "#CBA746", "accent": "#E0A080" },
  "portrait": {
    "mappingSize": { "width": 400, "height": 420 },
    "defaultOpacity": 1, "showsBackground": true,
    "items": [
      { "id": "a", "input": "a", "shape": "circle", "frame": { "x": 262, "y": 124, "width": 78, "height": 78 }, "color": "buttonA", "label": "A" }
    ]
  },
  "landscape": { "...": "same structure" }
}
```

To get a complete, valid starting point, export a built-in skin (`ControllerSkin.encoded()`).
