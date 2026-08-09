/**
 * Editor autocompletes: `[[wikilinks]]`, `#tags`, and the `/` slash menu.
 * Ported from the TUI's inline pickers so the same triggers work in both.
 */

import type { Completion, CompletionContext, CompletionResult } from '@codemirror/autocomplete'
import type { EditorView } from '@codemirror/view'
import { useStore } from '../store'
import { stem } from '../lib/notes'

/** `[[` … — every note by name, alias and folder path. */
export function wikilinkCompletion(context: CompletionContext): CompletionResult | null {
  const before = context.matchBefore(/\[\[[^[\]\n]*/)
  if (!before) return null
  if (before.from === before.to && !context.explicit) return null

  const typed = before.text.slice(2)
  const notes = useStore.getState().notes
  const options: Completion[] = []

  for (const [path, meta] of notes) {
    const name = stem(path)
    const folder = path.split('/').slice(0, -1).join('/')
    options.push({
      label: name,
      detail: folder || undefined,
      apply: (view: EditorView, _c: Completion, from: number, to: number) => {
        // Prefer the bare name; fall back to the folder path when ambiguous.
        const sameName = [...notes.keys()].filter((p) => stem(p) === name)
        const target = sameName.length > 1 ? path.replace(/\.md$/i, '') : name
        view.dispatch({
          changes: { from, to, insert: `${target}]]` },
          selection: { anchor: from + target.length + 2 },
        })
      },
      boost: meta.mtime / 1e12,
    })
    for (const alias of meta.aliases) {
      options.push({
        label: alias,
        detail: `alias · ${name}`,
        apply: `${alias}]]`,
      })
    }
  }

  return {
    from: before.from + 2,
    to: before.to,
    options,
    filter: true,
    validFor: /^[^[\]\n]*$/,
    // Keep the list responsive on big vaults.
    update: undefined as never,
  } as CompletionResult
}

/** `#` … — every tag already in the vault. */
export function tagCompletion(context: CompletionContext): CompletionResult | null {
  const before = context.matchBefore(/(?:^|\s)#[\w/-]*/)
  if (!before) return null
  const at = before.text.indexOf('#')
  const from = before.from + at + 1
  if (from === before.to && !context.explicit) return null

  const counts = new Map<string, number>()
  for (const meta of useStore.getState().notes.values()) {
    for (const t of meta.tags) counts.set(t, (counts.get(t) ?? 0) + 1)
  }
  return {
    from,
    to: before.to,
    options: [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([tag, n]) => ({ label: tag, detail: `${n}`, type: 'keyword' })),
    validFor: /^[\w/-]*$/,
  }
}

interface SlashItem {
  label: string
  detail: string
  /** Text inserted in place of the `/query`; `|` marks the caret. */
  insert: string
}

const SLASH_ITEMS: SlashItem[] = [
  { label: 'Heading 1', detail: 'block', insert: '# |' },
  { label: 'Heading 2', detail: 'block', insert: '## |' },
  { label: 'Heading 3', detail: 'block', insert: '### |' },
  { label: 'Bullet list', detail: 'block', insert: '- |' },
  { label: 'Numbered list', detail: 'block', insert: '1. |' },
  { label: 'Task', detail: 'block', insert: '- [ ] |' },
  { label: 'Quote', detail: 'block', insert: '> |' },
  { label: 'Code block', detail: 'block', insert: '```\n|\n```' },
  { label: 'Table', detail: 'block', insert: '| Column | Column |\n| --- | --- |\n| | |' },
  { label: 'Divider', detail: 'block', insert: '---\n|' },
  { label: 'Callout: note', detail: 'callout', insert: '> [!note]\n> |' },
  { label: 'Callout: tip', detail: 'callout', insert: '> [!tip]\n> |' },
  { label: 'Callout: warning', detail: 'callout', insert: '> [!warning]\n> |' },
  { label: 'Callout: danger', detail: 'callout', insert: '> [!danger]\n> |' },
  { label: 'Callout: info', detail: 'callout', insert: '> [!info]\n> |' },
  { label: 'Callout: quote', detail: 'callout', insert: '> [!quote]\n> |' },
  { label: 'Callout (collapsible)', detail: 'callout', insert: '> [!note]- Title\n> |' },
  { label: 'Columns', detail: 'layout', insert: '::: columns\n|\n+++\n\n:::' },
  { label: 'Internal link', detail: 'link', insert: '[[|]]' },
  { label: 'Embed note', detail: 'link', insert: '![[|]]' },
  { label: 'Math block', detail: 'math', insert: '$$\n|\n$$' },
  { label: 'Frontmatter', detail: 'meta', insert: '---\ntags: []\n---\n|' },
]

/** `/` at the start of a line — Onyx's slash menu. */
export function slashCompletion(context: CompletionContext): CompletionResult | null {
  const before = context.matchBefore(/^\s*\/[\w ]*/)
  if (!before) return null
  const at = before.text.indexOf('/')
  const from = before.from + at

  return {
    from,
    to: before.to,
    options: SLASH_ITEMS.map((item) => ({
      label: item.label,
      detail: item.detail,
      apply: (view: EditorView, _c: Completion, f: number, t: number) => {
        const caret = item.insert.indexOf('|')
        const text = item.insert.replace('|', '')
        view.dispatch({
          changes: { from: f, to: t, insert: text },
          selection: { anchor: f + (caret < 0 ? text.length : caret) },
        })
      },
    })),
    validFor: /^\/[\w ]*$/,
  }
}
