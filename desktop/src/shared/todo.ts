/**
 * The Todo checklist model, kept apart from its React pane so it can be tested
 * (and so the parsing rules sit next to the other shared parsers).
 *
 * Persisted to `.onyx/todos.md` as an ordinary markdown checklist, exactly the
 * format `src/todo.rs` reads and writes: completed items carry a trailing
 * `<!--done:YYYY-MM-DD-->` marker, invisible in rendered markdown but enough to
 * group finished todos at the bottom and sweep them a week later.
 */

export interface TodoItem {
  text: string
  done: boolean
  /** `YYYY-MM-DD` the item was ticked, or null while open. */
  doneOn: string | null
}

/** How long a completed todo lingers before it's pruned. */
export const DONE_RETENTION_DAYS = 7

export function today(now = new Date()): string {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(
    now.getDate(),
  ).padStart(2, '0')}`
}

function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b) - Date.parse(a)) / 86400000)
}

export function parseTodos(content: string, now = today()): TodoItem[] {
  const out: TodoItem[] = []
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.trimStart()
    const m = /^- \[([ xX])\] (.*)$/.exec(line)
    if (!m) continue
    const done = m[1] !== ' '
    let text = m[2]
    let doneOn: string | null = null
    if (done) {
      const marker = /<!--done:(\d{4}-\d{2}-\d{2})-->\s*$/.exec(text)
      if (marker) {
        doneOn = marker[1]
        text = text.slice(0, marker.index).trimEnd()
      } else {
        // Ticked elsewhere (in the TUI, or in Obsidian) — start its week now.
        doneOn = now
      }
    }
    out.push({ text: text.trim(), done, doneOn })
  }
  return out
}

export function serializeTodos(items: TodoItem[], now = today()): string {
  const open = items.filter((i) => !i.done)
  const done = items.filter((i) => i.done)
  const lines = [
    ...open.map((i) => `- [ ] ${i.text}`),
    ...done.map((i) => `- [x] ${i.text} <!--done:${i.doneOn ?? now}-->`),
  ]
  return `${lines.join('\n')}\n`
}

/** Drop completed items that finished more than a week ago. */
export function sweep(items: TodoItem[], now = today()): TodoItem[] {
  return items.filter(
    (i) => !i.done || !i.doneOn || daysBetween(i.doneOn, now) < DONE_RETENTION_DAYS,
  )
}
