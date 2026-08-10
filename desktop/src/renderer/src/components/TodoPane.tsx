/**
 * Onyx's Todo checklist, persisted to `.onyx/todos.md` as an ordinary markdown
 * checklist so the TUI and the desktop app read and write the same file.
 *
 * Completed items carry a trailing `<!--done:YYYY-MM-DD-->` marker — invisible
 * in rendered markdown, but enough to group finished todos at the bottom and
 * sweep them away a week later. Port of `src/todo.rs`.
 */

import { useCallback, useEffect, useState } from 'react'
import type { GTask } from '@shared/types'
import { parseTodos, serializeTodos, sweep, today, type TodoItem } from '@shared/todo'
import { useStore } from '../store'
import { Icon } from './Icon'

const TODO_PATH = '.onyx/todos.md'

export function TodoPane(): JSX.Element {
  const [items, setItems] = useState<TodoItem[]>([])
  const [draft, setDraft] = useState('')
  const [loaded, setLoaded] = useState(false)
  const [gtasks, setGtasks] = useState<GTask[]>([])
  const [gErr, setGErr] = useState<string | null>(null)
  const [gBusy, setGBusy] = useState(false)
  const setStatus = useStore((s) => s.setStatus)
  const syncTasks = useStore((s) => s.settings?.google.syncTasks !== false)

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

  const loadGoogle = useCallback(async () => {
    if (!syncTasks) {
      setGtasks([])
      return
    }
    setGBusy(true)
    try {
      setGtasks(await window.onyx.google.tasks())
      setGErr(null)
    } catch (e) {
      const msg = (e as Error).message
      setGtasks([])
      // "Not connected" is the ordinary state, not something to shout about.
      setGErr(/not connected|no google oauth/i.test(msg) ? null : msg)
    } finally {
      setGBusy(false)
    }
  }, [syncTasks])

  useEffect(() => {
    void loadGoogle()
  }, [loadGoogle])

  const toggleGoogle = async (task: GTask): Promise<void> => {
    const next = !task.completed
    setGtasks((prev) => prev.map((t) => (t.id === task.id ? { ...t, completed: next } : t)))
    try {
      await window.onyx.google.setTaskCompleted(task.listId, task.id, next)
    } catch (e) {
      setGtasks((prev) => prev.map((t) => (t.id === task.id ? { ...t, completed: !next } : t)))
      setStatus((e as Error).message)
    }
  }

  const removeGoogle = async (task: GTask): Promise<void> => {
    const before = gtasks
    setGtasks((prev) => prev.filter((t) => t.id !== task.id))
    try {
      await window.onyx.google.deleteTask(task.listId, task.id)
    } catch (e) {
      setGtasks(before)
      setStatus((e as Error).message)
    }
  }

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

  /**
   * `g ` prefixes a new item straight into Google Tasks; anything else stays
   * local, in the vault's `.onyx/todos.md`.
   */
  const add = (): void => {
    const text = draft.trim()
    if (!text) return
    setDraft('')
    const toGoogle = /^g\s+/i.test(text)
    if (toGoogle && syncTasks) {
      const title = text.replace(/^g\s+/i, '')
      void window.onyx.google
        .createTask(title)
        .then((created) => setGtasks((prev) => [...prev, { ...created, listTitle: 'Tasks' }]))
        .catch((e: Error) => setStatus(e.message))
      return
    }
    const open = items.filter((i) => !i.done)
    const done = items.filter((i) => i.done)
    void persist([...open, { text, done: false, doneOn: null }, ...done])
  }

  const remove = (index: number): void => {
    void persist(items.filter((_, i) => i !== index))
  }

  const openCount =
    items.filter((i) => !i.done).length + gtasks.filter((t) => !t.completed).length
  const gOpen = gtasks.filter((t) => !t.completed)
  const gDone = gtasks.filter((t) => t.completed)

  return (
    <div className="mini-pane">
      
      <div className="todo-add-row">
        <input
          className="todo-add"
          placeholder={syncTasks ? 'Add a todo…  (prefix “g ” for Google)' : 'Add a todo…'}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') add()
          }}
        />
        {gBusy ? (
          <span className="spinner" />
        ) : (
          syncTasks && (
            <button
              className="icon-btn"
              title="Refresh Google Tasks"
              onClick={() => void loadGoogle()}
            >
              <Icon name="history" size={13} />
            </button>
          )
        )}
      </div>
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
      {gErr && (
        <div className="empty-note" style={{ color: 'var(--warning)' }}>
          {gErr}
        </div>
      )}
      {gtasks.length > 0 && (
        <>
          <div className="pane-title" style={{ paddingTop: 12 }}>
            <span>Google Tasks</span>
            <span style={{ color: 'var(--fg-subtle)' }}>{gOpen.length} open</span>
          </div>
          {[...gOpen, ...gDone].map((task) => (
            <div className={`todo-item${task.completed ? ' is-done' : ''}`} key={task.id}>
              <input
                type="checkbox"
                checked={task.completed}
                onChange={() => void toggleGoogle(task)}
              />
              <span className="text" title={task.notes || task.listTitle}>
                {task.title || '(untitled)'}
                {task.due && (
                  <span style={{ color: 'var(--fg-subtle)', marginLeft: 6, fontSize: 11 }}>
                    {task.due.slice(0, 10)}
                  </span>
                )}
              </span>
              <button
                className="icon-btn"
                style={{ width: 18, height: 18 }}
                title="Delete from Google Tasks"
                onClick={() => void removeGoogle(task)}
              >
                <Icon name="close" size={11} />
              </button>
            </div>
          ))}
        </>
      )}
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
    <div className="mini-pane quicknote-pane">
      <textarea
        value={text}
        placeholder="Scratch pad — autosaved to the vault"
        onChange={(e) => {
          setText(e.target.value)
          setDirty(true)
        }}
      />
      {dirty && <div className="quicknote-status">saving…</div>}
    </div>
  )
}
