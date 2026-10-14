# The Scribe file format

Everything Scribe stores is plain JSON in ordinary folders. Nothing requires
Scribe to read it. This document is the contract.

## Folder layout

```
<workspace root>/
  <Notebook name>/
    notebook.json
    <Section name>/
      section.json
      <Page title>.json
      assets/
        ab12cd34ef56.png
```

Folder and file names follow the user-visible titles, sanitised for both macOS
and Windows (so a synced folder opens on either) and de-duplicated with a ` (2)`
suffix. Names are for humans; identity lives in the
`id` fields, and display order lives in the manifests.

A directory is a notebook only if it contains `notebook.json`, and a section
only if it contains `section.json`. Anything else is ignored, so it is safe to
keep unrelated files in the tree.

## notebook.json

```json
{
  "schema": "scribe.notebook/1",
  "id": "6f1c9b0e4a2d4f8e9c1b2a3d4e5f6071",
  "name": "My Notebook",
  "color": "#7C5CE6",
  "sectionOrder": ["Quick Notes", "Reading"],
  "source": { "app": "onenote", "id": "{...}", "importedAt": "2026-08-12T09:31:46+10:00" }
}
```

`sectionOrder` lists **folder names** in display order. Sections present on disk
but missing from the list are appended alphabetically rather than hidden, so
dropping a folder in by hand works.

`source` is present only on imported content and records where it came from.

## section.json

```json
{
  "schema": "scribe.section/1",
  "id": "…",
  "name": "Quick Notes",
  "color": "#4C9AFF",
  "pageOrder": ["Welcome to Scribe.json", "Meeting 2026-08-11.json"]
}
```

`pageOrder` lists **file names** in display order, with the same
append-if-missing rule.

## Page files

```json
{
  "schema": "scribe.page/1",
  "id": "…",
  "title": "Meeting 2026-08-11",
  "created": "2026-08-11T09:02:00+10:00",
  "modified": "2026-08-11T10:14:22+10:00",
  "background": { "kind": "ruled", "spacing": 32, "color": "#E8EEF5" },
  "strokes": [ … ],
  "textBoxes": [ … ],
  "images": [ … ],
  "source": { … }
}
```

All coordinates are in **page units**, with the origin at the top-left of the
page. One unit is one device-independent pixel on Windows and one point on
macOS; at 100% zoom it is one unit on screen in both apps, so a page looks the
same in either. The page grows downward and rightward as
content is added; there is no fixed page size.

### background

`kind` is one of `blank`, `ruled`, `grid`, `dots`. `spacing` is the rule/grid
pitch in DIPs. `color` describes the **light-mode** rule colour; in dark mode
the theme supplies its own so the lines do not glare, and this value is left
untouched.

### strokes

```json
{
  "color": "#1A1A1A",
  "width": 2.4,
  "height": 2.4,
  "tip": "ellipse",
  "highlighter": false,
  "fit": true,
  "pressureSensitive": true,
  "points": [102.5, 88.25, 0.412, 103.1, 88.9, 0.47, …]
}
```

`points` is a **flat array with stride 3** — `x, y, pressure` repeating.
Pressure is normalised `0..1`. Flat storage roughly halves file size versus
nested arrays, which matters because a dense page of handwriting runs to tens of
thousands of points. Coordinates are rounded to 2 decimal places and pressure to
3; the error is far below one pixel.

`color` is `#RRGGBB` or `#AARRGGBB`. It is the colour as authored and is
**independent of theme** — dark mode changes how ink is painted, never what is
stored.

`tip` is `ellipse` or `rectangle`. `fit` enables spline smoothing when
rendering (and erasing: a partial erase cuts along the smoothed line). `pressureSensitive: false` renders an even width regardless of the
pressure values, which is what the highlighter uses.

A stroke with fewer than 3 numbers in `points` is skipped. Out-of-range pressure
is clamped, so hand-edited files will not crash the app.

### textBoxes

```json
{
  "id": "…",
  "x": 90, "y": 96,
  "width": 620,
  "height": null,
  "text": "Line one\nLine two",
  "fontFamily": "Segoe UI",
  "fontSize": 15,
  "color": "#1A1A1A",
  "bold": false,
  "italic": false,
  "underline": false,
  "strikethrough": false,
  "heading": "body",
  "spans": [ { "start": 21, "length": 5, "bold": true } ],
  "xaml": "<FlowDocument ...>...</FlowDocument>"
}
```

`height: null` (or absent) means size-to-content. Empty containers are dropped
on save rather than persisted.

The box-level fields (`fontFamily`, `fontSize`, `color`, `bold`, …) are the
formatting of the whole box. `spans` overrides them for runs of text: `start`
and `length` count **UTF-16 code units** (how both AppKit and .NET index
strings), and any of `bold`, `italic`, `underline`, `strikethrough`,
`fontSize`, `fontFamily` and `color` may appear; what is left out is inherited
from the box. Out-of-range spans are clipped, never trusted.

`fontFamily` holds a logical name shared by both apps: `Segoe UI` (the system
font), `Handwritten`, `Georgia`, `Cascadia Code` (monospace), `Arial`,
`Times New Roman`, `Comic Sans MS`. Each app maps these onto fonts it has.

`heading` is one of `body`, `title`, `h1`, `h2`, `h3`, `handwritten`.

`xaml` is rich text written by the Windows app. It is kept verbatim while the
text is unchanged; once the box is edited it describes stale text, so the macOS
app drops it and writes `spans` instead.

### images

```json
{ "id": "…", "x": 40, "y": 500, "width": 320, "height": 180, "file": "assets/ab12cd.png" }
```

`file` is relative to the **section** folder and always uses forward slashes.

### latexBlocks

```json
{
  "id": "…",
  "x": 60, "y": 150,
  "latex": "\\int_{0}^{\\infty} e^{-x^2} \\, dx = \\frac{\\sqrt{\\pi}}{2}",
  "scale": 22,
  "color": "#1A1A1A"
}
```

Stores mathematical equations formatted in standard LaTeX syntax.

### tables

```json
{
  "id": "…",
  "x": 60, "y": 300,
  "hasHeader": true,
  "rows": [
    ["Item", "Quantity", "Price"],
    ["Apples", "10", "$5.00"]
  ],
  "columnWidths": [120, 100, 120]
}
```

Stores structured data tables with optional header row and custom column widths.

## Compatibility rules

- `schema` carries a name and a major version. A reader should refuse a major
  version it does not know rather than guess.
- Unknown fields are preserved: add fields freely, and treat missing fields as
  their documented default. The macOS app carries unknown fields on the page,
  its background, and every object (matched by `id`) through each save.
- Writers should write via a temporary file and swap it into place, which is
  what Scribe does, so that a reader or sync client never sees a partial file.
- The reference implementation of this format is `crates/scribe-core`
  (`model.rs` and `workspace.rs`), with tests in `crates/scribe-core/tests`.
