# The `.draw` format (version 1)

A `.draw` file is UTF-8 JSON holding every stroke of a PencilKit drawing, page by page. It is
the only copy of the drawing: the app reads it back losslessly and stores no private binary
alongside it, so any tool can read, render, or generate these files.

```json
{
  "type": "obsididraw",
  "version": 1,
  "source": "Obsididraw",
  "paper": {
    "size": "a4",
    "width": 595.28,
    "height": 841.89,
    "color": { "light": "#ffffffff", "dark": "#1c1c1eff" }
  },
  "pages": [
    {
      "width": 595.28,
      "height": 841.89,
      "strokes": [
        {
          "ink": "pen",
          "color": "#000000ff",
          "seed": 3127784211,
          "created": 1793367512.204,
          "points": [[120.5, 88.25, 0, 3.1, 3.1, 1, 0.84, 1.571, 1.2, 1], "…"]
        }
      ]
    }
  ]
}
```

## Top level

| Key       | Type   | Notes |
|-----------|--------|-------|
| `type`    | string | Always `"obsididraw"`. Readers should reject anything else. |
| `version` | int    | Format version. Readers should reject versions newer than they support. |
| `source`  | string | Optional. The app that wrote the file. |
| `paper`   | object | Page setup, see below. |
| `pdf`     | string | Optional. Path of a PDF this drawing annotates, relative to the `.draw` file's folder. Page `i` is drawn over PDF page `i`. |
| `pages`   | array  | One entry per page, in order. Always at least one. |

## Paper

| Key      | Type   | Notes |
|----------|--------|-------|
| `size`   | string | `infinite`, `a4`, `a5`, `letter`, `legal`, `custom`, or `pdf` (sizes come from the PDF). |
| `width`  | number | Page width in points (1/72 inch). For `infinite`, the width of the scrolling page. |
| `height` | number | Page height in points. Unused for `infinite`. |
| `color`  | object | `light` and `dark`: `#RRGGBBAA` page colors for light and dark appearance. |
| `template` | string | Optional pattern behind the ink, see below. Missing or unknown values mean `blank`. Ignored when the drawing has a `pdf`. |

An `infinite` drawing has exactly one page that grows downward. Renderers usually crop it to
its content.

**Dark appearance.** Ink colors are always stored as drawn in light appearance. To show a
drawing in dark appearance, fill the page with `color.dark` and invert the ink's lightness, as
PencilKit does on iPad. Drawings with a `pdf` always render light.

## Templates

Patterns are part of the page, not the ink: they're drawn over the page color and under every
stroke, black in light appearance and white in dark, at 30% opacity, and are never inverted.
Lines are 0.6 points thick and centered on their position; dots have a 0.9 point radius. All
positions are in page points. Below, `W` and `H` are the page size, and `last` is `H` for
`infinite` paper (the pattern runs to the end of the visible page) or `H − 24` otherwise.
"Rules" are horizontal lines at `y = 48, 72, 96, …` up to and including `last`. The compact
templates are the same as their namesakes with the rules 12 points apart instead of 24
(`y = 48, 60, 72, …`), which doubles the number of lines.

| Value            | Pattern |
|------------------|---------|
| `blank`          | None. |
| `lined`          | Rules across the full width. |
| `linedCompact`   | `lined` with compact rules. |
| `squares`        | Vertical and horizontal lines every 24 points, starting at 24 and stopping before `W` and `H`. |
| `dots`           | A dot at every intersection of that same 24-point grid. |
| `cornell`        | A line across the full width at `y = 48`. With `cue = round(0.3 × W)` and `summary = round(0.8 × H)` (or `H` for `infinite`): a vertical line at `x = cue` from 48 to `summary`, rules from `cue` to `W` at `y = 72, 96, …` before `summary`, and, except on `infinite`, a line across the full width at `y = summary`. |
| `twoPaneLined`   | Two equal columns inside a 24-point side margin with a 24-point gutter, each with its own rules, and a vertical divider centered in the gutter from `y = 24` to `last`. |
| `twoPaneLinedCompact` | `twoPaneLined` with compact rules. |
| `threePaneLined` | `twoPaneLined` with three columns. |
| `threePaneLinedCompact` | `threePaneLined` with compact rules. |

## Pages

| Key       | Type   | Notes |
|-----------|--------|-------|
| `width`   | number | Page width in points. |
| `height`  | number | Page height in points. For `infinite` paper, the bottom of the lowest stroke (advisory). |
| `strokes` | array  | In paint order, back to front, in page coordinates: origin at the top-left, y grows downward. For PDF pages, the coordinates cover the page's crop box as displayed, after its rotation. |

## Strokes

| Key         | Type     | Notes |
|-------------|----------|-------|
| `ink`       | string   | `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon`, or a raw PencilKit ink identifier such as `com.apple.ink.reed`. Unknown inks should render like `pen`. |
| `color`     | string   | `#RRGGBBAA` in sRGB, as drawn in light appearance. |
| `transform` | number[6] | Optional affine matrix `[a, b, c, d, tx, ty]`, the same as SVG `matrix()`. Omitted means identity. Applies to `points` and `mask`. |
| `mask`      | string   | Optional SVG path data (absolute `M L Q C Z` only) clipping the stroke, left behind by the pixel eraser. In the same coordinate space as `points`. |
| `seed`      | uint32   | Optional. PencilKit's texture seed for textured inks. |
| `created`   | number   | Optional creation time, Unix seconds. |
| `points`    | number[][] | The stroke's control points, see below. |

### Points

Each point is an array in this fixed order. Readers must accept shorter arrays and fill the
missing fields with the defaults shown.

| Index | Field            | Unit                                | Default |
|-------|------------------|-------------------------------------|---------|
| 0     | `x`              | points                              | required |
| 1     | `y`              | points, y grows downward            | required |
| 2     | `t`              | seconds since the stroke started    | 0 |
| 3     | `w`              | width of the ink footprint, points  | 2 |
| 4     | `h`              | height of the ink footprint, points | `w` |
| 5     | `opacity`        | 0–1                                 | 1 |
| 6     | `force`          | Pencil force                        | 1 |
| 7     | `azimuth`        | radians                             | 0 |
| 8     | `altitude`       | radians                             | π/2 |
| 9     | `secondaryScale` | multiplier                          | 1 |

The points are **control points of a uniform cubic B-spline**, exactly as PencilKit stores them,
not points on the curve. To draw the curve, repeat the first and last control point twice
(clamping the spline to its ends) and evaluate each segment. As a simpler approximation you can
draw a polyline through the control points: they sit very close to the curve.

`w` and `h` are PencilKit's internal ink footprint, not the drawn width. With `size` as their
average, draw a solid shape `scale × (size − offset)` points wide, never below zero:

| Ink                | `scale` | `offset` | Notes |
|--------------------|---------|----------|-------|
| `pen`, `monoline`  | 2       | 2        | Unknown inks should use this too. |
| `fountainPen`      | 1       | 2        | Typical value: wider on vertical strokes (`2 × (size − 2)`), narrower on horizontal ones (`(size − 2) / 2`). |
| `pencil`, `crayon`, `watercolor` | 1 | 0 | PencilKit's texture spans about `2 × size`, but its speckle covers only about half of that. |
| `marker`           | 1       | 0        | Typical value: about `1.4 × size` on vertical strokes, `0.56 × size` on horizontal ones. |

## Annotating PDFs

The Obsididraw app annotates `Paper.pdf` through a companion drawing named `Paper.pdf.draw` in
the same folder, with `"pdf": "Paper.pdf"` and `"paper": { "size": "pdf", … }`. The PDF itself is
never modified. Embed `![[Paper.pdf.draw]]` in a note to show the annotated PDF.

## Compatibility

Future versions only add optional keys, or extra fields at the end of the point arrays, and keep
the same meaning for existing ones. Anything else gets a new `version` number.
