<p align="center"><img src="docs/icon.png" width="160" alt="Scribe icon"></p>

# Scribe

A notebook app for macOS, built around the pen. Handwriting, typed text,
images, equations and tables share one infinite page, and everything is kept
in plain folders and JSON files on your own disk.

Scribe is written in **Rust** and **SwiftUI**:

- `crates/scribe-core`: the Rust core. It holds the file format, the folder
  workspace, search, table clipboard formats, theme-aware colour, and the ink
  geometry engine that turns pen samples into pressure-varying outlines.
- `macos/`: the SwiftUI app. It holds the window, the notebook navigator, the
  page canvas (AppKit, for pen input and zoom), and the on-page objects. It
  calls the core through a small C ABI.

---

## Build

Needs Rust (`cargo`) and Xcode 16 or newer, on macOS 15 or later.

```bash
./build.sh
```

That builds the Rust core, draws the app icon, builds the app, and writes
`dist/Scribe.app`. Copy it to `/Applications` or open it in place:

```bash
open dist/Scribe.app
```

To run both test suites (Rust and Swift) as part of the build:

```bash
./build.sh --test
```

For day-to-day work you can also open `Package.swift` in Xcode once the Rust
core has been built (`cargo build --release -p scribe-core`).

## The window

Velvet dark: three soft panels on a near-black ground, with no hard edges
anywhere. Every corner is rounded, every control is a pill or a circle, and
depth comes from layered surfaces and a faint light along their top edges
rather than outlines. Page titles are set in Fraunces at its softest; the rest
of the interface uses SF Pro Rounded.

- **Notebooks** on the left, with search at the top. Collapse the panel to an
  icon rail with the button beside the window controls (⌃⌘S).
- **Pages** in the middle, as cards with each page's opening text. Hide the
  panel with its « button (⌃⌘P); drag cards to reorder.
- **The page** on the right, centred in its pane. When the open panels leave
  less room than the page needs, it zooms out just enough to fit, centred with
  even margins. Zooming by hand turns that off until you click the zoom
  percentage or choose Fit Page Width (⌘9).
- **Focus mode** (⌘\\) hides both panels and leaves the page and the tools.
- Narrow windows fold the panels into the rail automatically, with notebooks
  and pages in a popover.

Tools live in one floating **dock** at the bottom of the page: pen,
highlighter, eraser, lasso, text, four ink colours and the highlighter, and an
Insert button for tables, equations, images, pasting and paper. Click the
active pen or highlighter again for its **tray**: colours, nib width, pressure,
and a preview stroke drawn by the real ink engine. While you type, a
**format pill** floats above the text box; while you have a lasso selection, a
pill above it offers Copy, Duplicate, Recolour and Delete.

## The drawing surface

- **Pressure-varying strokes.** Ink is rendered as a true outline whose width
  follows pressure, so downstrokes thicken and strokes taper as the nib lands
  and lifts. With a drawing tablet (Wacom and friends), pressure comes straight
  from the pen. A mouse or trackpad draws at an even mid pressure.
- **Jitter smoothing.** Strokes are resampled along a Catmull-Rom spline and
  pressure is averaged over a short window, so curves read smoothly and the
  width does not pulse.
- **The tablet pen's eraser end erases**, whatever tool is selected.
- **Zoom that stays crisp.** Pinch, or ⌘-scroll, from 15% to 600%. Ink, text,
  equations and tables are redrawn at every zoom level, not scaled bitmaps.

### Tools

| Key | Tool | Notes |
|-----|------|-------|
| `P` | Pen | Pressure-sensitive; pick a colour from the tray |
| `H` | Highlighter | Even width, translucent |
| `E` | Eraser | Press again for a partial eraser that rubs out part of a stroke |
| `S` | Lasso | Select ink and objects; drag to move, corner handle to resize (⇧ keeps proportions), ⌫ to delete, ⌘C/⌘X/⌘V |
| `T` | Text | Click anywhere for a text box; objects become editable |
| `Space` | Pan | Hold it, or drag with the middle button |

| Shortcut | Action |
|----------|--------|
| ⌘N / ⇧⌘N | New page / new notebook |
| ⌘Z / ⇧⌘Z | Undo / redo, across ink, objects and typing |
| ⌘F | Search every notebook (titles, typed text, table cells, handwriting) |
| ⌘B ⌘I ⌘U ⇧⌘X | Bold, italic, underline, strikethrough |
| ⌥⌘T ⌥⌘E ⌥⌘I | Insert table, equation, image |
| ⌥⌘V | Paste onto the page: images, tables (from Numbers, Excel, web pages, Markdown or CSV) or text |
| ⌘= ⌘− ⌘0 ⌘9 | Zoom in, zoom out, actual size, fit and centre the page |
| ⌃⌘S / ⌃⌘P | Collapse or expand the notebooks sidebar / hide or show pages |
| ⌘\\ | Focus mode: just the page and the dock |
| Esc | Finish typing and hand the keyboard back to the tools |

## On the page

- **Text boxes** with per-word formatting: heading styles, fonts (including a
  handwritten face), sizes, bold, italic, underline, strikethrough and colour.
  Drag the right edge to rewrap.
- **Equations** in LaTeX with a live preview, typeset natively by
  [SwiftMath](https://github.com/mgriebling/SwiftMath). Double-click to edit.
- **Tables** with a header row, resizable columns, and row and column
  insertion from the right-click menu. Copy a table out as a real table (HTML
  plus tab-separated text) or as Markdown.
- **Images** pasted, dropped in from a file, or chosen with Insert ▸ Image.
  Drag the corner to resize.

## Where your notes live

By default in `~/Documents/Scribe Notebooks`, as an ordinary folder tree:

```
Scribe Notebooks/
  My Notebook/
    notebook.json
    Quick Notes/
      section.json
      Meeting 2026-08-11.json
      assets/ab12cd.png
```

One JSON file per page, named after the page. You can browse the folder in
Finder, sync it with iCloud Drive or Dropbox, keep it in git, or read it with
any tool. The format is documented in [docs/FORMAT.md](docs/FORMAT.md). Writes
go through a temporary file and an atomic rename, so a crash or a sync client
reading mid-write never sees half a page. File ▸ Open Notebook Folder… points
Scribe at a different folder.

Deleting a page, section or notebook moves it to the Trash, so it can be
recovered.

The format is the same one the earlier Windows version of Scribe used, so
notebooks move between the two. Notebooks imported from OneNote on Windows
open here with their handwriting intact.

## Ink colour

Ink colour is adapted for display only: black handwriting shows as warm cream
on the dark page and stays black in the file, so pages written here read
correctly anywhere else, and coloured inks keep their hue, lifted to stay
legible.

## Checking the ink engine

Synthetic mouse events carry no pressure, so the ink engine is checked with a
render test that draws sample strokes through the same code path the pen uses:

```bash
dist/Scribe.app/Contents/MacOS/Scribe --render-selftest out.png
```

The sheet shows pressure response, tapering, smoothing, the highlighter, dots,
and a stroke round-tripped through the JSON format, on both themes.

## The icon

The app icon is a single bold S in cream ink on a velvet-dark tile, with a drop
of terracotta ink where the nib lifted: one stroke and no paper, so it holds up
at 16 px and sits well beside Electron's icon in its app switcher. It is drawn
by `crates/scribe-icon` using the app's own ink engine, so the S is a real
pressure-varying stroke, heavier on the downstroke and easing off where the nib
lands and lifts. The small sizes get a heavier stroke rather than a shrunk copy. `build.sh`
renders every size macOS needs and packs them into `AppIcon.icns`.

## Importing PDFs and Goodnotes notebooks

**File → Import PDF or Goodnotes…** (⇧⌘I) turns each PDF into a section in the
current notebook, one page per PDF page, with the PDF as the paper so you can
write straight onto it. The PDF is copied into the section, so the notebook
stays self-contained. To bring a notebook over from Goodnotes, export it as a
PDF first (Share → Export → PDF). Its handwriting arrives as part of the page
rather than as editable strokes, but Scribe reads it, along with any typed
text, so search finds it.

## Importing from OneNote

File → **Import from OneNote…** (on the Mac, and in Scribe inside Electron) brings your
OneNote notebooks across with handwriting, typed text, pictures and tables where they
were. Each OneNote notebook becomes a folder and each section a notebook (sections in a
section group are named "Group – Section").

Scribe reads OneNote through Microsoft's web API with a temporary key from Microsoft's
**Graph Explorer**, so there is no app to register: open Graph Explorer (the sheet has a
button), sign in, run any OneNote query once so it asks for **Notes.Read**, then copy
the key from the **Access token** tab and click Continue. Scribe takes the key from the
clipboard, clears it, and never stores it. The key lasts about an hour; if it runs out
part way, copy a fresh one and import again: pages already brought in are skipped
(`.scribe/onenote-import.json` remembers them).

OneNote pages have no fixed size, so they come in as **canvas pages**: they keep their
full width, open at a readable zoom with sideways scrolling, grow as you write past an
edge, and show their whole width in thumbnails. Attachments and audio aren't imported.
The conversion lives in `crates/scribe-core/src/onenote.rs`.

## Searching handwriting

Search finds written words as well as typed ones. Scribe reads each page's ink
with macOS's built-in text recognition a moment after you save, and on start it
works through older pages in the background, most recently edited first.
Nothing leaves your Mac. The text it reads is kept in one file,
`.scribe/ink-text.json` in the notebook folder, and never written into your
pages; delete it and it is rebuilt. Recognition is best on clear print and
reasonable on joined-up writing.

## Inside Electron

Scribe also runs inside the Electron desktop app (`../desktop`) on macOS. The interface
is the `ScribeUI` library; the standalone app is a thin `@main` around it, and
`ScribeEmbed` builds it into `libScribeEmbed.dylib` with a small C API: make the view,
show or hide it, run a menu action by name, and hand over the menu as JSON. Embedded,
the host draws its app switcher where the window's traffic lights would be (Electron
hides them), and nothing else about the interface changes. `../desktop/scripts/build-scribe.sh`
builds and stages it.

## The library

Scribe opens on a library, like Goodnotes: recent pages along the top, then your folders
as coloured stacks. Open a folder to see its notebooks as covers (each notebook's first
page, or its latest-edited page if you choose that from its menu) with a spine in the
notebook's colour. Long-press (or right-click) a folder or notebook to rename, recolour
or delete it. On the Mac the library shows when no page is open, and View → Library (⌘L)
brings it back.

The library's words map onto the files like this: a **folder** is a Scribe notebook
folder (`notebook.json`), and a **notebook** is a section folder (`section.json`) holding
pages. Only the labels changed; the format is the same (docs/FORMAT.md).

## All pages

The grid button by a page's title (or View → All Pages, ⇧⌘G, on the Mac) shows every
page in the section as thumbnails. Tap one to open it, drag a page onto another to move
it there, and use a page's menu to star, rename or delete it. "Starred" lists starred
pages only. The grid is one SwiftUI view (`macos/Scribe/Views/PageGrid.swift`) shared by
the Mac app, Scribe inside Electron, and the iPad.

Thumbnails are drawn by `macos/Scribe/Core/Thumbnails.swift` on both platforms and cached
in the notebook folder's `.scribe/thumbs.nosync/`, one PNG per page. iCloud Drive leaves
`.nosync` folders alone, so each device keeps its own cache. Delete the folder any time;
it is rebuilt as pages are shown.

## On the iPad

`ios/` is a companion app for the iPad, laid out for the iPad mini. It uses the same Rust
core and the same page files, so there is no sync service: on first launch you pick the
**Scribe Notebooks** folder in iCloud Drive, and the iPad and the Mac read and write the
same files. The app checks for changes from the Mac every few seconds and saves a moment
after you stop writing.

The Apple Pencil writes, and fingers scroll and pinch. Without a Pencil, the hand button
in the tool dock lets a finger write (then scrolling takes two fingers). Double-tap the
Pencil to swap between pen and eraser. A notebook scrolls straight through its pages, one
under another, with a "3 of 14" counter while you scroll; write on any page you can see.
Pull past the end of the last page to add a new one. The notebooks you've opened sit as
tabs above the page. The **⋯** menu switches to one page at a time (pull past a page's
end to turn it) and turns finger drawing on or off. Swiping sideways never goes back
while you're writing; use the back button. Pages keep their size while you write, like paper: ink past an edge is cut off
rather than growing the page (a page only grows to fit what is already on it, such as
writing from the Mac). The iPad's pen is a little heavier than the Mac's, and its curve
lifts the light pressure of everyday Pencil writing.

Folders and notebooks are made from the library (the **⋯** menu, the **+** in a folder, or
the dashed tiles). To rename a page, tap the open page's title, or long-press it in the
page grid. You get the pen, the highlighter, the stroke
eraser, the lasso, the Mac's ink colours, three nib sizes and undo. Tap with two fingers
to undo and three to redo. The lasso selects writing to move, recolour (tap a colour) or
delete. The **⋯** menu sets the page's paper and line spacing, and new pages in that
notebook follow.

The library's search finds titles, typed text and handwriting; the iPad reads handwriting
itself, as the Mac does, so pages written on either are found on both. The **⋯** menu (or
**+** in a folder) imports PDFs and Goodnotes exports from the Files app, the same way as on
the Mac. Deleted pages, notebooks and folders go to **Recently Deleted** in the library's
menu for 30 days, kept in the library folder's `.scribe/Recently Deleted/`. Typed text, pictures, tables and
imported PDFs show as on the Mac; for now they're edited on the Mac, and formulas show
their LaTeX source.

### Electron on the iPad

The iPad app holds Electron too, as the desktop does: the switch at the top left of
Scribe's library and of Electron's sidebar (or Ctrl-Cmd-1 / Ctrl-Cmd-2 on a keyboard) moves
between them. Electron opens the Markdown vault from iCloud Drive (**OnyxVault**, picked
once like the notebook folder) and reads and writes the same files as the desktop, checking
for changes every few seconds. Its code is in `ios/Electron/`, written natively rather than
reusing the desktop's web UI.

Notes open for reading, drawn natively in the Velvet theme: headings, lists and tasks (tap a
box to tick it), tables, code, quotes, callouts, images, `![[embeds]]` and LaTeX, drawn with
SwiftMath (commands only KaTeX knows, such as `\implies` or `\R`, are rewritten first). The
pencil button (⌘E) switches to the editor, which colours the Markdown as you type, carries
lists on with Return, has formatting keys above the keyboard (⌘B, ⌘I, ⌘K) and suggests
notes after `[[`. Either way you stay at the same place in the note. Links open their note
(a missing one is created, as in Obsidian), and the end of each note lists its backlinks.
The sidebar has recent notes, the file tree and search; its **⋯** menu has the desktop's
Todo list (`.onyx/todos.md`), tags, today's note (⇧⌘D), a calendar of daily notes
(`Daily/YYYY-MM-DD.md`, as the desktop names them) and the graph (⌘G). The graph uses the
desktop's layout (tag nodes, pastel tag colours, tag families gathered into continents, a
round edge): drag to move, pinch to zoom, tap a dot to see it and open it. A note's **⋯**
menu has its local graph, one to three links deep. Renaming a note rewrites links to it,
and deleting moves it to the vault's `.trash` folder. Canvases, the database view and AI
are still desktop-only.

To install it for free, open `ios/Scribe.xcodeproj` in Xcode, add your Apple ID under
Settings → Accounts, choose your team under Signing & Capabilities, plug in the iPad and
press Run. With a free Apple ID the install lasts seven days; run it again from Xcode to
renew. Xcode builds the Rust core for the iPad itself (`ios/build-core.sh`). After
changing `ios/project.yml`, regenerate the project with `xcodegen` in `ios/`. The icon is
`ios/icon.svg`.

## Layout of the source

| Path | What is in it |
|------|----------------|
| `crates/scribe-core/src/model.rs` | The page, notebook and section formats |
| `crates/scribe-core/src/workspace.rs` | Folder workspace, manifests, search, atomic writes |
| `crates/scribe-core/src/geometry.rs` | Stroke outlines, hit testing, partial erase, lasso |
| `crates/scribe-core/src/color.rs` | Colour parsing and dark-mode ink adaptation |
| `crates/scribe-core/src/table.rs` | HTML / Markdown / TSV / CSV tables in and out |
| `crates/scribe-core/src/ffi.rs` | The C ABI (header in `crates/scribe-core/include`) |
| `crates/scribe-icon/` | The icon renderer |
| `macos/Scribe/App/` | Window state, the root view, menus and their actions, pasting and inserting |
| `macos/ScribeApp/` | The standalone app's entry point (`@main`) |
| `macos/ScribeEmbed/` | C entry points for hosting Scribe in another app's window |
| `macos/Scribe/Canvas/` | The scroll view, page surface and ink view (pen input) |
| `macos/Scribe/Objects/` | Text boxes, rich text, images, equations, tables, floating pills |
| `macos/Scribe/Views/` | Sidebar, page list, rail, dock, pen tray, sheets, control styles |
| `macos/Scribe/Core/Theme.swift` | The velvet palette, radii, surfaces and title font |
| `macos/Scribe/Resources/Fonts/` | Fraunces (SIL Open Font License) |
| `macos/Tests/` | Swift tests |

## Known gaps

- OneNote attachments, audio and embedded files aren't imported, and pictures or tables
  inside a text block are placed by estimate below the text before them.
- Handwriting is read for search, but there is no "convert to typed text" command yet.
