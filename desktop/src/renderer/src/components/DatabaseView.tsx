/**
 * Database views — a folder of notes rendered as a Notion-style table or
 * kanban board keyed by frontmatter properties. Port of `src/db_view.rs`.
 */

import { useMemo, useState } from 'react'
import { useStore, type Tab } from '../store'
import { Icon } from './Icon'
import { splitFrontmatter, stem, withFrontmatter } from '../lib/notes'

type Mode = 'table' | 'board'

export function DatabaseView({ tab }: { tab: Tab }): JSX.Element {
  const folder = tab.path ?? ''
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const [mode, setMode] = useState<Mode>((tab.state.mode as Mode) ?? 'table')
  const [sortKey, setSortKey] = useState<string>('Name')
  const [sortAsc, setSortAsc] = useState(true)
  const [filter, setFilter] = useState('')
  const [groupBy, setGroupBy] = useState<string>('')

  const rows = useMemo(() => {
    const prefix = folder ? `${folder}/` : ''
    return [...notes.values()].filter(
      (n) => n.path.startsWith(prefix) && !n.path.slice(prefix.length).includes('/'),
    )
  }, [notes, folder])

  const columns = useMemo(() => {
    const seen: string[] = []
    for (const row of rows) {
      for (const [k] of row.properties) if (!seen.includes(k)) seen.push(k)
    }
    return seen
  }, [rows])

  const groupKey = groupBy || columns[0] || ''

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    const list = q
      ? rows.filter(
          (r) =>
            r.title.toLowerCase().includes(q) ||
            r.path.toLowerCase().includes(q) ||
            r.properties.some(([, vs]) => vs.some((v) => v.toLowerCase().includes(q))),
        )
      : rows
    const value = (r: (typeof rows)[number], key: string): string =>
      key === 'Name'
        ? r.title
        : key === 'Modified'
          ? String(r.mtime)
          : (r.properties.find(([k]) => k === key)?.[1].join(', ') ?? '')
    return [...list].sort((a, b) => {
      const av = value(a, sortKey)
      const bv = value(b, sortKey)
      const cmp = sortKey === 'Modified' ? Number(av) - Number(bv) : av.localeCompare(bv)
      return sortAsc ? cmp : -cmp
    })
  }, [rows, filter, sortKey, sortAsc])

  const groups = useMemo(() => {
    const map = new Map<string, typeof filtered>()
    for (const row of filtered) {
      const raw = row.properties.find(([k]) => k === groupKey)?.[1] ?? []
      const key = raw.length ? raw[0] : '—'
      const list = map.get(key)
      if (list) list.push(row)
      else map.set(key, [row])
    }
    return [...map.entries()].sort((a, b) => a[0].localeCompare(b[0]))
  }, [filtered, groupKey])

  /** Move a card between board columns by rewriting its frontmatter. */
  const setProperty = async (path: string, key: string, value: string): Promise<void> => {
    const content = await window.onyx.file.read(path)
    const { frontmatter, body } = splitFrontmatter(content)
    const lines = (frontmatter ?? '').split('\n').filter(Boolean)
    const idx = lines.findIndex((l) => l.split(':')[0].trim() === key)
    const line = `${key}: ${value}`
    if (idx >= 0) lines[idx] = line
    else lines.push(line)
    await window.onyx.file.write(path, withFrontmatter(lines.join('\n'), body))
    await useStore.getState().refreshVault()
  }

  const header = (key: string): JSX.Element => (
    <th
      key={key}
      onClick={() => {
        if (sortKey === key) setSortAsc(!sortAsc)
        else {
          setSortKey(key)
          setSortAsc(true)
        }
      }}
    >
      {key} {sortKey === key ? (sortAsc ? '▲' : '▼') : ''}
    </th>
  )

  return (
    <div className="db-view">
      <div className="db-toolbar">
        <strong>{folder || useStore.getState().vault?.name}</strong>
        <span style={{ color: 'var(--fg-subtle)' }}>{filtered.length} notes</span>
        <div style={{ flex: 1 }} />
        <input placeholder="Filter…" value={filter} onChange={(e) => setFilter(e.target.value)} />
        {mode === 'board' && (
          <select value={groupKey} onChange={(e) => setGroupBy(e.target.value)}>
            {columns.map((c) => (
              <option key={c} value={c}>
                Group by {c}
              </option>
            ))}
          </select>
        )}
        <button
          className={`icon-btn${mode === 'table' ? ' is-active' : ''}`}
          onClick={() => setMode('table')}
          title="Table"
        >
          <Icon name="list" size={14} />
        </button>
        <button
          className={`icon-btn${mode === 'board' ? ' is-active' : ''}`}
          onClick={() => setMode('board')}
          title="Board"
        >
          <Icon name="canvas" size={14} />
        </button>
      </div>

      {!rows.length && (
        <div className="empty-note">
          No notes directly inside this folder. Open a folder from the file explorer's context menu
          ("Open as database").
        </div>
      )}

      {mode === 'table' && rows.length > 0 && (
        <table className="db-table">
          <thead>
            <tr>
              {header('Name')}
              {columns.map(header)}
              {header('Modified')}
            </tr>
          </thead>
          <tbody>
            {filtered.map((row) => (
              <tr key={row.path} onClick={() => void openFile(row.path)}>
                <td style={{ color: 'var(--wikilink)' }}>{row.title || stem(row.path)}</td>
                {columns.map((c) => (
                  <td key={c}>{row.properties.find(([k]) => k === c)?.[1].join(', ') ?? ''}</td>
                ))}
                <td style={{ color: 'var(--fg-subtle)' }}>
                  {new Date(row.mtime).toLocaleDateString()}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {mode === 'board' && rows.length > 0 && (
        <div className="board">
          {groups.map(([key, items]) => (
            <div
              className="board-col"
              key={key}
              onDragOver={(e) => e.preventDefault()}
              onDrop={(e) => {
                const path = e.dataTransfer.getData('text/onyx-path')
                if (path && key !== '—') void setProperty(path, groupKey, key)
              }}
            >
              <div className="board-col-title">
                <span>{key}</span>
                <span>{items.length}</span>
              </div>
              {items.map((row) => (
                <div
                  className="board-card"
                  key={row.path}
                  draggable
                  onDragStart={(e) => e.dataTransfer.setData('text/onyx-path', row.path)}
                  onClick={() => void openFile(row.path)}
                >
                  <div>{row.title || stem(row.path)}</div>
                  {row.tags.length > 0 && (
                    <div className="meta">{row.tags.map((t) => `#${t}`).join(' ')}</div>
                  )}
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
