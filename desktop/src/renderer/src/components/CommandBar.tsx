/**
 * The command bar (⌘K): one place to find a note, a line inside one, a page
 * of handwriting in Scribe, a command or a tag, or to ask the vault. Results
 * come from lib/command-results; this file wires them to the keyboard and to
 * what each kind of result opens.
 */

import { useEffect, useMemo, useRef, useState } from 'react'
import type { ScribeHit, SearchHit } from '@shared/types'
import { useStore } from '../store'
import { COMMANDS, runCommand } from '../commands'
import { commandResults, flatten, type CommandFilter, type CommandResult } from '../lib/command-results'
import { dirname, joinPath } from '../lib/notes'
import { Icon } from './Icon'
import { Highlight } from './Modals'

const FILTERS: Array<{ id: CommandFilter; label: string }> = [
  { id: 'all', label: 'Everything' },
  { id: 'notes', label: 'Notes' },
  { id: 'ink', label: 'Handwriting' },
  { id: 'commands', label: 'Commands' },
  { id: 'tags', label: 'Tags' },
]

export function CommandBar({ initial = '' }: { initial?: string }): JSX.Element {
  const notes = useStore((s) => s.notes)
  const scribePages = useStore((s) => s.scribePages)
  const [query, setQuery] = useState(initial)
  const [filter, setFilter] = useState<CommandFilter>('all')
  const [sel, setSel] = useState(0)
  const [tags, setTags] = useState<Array<{ tag: string; count: number }>>([])
  const [contentHits, setContentHits] = useState<SearchHit[]>([])
  const [inkHits, setInkHits] = useState<ScribeHit[]>([])
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    void window.onyx.vault.tags().then(setTags).catch(() => setTags([]))
  }, [])

  // Text inside notes and handwriting take a moment; titles show at once.
  useEffect(() => {
    const q = query.trim()
    if (!q || q.startsWith('>') || q.startsWith('#')) {
      setContentHits([])
      setInkHits([])
      return
    }
    let stale = false
    const timer = window.setTimeout(() => {
      void window.onyx.search
        .query(q)
        .then((hits) => !stale && setContentHits(hits.slice(0, 12)))
        .catch(() => undefined)
      void window.onyx.apps
        .scribeSearch(q)
        .then((hits) => !stale && setInkHits(hits))
        .catch(() => undefined)
    }, 140)
    return () => {
      stale = true
      window.clearTimeout(timer)
    }
  }, [query])

  const commands = useMemo(
    () => COMMANDS.filter((c) => c.id !== 'command:open' && (c.enabled?.() ?? true)),
    [],
  )
  const groups = useMemo(
    () =>
      commandResults({
        query,
        filter,
        notes,
        commands,
        tags,
        contentHits,
        inkHits,
        current: useStore.getState().activeTab()?.path,
      }),
    [query, filter, notes, commands, tags, contentHits, inkHits],
  )
  const items = useMemo(() => flatten(groups), [groups])

  useEffect(() => setSel(0), [query, filter])
  useEffect(() => {
    listRef.current?.querySelector('.cb-item.is-selected')?.scrollIntoView({ block: 'nearest' })
  }, [sel])

  const choose = (item: CommandResult | undefined, newTab = false): void => {
    if (!item) return
    const st = useStore.getState()
    st.setModal(null)
    switch (item.kind) {
      case 'ask':
        st.openView('ai', { state: { pending: { kind: 'ask', question: item.question } } })
        break
      case 'note':
        void st.openFile(item.path, { newTab })
        break
      case 'create': {
        const folder = dirname(st.activeTab()?.path ?? '')
        const path = joinPath(folder, `${item.title.replace(/[\\/:]/g, '-')}.md`)
        void (async () => {
          if (!st.notes.has(path)) {
            await window.onyx.file.create(path, `# ${item.title}\n\n`)
            await st.refreshVault()
          }
          await st.openFile(path, { newTab })
        })()
        break
      }
      case 'ink':
        void window.onyx.apps.scribeOpen(item.hit.path)
        break
      case 'command':
        runCommand(item.id)
        break
      case 'tag':
        st.setModal({ kind: 'search', initial: `tag:${item.tag}` })
        break
    }
  }

  const onKey = (e: React.KeyboardEvent): void => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setSel((s) => Math.min(s + 1, items.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setSel((s) => Math.max(s - 1, 0))
    } else if (e.key === 'Enter') {
      e.preventDefault()
      choose(items[sel], e.metaKey || e.ctrlKey)
    } else if (e.key === 'Tab' && !e.shiftKey) {
      // Tab hands the query to the assistant.
      const ask = items.find((i) => i.kind === 'ask')
      if (ask) {
        e.preventDefault()
        choose(ask)
      }
    }
  }

  let index = -1
  return (
    <div className="command-bar" role="dialog" aria-label="Command bar" onMouseDown={(e) => e.stopPropagation()}>
      <label className="cb-input">
        <Icon name="search" size={18} />
        <span className="sr-only">Search notes and handwriting, run a command, or ask</span>
        <input
          autoFocus
          value={query}
          placeholder="Search notes and handwriting, run a command, or ask…"
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={onKey}
          spellCheck={false}
        />
        <span className="cb-esc">esc</span>
      </label>

      <div className="cb-filters" role="group" aria-label="Show">
        {FILTERS.map((f) => (
          <button
            key={f.id}
            type="button"
            aria-pressed={filter === f.id}
            className={filter === f.id ? 'is-on' : ''}
            onClick={() => setFilter(f.id)}
          >
            {f.label}
          </button>
        ))}
      </div>

      <div className="cb-list" ref={listRef} role="listbox" aria-label="Results">
        {groups.map((g) => (
          <div key={g.title || 'top'} className="cb-group">
            {g.title && <div className="cb-group-title">{g.title}</div>}
            {g.items.map((item) => {
              index += 1
              const i = index
              return (
                <div
                  key={item.key}
                  role="option"
                  aria-selected={i === sel}
                  className={`cb-item cb-${item.kind}${i === sel ? ' is-selected' : ''}`}
                  onMouseMove={() => sel !== i && setSel(i)}
                  onClick={(e) => choose(item, e.metaKey || e.ctrlKey)}
                >
                  <ResultRow item={item} />
                </div>
              )
            })}
          </div>
        ))}
        {!items.length && <div className="cb-empty">Nothing matches “{query.trim()}”.</div>}
      </div>

      <div className="cb-footer">
        <span>↑↓ to move</span>
        <span>↵ to open</span>
        <span>⌘↵ in a new tab</span>
        <span>⇥ to ask</span>
        <span>&gt; commands · # tags</span>
        <span className="cb-spacer" />
        <span>
          {notes.size} notes{scribePages.size ? ` · ${scribePages.size} pages of ink` : ''}
        </span>
      </div>
    </div>
  )
}

function ResultRow({ item }: { item: CommandResult }): JSX.Element {
  switch (item.kind) {
    case 'ask':
      return (
        <>
          <span className="cb-icon cb-icon-ask">
            <Icon name="bot" size={16} />
          </span>
          <span className="cb-text">
            <span className="cb-title">Ask your vault about “{item.question}”</span>
            <span className="cb-sub">Answers from your notes, with sources. Runs on this Mac.</span>
          </span>
          <kbd>⇥ Tab</kbd>
        </>
      )
    case 'note':
      return (
        <>
          <span className="cb-icon">
            <Icon name="files" size={15} />
          </span>
          <span className="cb-text">
            <span className="cb-title">
              <Highlight text={item.title} positions={item.positions} />
            </span>
            <span className="cb-sub">{item.snippet ?? (item.folder || 'Vault')}</span>
          </span>
        </>
      )
    case 'create':
      return (
        <>
          <span className="cb-icon">
            <Icon name="plus" size={15} />
          </span>
          <span className="cb-text">
            <span className="cb-title">Create “{item.title}”</span>
          </span>
          <kbd>⌘↵ new tab</kbd>
        </>
      )
    case 'ink':
      return (
        <>
          <span className="cb-icon cb-icon-ink" aria-hidden="true" />
          <span className="cb-text">
            <span className="cb-title">
              {item.hit.title} <span className="cb-dim">· {item.hit.section}</span>
            </span>
            {item.hit.snippet && <span className="cb-sub">{item.hit.snippet}</span>}
          </span>
          <span className="cb-hint">opens in Scribe</span>
        </>
      )
    case 'command':
      return (
        <>
          <span className="cb-icon">
            <Icon name="target" size={15} />
          </span>
          <span className="cb-text">
            <span className="cb-title">
              <Highlight text={item.name} positions={item.positions} />
            </span>
          </span>
          {item.hotkey && <kbd>{item.hotkey}</kbd>}
        </>
      )
    case 'tag':
      return (
        <>
          <span className="cb-icon">
            <Icon name="tag" size={15} />
          </span>
          <span className="cb-text">
            <span className="cb-title">
              #<Highlight text={item.tag} positions={item.positions} />
            </span>
          </span>
          <span className="cb-hint">{item.count}</span>
        </>
      )
  }
}
