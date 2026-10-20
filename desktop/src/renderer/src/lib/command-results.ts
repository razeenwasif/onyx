/**
 * What the command bar (⌘K) lists for a query: one search across notes, the
 * text inside them, handwriting in Scribe, commands and tags, plus asking the
 * vault. Pure, so the ranking can be tested without a window.
 *
 * `>` at the start lists commands only, `#` tags only.
 */

import type { NoteMeta, ScribeHit, SearchHit } from '@shared/types'
import { fuzzy } from './fuzzy'

export type CommandFilter = 'all' | 'notes' | 'ink' | 'commands' | 'tags'

export type CommandResult =
  | { kind: 'ask'; key: string; question: string }
  | { kind: 'note'; key: string; path: string; title: string; folder: string; positions: number[]; snippet?: string }
  | { kind: 'ink'; key: string; hit: ScribeHit }
  | { kind: 'command'; key: string; id: string; name: string; hotkey?: string; positions: number[] }
  | { kind: 'tag'; key: string; tag: string; count: number; positions: number[] }
  | { kind: 'create'; key: string; title: string }

export interface CommandGroup {
  title: string
  items: CommandResult[]
}

export interface CommandInputs {
  query: string
  filter: CommandFilter
  notes: Map<string, NoteMeta>
  commands: Array<{ id: string; name: string; hotkey?: string }>
  tags: Array<{ tag: string; count: number }>
  /** Full-text hits for the query (may lag the titles while they load). */
  contentHits: SearchHit[]
  /** Scribe pages matching the query (empty without Scribe). */
  inkHits: ScribeHit[]
  /** The note open now, listed last among recents. */
  current?: string | null
}

const LIMITS = { notes: 6, content: 3, ink: 4, commands: 5, tags: 4, recent: 6 }

/**
 * A query found as a run of letters in `text` beats a scattered fuzzy
 * match, and marks those letters: "eigen" in "Week 7 — Eigenvalues"
 * highlights "Eigen", not the "e" of "Week".
 */
function match(query: string, text: string): { score: number; positions: number[] } | null {
  if (!query) return { score: 0, positions: [] }
  const at = text.toLowerCase().indexOf(query.toLowerCase())
  if (at < 0) return fuzzy(query, text)
  const wordStart = at === 0 || /[\s/_\-.—]/.test(text[at - 1])
  return {
    score: 100 + query.length * 9 + (at === 0 ? 20 : wordStart ? 12 : 0) - Math.floor(text.length / 12),
    positions: Array.from({ length: query.length }, (_, i) => at + i),
  }
}

/** A line of markdown as it reads: links shown by their text. */
function plain(line: string): string {
  return line
    .replace(/!?\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]/g, (_m, target: string, alias?: string) =>
      alias ?? target.replace(/[#^].*$/, ''),
    )
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .trim()
}

function stem(path: string): string {
  return (path.split('/').pop() ?? path).replace(/\.[^.]+$/, '')
}

function folderOf(path: string): string {
  const i = path.lastIndexOf('/')
  return i < 0 ? '' : path.slice(0, i)
}

/** The groups to show, in order, each already ranked and trimmed. */
export function commandResults(input: CommandInputs): CommandGroup[] {
  let query = input.query.trim()
  let filter = input.filter
  if (query.startsWith('>')) {
    filter = 'commands'
    query = query.slice(1).trim()
  } else if (query.startsWith('#') && filter === 'all') {
    filter = 'tags'
    query = query.slice(1).trim()
  }
  const want = (f: CommandFilter): boolean => filter === 'all' || filter === f
  const groups: CommandGroup[] = []

  // Nothing typed: the notes edited last, then the most-used commands.
  if (!query) {
    if (want('notes')) {
      const recent = [...input.notes.values()]
        .sort((a, b) => b.mtime - a.mtime)
        .slice(0, LIMITS.recent)
        .map(
          (m): CommandResult => ({
            kind: 'note',
            key: `note:${m.path}`,
            path: m.path,
            title: stem(m.path),
            folder: folderOf(m.path),
            positions: [],
          }),
        )
      if (recent.length) groups.push({ title: 'Recent', items: recent })
    }
    if (want('commands')) {
      groups.push({ title: 'Commands', items: rankCommands(input.commands, '').slice(0, LIMITS.commands) })
    }
    if (filter === 'tags') groups.push({ title: 'Tags', items: rankTags(input.tags, '') })
    return groups.filter((g) => g.items.length)
  }

  if (filter === 'all') groups.push({ title: '', items: [{ kind: 'ask', key: 'ask', question: query }] })

  if (want('notes')) {
    const titled: Array<CommandResult & { kind: 'note'; score: number }> = []
    for (const [path, meta] of input.notes) {
      const title = stem(path)
      const hit = match(query, title)
      const alias = hit ? null : meta.aliases.map((a) => match(query, a)).find(Boolean)
      if (!hit && !alias) continue
      titled.push({
        kind: 'note',
        key: `note:${path}`,
        path,
        title,
        folder: folderOf(path),
        positions: hit?.positions ?? [],
        score: (hit ?? alias)!.score - (hit ? 0 : 5) + meta.mtime / 1e13,
      })
    }
    titled.sort((a, b) => b.score - a.score)
    const items: CommandResult[] = titled.slice(0, LIMITS.notes).map(({ score: _s, ...r }) => r)
    // Then notes that only match in their text, with the line that does.
    const shown = new Set(items.map((i) => i.key))
    for (const hit of input.contentHits) {
      if (items.length >= LIMITS.notes + LIMITS.content) break
      if (shown.has(`note:${hit.path}`)) continue
      items.push({
        kind: 'note',
        key: `note:${hit.path}`,
        path: hit.path,
        title: stem(hit.path),
        folder: folderOf(hit.path),
        positions: [],
        snippet: hit.matches[0] ? plain(hit.matches[0].text) : undefined,
      })
    }
    if (!titled.some((t) => t.title.toLowerCase() === query.toLowerCase())) {
      items.push({ kind: 'create', key: 'create', title: query })
    }
    groups.push({ title: 'Notes', items })
  }

  if (want('ink') && input.inkHits.length) {
    groups.push({
      title: 'Handwriting',
      items: input.inkHits.slice(0, LIMITS.ink).map((hit) => ({ kind: 'ink', key: `ink:${hit.path}`, hit })),
    })
  }

  if (want('commands')) {
    const items = rankCommands(input.commands, query).slice(0, filter === 'commands' ? 40 : LIMITS.commands)
    if (items.length) groups.push({ title: 'Commands', items })
  }

  if (want('tags')) {
    const items = rankTags(input.tags, query).slice(0, filter === 'tags' ? 40 : LIMITS.tags)
    if (items.length) groups.push({ title: 'Tags', items })
  }

  return groups.filter((g) => g.items.length)
}

function rankCommands(commands: CommandInputs['commands'], query: string): CommandResult[] {
  return commands
    .map((c) => {
      const hit = match(query, c.name)
      return hit ? { c, hit } : null
    })
    .filter((x): x is NonNullable<typeof x> => x !== null)
    .sort((a, b) => b.hit.score - a.hit.score)
    .map(({ c, hit }) => ({
      kind: 'command' as const,
      key: `command:${c.id}`,
      id: c.id,
      name: c.name,
      hotkey: c.hotkey,
      positions: hit.positions,
    }))
}

function rankTags(tags: CommandInputs['tags'], query: string): CommandResult[] {
  return tags
    .map((t) => {
      const hit = match(query, t.tag)
      return hit ? { t, hit } : null
    })
    .filter((x): x is NonNullable<typeof x> => x !== null)
    .sort((a, b) => b.hit.score - a.hit.score || b.t.count - a.t.count)
    .map(({ t, hit }) => ({ kind: 'tag' as const, key: `tag:${t.tag}`, tag: t.tag, count: t.count, positions: hit.positions }))
}

/** Every result in display order, for moving the selection with the arrows. */
export function flatten(groups: CommandGroup[]): CommandResult[] {
  return groups.flatMap((g) => g.items)
}
