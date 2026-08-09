/**
 * Onyx's Todo checklist, persisted to `.onyx/todos.md` as an ordinary markdown
 * checklist so the TUI and the desktop app read and write the same file.
 *
 * Completed items carry a trailing `<!--done:YYYY-MM-DD-->` marker — invisible
 * in rendered markdown, but enough to group finished todos at the bottom and
 * sweep them away a week later. Port of `src/todo.rs`.
 */

import { useCallback, useEffect, useState } from 'react'
import { useStore } from '../store'
import { Icon } from './Icon'

const TODO_PATH = '.onyx/todos.md'
const DONE_RETENTION_DAYS = 7

interface TodoItem {
  text: string
  done: boolean
  /** `YYYY-MM-DD` the item was ticked, or null while open. */
  doneOn: string | null
}

function today(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b) - Date.parse(a)) / 86400000)
}

export function parseTodos(content: string): TodoItem[] {
  const out: TodoItem[] = []
  const now = today()
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
        // Ticked elsewhere (e.g. in Obsidian) — start its week now.
        doneOn = now
      }
    }
    out.push({ text: text.trim(), done, doneOn })
  }
  return out
}

export function serializeTodos(items: TodoItem[]): string {
  const open = items.filter((i) => !i.done)
  const done = items.filter((i) => i.done)
  const lines = [
    ...open.map((i) => `- [ ] ${i.text}`),
    ...done.map((i) => `- [x] ${i.text} <!--done:${i.doneOn ?? today()}-->`),
  ]
  return `${lines.join('\n')}\n`
}

/** Drop completed items that finished more than a week ago. */
export function sweep(items: TodoItem[]): TodoItem[] {
  const now = today()
  return items.filter(
    (i) => !i.done || !i.doneOn || daysBetween(i.doneOn, now) < DONE_RETENTION_DAYS,
  )
}

export function TodoPane(): JSX.Element {
  const [items, setItems] = useState<TodoItem[]>([])
  const [draft, setDraft] = useState('')
  const [loaded, setLoaded] = useState(false)
  const setStatus = useStore((s) => s.setStatus)

  useEffect(() => {
    void (async () => {
      try {
        const content = await window.onyx.file.read(TODO_PATH)
        setItems(sweep(parseTodos(content)))
      } catch {
        setItems([])
      }
      setLoaded(true)
    })()
  }, [])

  const persist = useCallback(
    async (next: TodoItem[]) => {
      setItems(next)
      try {
        await window.onyx.file.write(TODO_PATH, serializeTodos(next))
      } catch {
        setStatus("Couldn't save todos")
      }
    },
    [setStatus],
  )

  const toggle = (index: number): void => {
    const next = items.map((item, i) =>
      i === index ? { ...item, done: !item.done, doneOn: item.done ? null : today() } : item,
    )
    // Completed items sink to the bottom.
    next.sort((a, b) => Number(a.done) - Number(b.done))
    void persist(next)
  }

  const add = (): void => {
    const text = draft.trim()
    if (!text) return
    setDraft('')
    const open = items.filter((i) => !i.done)
    const done = items.filter((i) => i.done)
    void persist([...open, { text, done: false, doneOn: null }, ...done])
  }

  const remove = (index: number): void => {
    void persist(items.filter((_, i) => i !== index))
  }

  const openCount = items.filter((i) => !i.done).length

  return (
    <div className="mini-pane">
      <div className="pane-title">
        <span>Todo</span>
        <span style={{ color: 'var(--fg-subtle)' }}>{openCount} open</span>
      </div>
      <input
        className="todo-add"
        placeholder="Add a todo…"
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') add()
        }}
      />
      {loaded && !items.length && <div className="empty-note">Nothing to do. Enjoy it.</div>}
      {items.map((item, i) => (
        <div className={`todo-item${item.done ? ' is-done' : ''}`} key={`${item.text}-${i}`}>
          <input type="checkbox" checked={item.done} onChange={() => toggle(i)} />
          <span className="text">{item.text}</span>
          <button
            className="icon-btn"
            style={{ width: 18, height: 18 }}
            title="Remove"
            onClick={() => remove(i)}
          >
            <Icon name="close" size={11} />
          </button>
        </div>
      ))}
      <QuicknotePane />
    </div>
  )
}

// ------------------------------------------------------------- quicknote

const QUICKNOTE_PATH = '.onyx/quicknote.md'

export function QuicknotePane(): JSX.Element {
  const [text, setText] = useState('')
  const [dirty, setDirty] = useState(false)

  useEffect(() => {
    void window.onyx.file
      .read(QUICKNOTE_PATH)
      .then(setText)
      .catch(() => setText(''))
  }, [])

  useEffect(() => {
    if (!dirty) return
    const timer = setTimeout(() => {
      void window.onyx.file.write(QUICKNOTE_PATH, text).then(() => setDirty(false))
    }, 800)
    return () => clearTimeout(timer)
  }, [text, dirty])

  return (
    <>
      <div className="pane-title">
        <span>Quicknote</span>
        {dirty && <span style={{ color: 'var(--fg-subtle)' }}>saving…</span>}
      </div>
      <textarea
        value={text}
        placeholder="Scratch pad — autosaved to the vault"
        onChange={(e) => {
          setText(e.target.value)
          setDirty(true)
        }}
      />
    </>
  )
}
