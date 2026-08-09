/** Quick switcher, command palette, search modal, settings, prompt, confirm. */

import { useEffect, useMemo, useRef, useState } from 'react'
import { useStore } from '../store'
import { COMMANDS } from '../commands'
import { Icon } from './Icon'
import { SearchPane } from './LeftSidebar'
import { Settings } from './Settings'
import { stem } from '../lib/notes'

/** Same scorer as the main process's, kept here so the list filters locally. */
function fuzzy(needle: string, haystack: string): { score: number; positions: number[] } | null {
  if (!needle) return { score: 0, positions: [] }
  const n = needle.toLowerCase()
  const h = haystack.toLowerCase()
  const positions: number[] = []
  let score = 0
  let hi = 0
  let last = -2
  for (const c of n) {
    const found = h.indexOf(c, hi)
    if (found < 0) return null
    positions.push(found)
    let bonus = 1
    if (found === last + 1) bonus += 8
    if (found === 0) bonus += 10
    else if (/[\s/_\-.]/.test(haystack[found - 1])) bonus += 7
    score += bonus
    last = found
    hi = found + 1
  }
  return { score: score - Math.floor(haystack.length / 12) - Math.floor(positions[0] / 4), positions }
}

function Highlight({ text, positions }: { text: string; positions: number[] }): JSX.Element {
  if (!positions.length) return <>{text}</>
  const set = new Set(positions)
  return (
    <>
      {[...text].map((c, i) => (set.has(i) ? <mark key={i}>{c}</mark> : <span key={i}>{c}</span>))}
    </>
  )
}

export function Modals(): JSX.Element | null {
  const modal = useStore((s) => s.modal)
  const setModal = useStore((s) => s.setModal)

  useEffect(() => {
    if (!modal) return
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        setModal(null)
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [modal, setModal])

  if (!modal) return null

  return (
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && setModal(null)}>
      {modal.kind === 'switcher' && <QuickSwitcher />}
      {modal.kind === 'palette' && <CommandPalette />}
      {modal.kind === 'search' && (
        <div className="modal wide">
          <SearchPane initial={modal.initial} />
        </div>
      )}
      {modal.kind === 'settings' && <Settings />}
      {modal.kind === 'prompt' && (
        <PromptModal title={modal.title} initial={modal.value} onSubmit={modal.onSubmit} />
      )}
      {modal.kind === 'confirm' && (
        <ConfirmModal title={modal.title} body={modal.body} onConfirm={modal.onConfirm} />
      )}
    </div>
  )
}

// ---------------------------------------------------------- quick switcher

function QuickSwitcher(): JSX.Element {
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const setModal = useStore((s) => s.setModal)
  const [query, setQuery] = useState('')
  const [sel, setSel] = useState(0)

  const results = useMemo(() => {
    const items: Array<{ path: string; label: string; sub: string; score: number; positions: number[] }> = []
    for (const [path, meta] of notes) {
      const label = stem(path)
      const hit = fuzzy(query, label) ?? fuzzy(query, path)
      if (!hit) {
        const alias = meta.aliases.map((a) => fuzzy(query, a)).find(Boolean)
        if (!alias) continue
        items.push({ path, label, sub: path, score: alias.score - 5, positions: [] })
        continue
      }
      items.push({
        path,
        label,
        sub: path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '',
        score: hit.score + meta.mtime / 1e13,
        positions: hit.positions,
      })
    }
    items.sort((a, b) => b.score - a.score)
    return items.slice(0, 60)
  }, [notes, query])

  useEffect(() => setSel(0), [query])

  const choose = (i: number, newTab = false): void => {
    const hit = results[i]
    if (!hit) return
    setModal(null)
    void openFile(hit.path, { newTab })
  }

  return (
    <div className="modal" onMouseDown={(e) => e.stopPropagation()}>
      <input
        className="modal-input"
        autoFocus
        placeholder="Find or create a note…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') {
            e.preventDefault()
            setSel((s) => Math.min(s + 1, results.length - 1))
          } else if (e.key === 'ArrowUp') {
            e.preventDefault()
            setSel((s) => Math.max(s - 1, 0))
          } else if (e.key === 'Enter') {
            e.preventDefault()
            if (results.length) choose(sel, e.ctrlKey || e.metaKey)
            else if (query.trim()) {
              const path = `${query.trim()}.md`
              setModal(null)
              void window.onyx.file
                .create(path, `# ${query.trim()}\n\n`)
                .then(() => useStore.getState().refreshVault())
                .then(() => useStore.getState().openFile(path))
            }
          }
        }}
      />
      <div className="modal-list">
        {results.map((r, i) => (
          <div
            className={`modal-item${i === sel ? ' is-selected' : ''}`}
            key={r.path}
            onMouseEnter={() => setSel(i)}
            onClick={(e) => choose(i, e.ctrlKey || e.metaKey)}
          >
            <Icon name="files" size={13} />
            <span className="title">
              <Highlight text={r.label} positions={r.positions} />
            </span>
            <span className="subtitle">{r.sub}</span>
          </div>
        ))}
        {!results.length && (
          <div className="modal-empty">
            {query.trim() ? `Press Enter to create "${query.trim()}"` : 'Type to search notes'}
          </div>
        )}
      </div>
    </div>
  )
}

// --------------------------------------------------------- command palette

function CommandPalette(): JSX.Element {
  const setModal = useStore((s) => s.setModal)
  const [query, setQuery] = useState('')
  const [sel, setSel] = useState(0)

  const results = useMemo(() => {
    const items = COMMANDS.map((c) => {
      const hit = fuzzy(query, c.name)
      return hit ? { cmd: c, ...hit } : null
    }).filter(Boolean) as Array<{ cmd: (typeof COMMANDS)[number]; score: number; positions: number[] }>
    items.sort((a, b) => b.score - a.score)
    return items
  }, [query])

  useEffect(() => setSel(0), [query])

  const choose = (i: number): void => {
    const hit = results[i]
    if (!hit) return
    setModal(null)
    void hit.cmd.run()
  }

  return (
    <div className="modal" onMouseDown={(e) => e.stopPropagation()}>
      <input
        className="modal-input"
        autoFocus
        placeholder="Type a command…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') {
            e.preventDefault()
            setSel((s) => Math.min(s + 1, results.length - 1))
          } else if (e.key === 'ArrowUp') {
            e.preventDefault()
            setSel((s) => Math.max(s - 1, 0))
          } else if (e.key === 'Enter') {
            e.preventDefault()
            choose(sel)
          }
        }}
      />
      <div className="modal-list">
        {results.map((r, i) => (
          <div
            className={`modal-item${i === sel ? ' is-selected' : ''}`}
            key={r.cmd.id}
            onMouseEnter={() => setSel(i)}
            onClick={() => choose(i)}
          >
            <span className="title">
              <Highlight text={r.cmd.name} positions={r.positions} />
            </span>
            {r.cmd.hotkey && <span className="hotkey">{r.cmd.hotkey}</span>}
          </div>
        ))}
        {!results.length && <div className="modal-empty">No matching commands</div>}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------ small

function PromptModal({
  title,
  initial,
  onSubmit,
}: {
  title: string
  initial: string
  onSubmit: (v: string) => void
}): JSX.Element {
  const setModal = useStore((s) => s.setModal)
  const [value, setValue] = useState(initial)
  const ref = useRef<HTMLInputElement>(null)

  useEffect(() => {
    ref.current?.select()
  }, [])

  const submit = (): void => {
    setModal(null)
    onSubmit(value)
  }

  return (
    <div className="modal" style={{ maxHeight: 'none' }} onMouseDown={(e) => e.stopPropagation()}>
      <div style={{ padding: '14px 16px 0', fontWeight: 600 }}>{title}</div>
      <input
        ref={ref}
        className="modal-input"
        autoFocus
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => e.key === 'Enter' && submit()}
      />
      <div className="modal-footer">
        <button className="btn" onClick={() => setModal(null)}>
          Cancel
        </button>
        <button className="btn primary" onClick={submit}>
          OK
        </button>
      </div>
    </div>
  )
}

function ConfirmModal({
  title,
  body,
  onConfirm,
}: {
  title: string
  body: string
  onConfirm: () => void
}): JSX.Element {
  const setModal = useStore((s) => s.setModal)
  return (
    <div className="modal" style={{ maxHeight: 'none' }} onMouseDown={(e) => e.stopPropagation()}>
      <div style={{ padding: '16px 18px 4px', fontWeight: 600, fontSize: 15 }}>{title}</div>
      <div style={{ padding: '0 18px 16px', color: 'var(--fg-dim)' }}>{body}</div>
      <div className="modal-footer">
        <button className="btn" onClick={() => setModal(null)}>
          Cancel
        </button>
        <button
          className="btn danger"
          autoFocus
          onClick={() => {
            setModal(null)
            onConfirm()
          }}
        >
          Confirm
        </button>
      </div>
    </div>
  )
}
