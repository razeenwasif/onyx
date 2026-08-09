/**
 * Live Preview: the decoration layer that makes CodeMirror look like rendered
 * markdown while staying a plain-text editor.
 *
 * The rule Obsidian uses, and this reproduces: a construct renders formatted,
 * and its syntax markers are hidden, *unless* the selection touches it — then
 * the raw markdown reappears on that construct only. Block-level things
 * (headings, quotes, list bullets, code fences) reveal per line; inline things
 * (bold, links, tags) reveal per node.
 */

import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view'
import { EditorState, Range, StateEffect, StateField } from '@codemirror/state'
import { syntaxTree } from '@codemirror/language'

import { extractFrontmatterProperties, frontmatterLength } from '@shared/parse'

/** Callout types → the CSS color token and glyph used in Live Preview. */
const CALLOUT_COLORS: Record<string, string> = {
  note: 'var(--info)',
  abstract: 'var(--info)',
  summary: 'var(--info)',
  tldr: 'var(--info)',
  info: 'var(--info)',
  todo: 'var(--info)',
  tip: 'var(--success)',
  hint: 'var(--success)',
  important: 'var(--success)',
  success: 'var(--success)',
  check: 'var(--success)',
  done: 'var(--success)',
  question: 'var(--warning)',
  help: 'var(--warning)',
  faq: 'var(--warning)',
  warning: 'var(--warning)',
  caution: 'var(--warning)',
  attention: 'var(--warning)',
  failure: 'var(--error)',
  fail: 'var(--error)',
  missing: 'var(--error)',
  danger: 'var(--error)',
  error: 'var(--error)',
  bug: 'var(--error)',
  example: 'var(--accent)',
  quote: 'var(--fg-subtle)',
  cite: 'var(--fg-subtle)',
}

const CALLOUT_ICONS: Record<string, string> = {
  note: '✎',
  info: 'ℹ',
  tip: '★',
  hint: '★',
  success: '✓',
  check: '✓',
  done: '✓',
  question: '?',
  help: '?',
  faq: '?',
  warning: '⚠',
  caution: '⚠',
  attention: '⚠',
  failure: '✗',
  fail: '✗',
  danger: '⚡',
  error: '⚡',
  bug: '🐞',
  example: '❯',
  quote: '❝',
  todo: '☐',
  abstract: '≡',
  summary: '≡',
  tldr: '≡',
  important: '❗',
  missing: '✗',
  cite: '❝',
}

/** Set by the host so widgets can resolve links and open notes. */
export interface EditorHost {
  resolve(target: string): string | null
  openLink(target: string, newTab: boolean): void
  openTag(tag: string): void
  /** Vault-relative → a `data:`/`file:` URL the renderer can show. */
  imageSrc(target: string): string | null
  toggleTask(line: number): void
}

export const setHost = StateEffect.define<EditorHost>()

export const hostField = StateField.define<EditorHost | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setHost)) return e.value
    return value
  },
})

// ------------------------------------------------------------------ widgets

class CheckboxWidget extends WidgetType {
  constructor(
    readonly checked: boolean,
    readonly line: number,
  ) {
    super()
  }

  eq(other: CheckboxWidget): boolean {
    return other.checked === this.checked && other.line === this.line
  }

  toDOM(view: EditorView): HTMLElement {
    const box = document.createElement('input')
    box.type = 'checkbox'
    box.checked = this.checked
    box.className = 'cm-md-checkbox'
    box.addEventListener('mousedown', (e) => {
      e.preventDefault()
      e.stopPropagation()
      view.state.field(hostField)?.toggleTask(this.line)
    })
    return box
  }

  ignoreEvent(): boolean {
    return false
  }
}

class HrWidget extends WidgetType {
  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'cm-md-hr'
    return el
  }
}

class LinkWidget extends WidgetType {
  constructor(
    readonly text: string,
    readonly target: string,
    readonly unresolved: boolean,
    readonly external: boolean,
  ) {
    super()
  }

  eq(o: LinkWidget): boolean {
    return o.text === this.text && o.target === this.target && o.unresolved === this.unresolved
  }

  toDOM(view: EditorView): HTMLElement {
    const a = document.createElement('span')
    a.className = `cm-md-wikilink${this.unresolved ? ' is-unresolved' : ''}`
    a.textContent = this.text
    a.title = this.target
    a.addEventListener('mousedown', (e) => {
      e.preventDefault()
      e.stopPropagation()
      const host = view.state.field(hostField)
      if (this.external) void window.onyx.url.open(this.target)
      else host?.openLink(this.target, e.ctrlKey || e.metaKey || e.button === 1)
    })
    return a
  }

  ignoreEvent(): boolean {
    return false
  }
}

class TagWidget extends WidgetType {
  constructor(readonly tag: string) {
    super()
  }

  eq(o: TagWidget): boolean {
    return o.tag === this.tag
  }

  toDOM(view: EditorView): HTMLElement {
    const el = document.createElement('span')
    el.className = 'cm-md-tag'
    el.textContent = `#${this.tag}`
    el.addEventListener('mousedown', (e) => {
      e.preventDefault()
      e.stopPropagation()
      view.state.field(hostField)?.openTag(this.tag)
    })
    return el
  }

  ignoreEvent(): boolean {
    return false
  }
}

/** The frontmatter block, shown as Obsidian's properties table. */
class PropertiesWidget extends WidgetType {
  constructor(readonly source: string) {
    super()
  }

  eq(o: PropertiesWidget): boolean {
    return o.source === this.source
  }

  toDOM(): HTMLElement {
    const props = extractFrontmatterProperties(this.source)
    const wrap = document.createElement('div')
    wrap.className = 'properties'
    if (!props.length) {
      wrap.classList.add('is-empty')
      wrap.textContent = 'No properties'
      return wrap
    }
    for (const [key, values] of props) {
      const row = document.createElement('div')
      row.className = 'properties-row'
      const k = document.createElement('div')
      k.className = 'properties-key'
      k.textContent = key
      const v = document.createElement('div')
      v.className = 'properties-val'
      if (!values.length) {
        v.textContent = '—'
        v.style.color = 'var(--fg-subtle)'
      } else {
        for (const value of values) {
          const chip = document.createElement('span')
          chip.className = 'prop-chip'
          chip.textContent = value
          v.append(chip)
        }
      }
      row.append(k, v)
      wrap.append(row)
    }
    return wrap
  }

  ignoreEvent(): boolean {
    return false
  }
}

/** The `[!type]` marker of a callout, replaced by its icon and title. */
class CalloutTitleWidget extends WidgetType {
  constructor(
    readonly type: string,
    readonly title: string,
    readonly foldable: boolean,
  ) {
    super()
  }

  eq(o: CalloutTitleWidget): boolean {
    return o.type === this.type && o.title === this.title
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'cm-callout-title'
    const icon = document.createElement('span')
    icon.textContent = CALLOUT_ICONS[this.type] ?? '●'
    icon.style.marginRight = '8px'
    const label = document.createElement('span')
    label.textContent = this.title
    el.append(icon, label)
    return el
  }
}

class ImageWidget extends WidgetType {
  constructor(
    readonly src: string,
    readonly alt: string,
  ) {
    super()
  }

  eq(o: ImageWidget): boolean {
    return o.src === this.src
  }

  toDOM(): HTMLElement {
    const img = document.createElement('img')
    img.className = 'cm-md-image'
    img.src = this.src
    img.alt = this.alt
    return img
  }
}

// ------------------------------------------------------------- decorations

const HIDE = Decoration.replace({})

const HEADING_CLASS = ['cm-md-h1', 'cm-md-h2', 'cm-md-h3', 'cm-md-h4', 'cm-md-h5', 'cm-md-h6']

const WIKILINK_RE = /(!?)\[\[([^[\]\n]+?)\]\]/g
const TAG_RE = /(^|[^\w&`])#([A-Za-z][\w/-]*)/g
const HIGHLIGHT_RE = /==([^=\n]+)==/g
const TASK_RE = /^(\s*[-*+]\s+)\[([ xX])\]\s/

function selectionTouches(state: EditorState, from: number, to: number): boolean {
  for (const r of state.selection.ranges) {
    if (r.from <= to && r.to >= from) return true
  }
  return false
}

function lineTouched(state: EditorState, pos: number): boolean {
  const line = state.doc.lineAt(pos)
  return selectionTouches(state, line.from, line.to)
}

interface CalloutRange {
  type: string
  title: string
  foldable: boolean
  firstLine: number
  lastLine: number
  /** Character range of the `[!type]±` marker (plus any title text). */
  markerFrom: number
  markerTo: number
}

/** Every `> [!type]` block in the document, with its line extent. */
function calloutBlocks(state: EditorState, from: number): CalloutRange[] {
  const out: CalloutRange[] = []
  const startLine = from > 0 ? state.doc.lineAt(Math.min(from, state.doc.length)).number : 1
  for (let n = startLine; n <= state.doc.lines; n++) {
    const line = state.doc.line(n)
    const m = /^(>\s*)\[!([A-Za-z-]+)\]([+-]?)\s*(.*)$/.exec(line.text)
    if (!m) continue
    let last = n
    while (last + 1 <= state.doc.lines && /^>/.test(state.doc.line(last + 1).text)) last++
    const type = m[2].toLowerCase()
    out.push({
      type,
      title: m[4].trim() || type[0].toUpperCase() + type.slice(1),
      foldable: m[3] === '-' || m[3] === '+',
      firstLine: n,
      lastLine: last,
      markerFrom: line.from + m[1].length,
      markerTo: line.to,
    })
    n = last
  }
  return out
}

function buildDecorations(view: EditorView, live: boolean): DecorationSet {
  const state = view.state
  const marks: Range<Decoration>[] = []
  const host = state.field(hostField, false) ?? null
  const fmEnd = frontmatterLength(state.doc.sliceString(0, Math.min(state.doc.length, 4000)))

  const add = (from: number, to: number, deco: Decoration): void => {
    if (from > to) return
    marks.push(deco.range(from, to))
  }

  // Frontmatter. The properties table itself is a block widget, which CM only
  // accepts from a state field (`frontmatterProperties`); all this pass does is
  // dim the raw YAML for the case where the cursor is inside it.
  if (fmEnd > 0 && (!live || frontmatterEditing(state, fmEnd))) {
    const lastLine = state.doc.lineAt(Math.max(0, Math.min(fmEnd, state.doc.length) - 1))
    for (let n = 1; n <= lastLine.number; n++) {
      marks.push(Decoration.line({ class: 'cm-md-frontmatter' }).range(state.doc.line(n).from))
    }
  }

  // Callouts: a colored block, with `> [!type]` swapped for an icon + title.
  if (live) {
    for (const range of calloutBlocks(state, fmEnd)) {
      for (let n = range.firstLine; n <= range.lastLine; n++) {
        const line = state.doc.line(n)
        const cls = [
          'cm-callout',
          n === range.firstLine ? 'cm-callout-first' : '',
          n === range.lastLine ? 'cm-callout-last' : '',
        ]
          .filter(Boolean)
          .join(' ')
        marks.push(
          Decoration.line({
            class: cls,
            attributes: { style: `--callout-color:${CALLOUT_COLORS[range.type] ?? 'var(--accent)'}` },
          }).range(line.from),
        )
      }
      const head = state.doc.line(range.firstLine)
      if (!selectionTouches(state, head.from, head.to)) {
        add(
          range.markerFrom,
          range.markerTo,
          Decoration.replace({
            widget: new CalloutTitleWidget(range.type, range.title, range.foldable),
          }),
        )
      }
    }
  }

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const name = node.name
        const nodeFrom = node.from
        const nodeTo = node.to

        // ---- headings
        if (/^ATXHeading[1-6]$/.test(name)) {
          const level = Number(name.slice(-1))
          const line = state.doc.lineAt(nodeFrom)
          marks.push(
            Decoration.line({ class: `cm-md-heading ${HEADING_CLASS[level - 1]}` }).range(line.from),
          )
          return
        }
        if (name === 'HeaderMark') {
          const parent = node.node.parent
          if (live && parent && !lineTouched(state, nodeFrom)) {
            // Hide the `## ` including the following space.
            const after = state.doc.sliceString(nodeTo, nodeTo + 1)
            add(nodeFrom, after === ' ' ? nodeTo + 1 : nodeTo, HIDE)
          } else {
            add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-mark' }))
          }
          return
        }

        // ---- inline emphasis
        if (name === 'StrongEmphasis') {
          add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-bold' }))
          return
        }
        if (name === 'Emphasis') {
          add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-italic' }))
          return
        }
        if (name === 'Strikethrough') {
          add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-strike' }))
          return
        }
        if (name === 'InlineCode') {
          add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-code' }))
          return
        }
        if (
          name === 'EmphasisMark' ||
          name === 'StrikethroughMark' ||
          (name === 'CodeMark' && node.node.parent?.name === 'InlineCode')
        ) {
          const parent = node.node.parent
          const touched = parent ? selectionTouches(state, parent.from, parent.to) : true
          if (live && !touched) add(nodeFrom, nodeTo, HIDE)
          else add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-mark' }))
          return
        }

        // ---- blockquote
        if (name === 'QuoteMark') {
          if (live && !lineTouched(state, nodeFrom)) {
            const after = state.doc.sliceString(nodeTo, nodeTo + 1)
            add(nodeFrom, after === ' ' ? nodeTo + 1 : nodeTo, HIDE)
          } else {
            add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-mark' }))
          }
          return
        }
        if (name === 'Blockquote') {
          const first = state.doc.lineAt(nodeFrom).number
          const last = state.doc.lineAt(Math.min(nodeTo, state.doc.length)).number
          for (let n = first; n <= last; n++) {
            marks.push(Decoration.line({ class: 'cm-md-quote' }).range(state.doc.line(n).from))
          }
          return
        }

        // ---- lists
        if (name === 'ListMark') {
          add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-list-bullet' }))
          return
        }

        // ---- code fences
        if (name === 'FencedCode') {
          const first = state.doc.lineAt(nodeFrom).number
          const last = state.doc.lineAt(Math.min(nodeTo, state.doc.length)).number
          for (let n = first; n <= last; n++) {
            const cls =
              'cm-md-codeblock' +
              (n === first ? ' cm-md-codeblock-first' : '') +
              (n === last ? ' cm-md-codeblock-last' : '')
            marks.push(Decoration.line({ class: cls }).range(state.doc.line(n).from))
          }
          return
        }

        // ---- thematic break
        if (name === 'HorizontalRule') {
          if (live && !lineTouched(state, nodeFrom)) {
            add(nodeFrom, nodeTo, Decoration.replace({ widget: new HrWidget() }))
          }
          return
        }

        // ---- inline links [text](url) and images
        if (name === 'Image' && live && !selectionTouches(state, nodeFrom, nodeTo)) {
          const text = state.doc.sliceString(nodeFrom, nodeTo)
          const m = /^!\[([^\]]*)\]\(([^)]+)\)$/.exec(text)
          if (m && host) {
            const src = /^https?:\/\//i.test(m[2]) ? m[2] : host.imageSrc(m[2])
            if (src) {
              add(nodeFrom, nodeTo, Decoration.replace({ widget: new ImageWidget(src, m[1]) }))
              return
            }
          }
        }
        if (name === 'Link') {
          const text = state.doc.sliceString(nodeFrom, nodeTo)
          const m = /^\[([^\]]*)\]\(([^)]+)\)$/.exec(text)
          if (m && live && !selectionTouches(state, nodeFrom, nodeTo)) {
            const external = /^[a-z][a-z0-9+.-]*:/i.test(m[2])
            add(
              nodeFrom,
              nodeTo,
              Decoration.replace({
                widget: new LinkWidget(
                  m[1] || m[2],
                  m[2],
                  !external && host ? host.resolve(m[2]) === null : false,
                  external,
                ),
              }),
            )
          } else {
            add(nodeFrom, nodeTo, Decoration.mark({ class: 'cm-md-link' }))
          }
          return
        }
      },
    })

    // ---- regex passes for things the markdown grammar doesn't model:
    //      wikilinks, tags, ==highlights==, and task checkboxes.
    const text = state.doc.sliceString(from, to)

    WIKILINK_RE.lastIndex = 0
    for (let m = WIKILINK_RE.exec(text); m; m = WIKILINK_RE.exec(text)) {
      const start = from + m.index
      const end = start + m[0].length
      if (start < fmEnd) continue
      const inner = m[2]
      const bar = inner.indexOf('|')
      const target = (bar >= 0 ? inner.slice(0, bar) : inner).trim()
      const label = bar >= 0 ? inner.slice(bar + 1).trim() : target
      if (live && !selectionTouches(state, start, end)) {
        const unresolved = host ? host.resolve(target) === null : false
        add(
          start,
          end,
          Decoration.replace({
            widget: new LinkWidget(m[1] === '!' ? `📄 ${label}` : label, target, unresolved, false),
          }),
        )
      } else {
        add(start, start + 2 + m[1].length, Decoration.mark({ class: 'cm-md-mark' }))
        add(start + 2 + m[1].length, end - 2, Decoration.mark({ class: 'cm-md-wikilink' }))
        add(end - 2, end, Decoration.mark({ class: 'cm-md-mark' }))
      }
    }

    TAG_RE.lastIndex = 0
    for (let m = TAG_RE.exec(text); m; m = TAG_RE.exec(text)) {
      const start = from + m.index + m[1].length
      const end = start + 1 + m[2].length
      if (start < fmEnd) continue
      if (live && !selectionTouches(state, start, end)) {
        add(start, end, Decoration.replace({ widget: new TagWidget(m[2]) }))
      } else {
        add(start, end, Decoration.mark({ class: 'cm-md-tag' }))
      }
    }

    HIGHLIGHT_RE.lastIndex = 0
    for (let m = HIGHLIGHT_RE.exec(text); m; m = HIGHLIGHT_RE.exec(text)) {
      const start = from + m.index
      const end = start + m[0].length
      if (live && !selectionTouches(state, start, end)) {
        add(start, start + 2, HIDE)
        add(start + 2, end - 2, Decoration.mark({ class: 'cm-md-highlight' }))
        add(end - 2, end, HIDE)
      } else {
        add(start, end, Decoration.mark({ class: 'cm-md-highlight' }))
      }
    }

    // Task checkboxes, line by line over the visible range.
    const firstLine = state.doc.lineAt(from).number
    const lastLine = state.doc.lineAt(Math.min(to, state.doc.length)).number
    for (let n = firstLine; n <= lastLine; n++) {
      const line = state.doc.line(n)
      const m = TASK_RE.exec(line.text)
      if (!m) continue
      const boxFrom = line.from + m[1].length
      const boxTo = boxFrom + 3
      const done = m[2] !== ' '
      if (live && !selectionTouches(state, line.from, line.to)) {
        // Hide the `- ` bullet too: a rendered task is just its checkbox.
        const bulletFrom = line.from + (m[1].length - m[1].trimStart().length)
        add(bulletFrom, boxFrom, HIDE)
        add(boxFrom, boxTo, Decoration.replace({ widget: new CheckboxWidget(done, n - 1) }))
      }
      if (done) {
        add(boxTo + 1, line.to, Decoration.mark({ class: 'cm-md-task-done' }))
      }
    }
  }

  // `sort: true` handles the (from, startSide) ordering RangeSet requires —
  // line decorations and marks can share a start position.
  return Decoration.set(marks, true)
}

/** True when the selection sits inside the frontmatter block. */
function frontmatterEditing(state: EditorState, fmEnd: number): boolean {
  const lastLine = state.doc.lineAt(Math.max(0, Math.min(fmEnd, state.doc.length) - 1))
  return selectionTouches(state, 0, lastLine.to)
}

/**
 * The frontmatter properties table. This has to be a state field rather than
 * part of the view plugin above: CodeMirror rejects decorations that replace
 * line breaks when they come from a plugin.
 */
export const frontmatterProperties = StateField.define<DecorationSet>({
  create: (state) => buildFrontmatter(state),
  update(value, tr) {
    if (!tr.docChanged && !tr.selection) return value
    return buildFrontmatter(tr.state)
  },
  provide: (f) => EditorView.decorations.from(f),
})

function buildFrontmatter(state: EditorState): DecorationSet {
  const head = state.doc.sliceString(0, Math.min(state.doc.length, 8000))
  const fmEnd = frontmatterLength(head)
  if (fmEnd <= 0) return Decoration.none
  if (frontmatterEditing(state, fmEnd)) return Decoration.none
  const lastLine = state.doc.lineAt(Math.max(0, Math.min(fmEnd, state.doc.length) - 1))
  return Decoration.set([
    Decoration.replace({
      widget: new PropertiesWidget(state.doc.sliceString(0, Math.min(fmEnd, state.doc.length))),
      block: true,
    }).range(0, lastLine.to),
  ])
}

/** `live` = Live Preview; false = Source mode (markers stay visible). */
export function markdownDecorations(live: boolean) {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet

      constructor(view: EditorView) {
        this.decorations = buildDecorations(view, live)
      }

      update(update: ViewUpdate): void {
        if (
          update.docChanged ||
          update.selectionSet ||
          update.viewportChanged ||
          update.transactions.some((t) => t.effects.some((e) => e.is(setHost)))
        ) {
          this.decorations = buildDecorations(update.view, live)
        }
      }
    },
    {
      decorations: (v) => v.decorations,
      provide: (plugin) =>
        EditorView.atomicRanges.of((view) => view.plugin(plugin)?.decorations ?? Decoration.none),
    },
  )
}
