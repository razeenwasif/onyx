/**
 * Today: the home view, shown in a new tab and on launch when nothing is
 * open. Today's daily note to write in place, a quick capture box that adds
 * to it, this week's daily notes and events, open tasks from across the
 * vault, and the notes and handwriting edited last.
 */

import { useEffect, useMemo, useRef, useState } from 'react'
import type { CalEvent, OpenTask } from '@shared/types'
import { useStore } from '../store'
import { dailyNotePath, formatDate, relativeTime, stem, toggleTaskOnLine } from '../lib/notes'
import { Icon } from './Icon'
import { TodoPane } from './TodoPane'

const DAY_MS = 86_400_000

function greeting(d: Date): string {
  const h = d.getHours()
  if (h < 5) return 'Still up'
  if (h < 12) return 'Good morning'
  if (h < 18) return 'Good afternoon'
  return 'Good evening'
}

/** Monday to Sunday of the week holding `d`. */
function weekOf(d: Date): Date[] {
  const start = new Date(d.getFullYear(), d.getMonth(), d.getDate())
  start.setDate(start.getDate() - ((start.getDay() + 6) % 7))
  return Array.from({ length: 7 }, (_, i) => new Date(start.getTime() + i * DAY_MS))
}

/** "Monday 19 October". */
function longDate(d: Date): string {
  return `${formatDate(d, 'dddd')} ${d.getDate()} ${formatDate(d, 'MMMM')}`
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

function isoDay(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** Opens the daily note for `d`, making it first if needed. */
async function openDaily(d: Date): Promise<void> {
  const st = useStore.getState()
  const cfg = st.settings
  if (!cfg) return
  const path = dailyNotePath(d, cfg.dailyNotes.folder, cfg.dailyNotes.format)
  if (!st.notes.has(path) && !(await window.onyx.file.exists(path))) {
    await window.onyx.file.create(path, `# ${stem(path)}\n\n`)
    await st.refreshVault()
  }
  await st.openFile(path, { newTab: true })
}

export function TodayView(): JSX.Element {
  const settings = useStore((s) => s.settings)
  const [now, setNow] = useState(() => new Date())

  // Roll over at midnight if the view is left open.
  useEffect(() => {
    const t = window.setInterval(() => setNow(new Date()), 60_000)
    return () => window.clearInterval(t)
  }, [])

  if (!settings) return <div className="today" />
  const dailyPath = dailyNotePath(now, settings.dailyNotes.folder, settings.dailyNotes.format)

  return (
    <div className="today">
      <div className="today-inner">
        <div className="today-head">
          <div>
            <div className="today-date">{longDate(now)}</div>
            <h1 className="today-title">{greeting(now)}</h1>
          </div>
          <ContinueButton />
        </div>

        <div className="today-row">
          {/* Today's note, and under it what to pick up again. */}
          <div className="today-main">
            <DailyNote path={dailyPath} date={now} />
            <Recent />
          </div>
          <div className="today-side">
            <Week now={now} />
            <section className="today-card today-todo" aria-label="To do">
              <div className="today-card-head">
                <h2>To do</h2>
              </div>
              <TodoPane />
            </section>
            <Tasks />
          </div>
        </div>
      </div>
    </div>
  )
}

/** "Continue <the note read last>", when there is one. */
function ContinueButton(): JSX.Element | null {
  const last = useStore((s) => s.lastNotePath)
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  if (!last || !notes.has(last)) return null
  return (
    <button type="button" className="today-continue" onClick={() => void openFile(last)}>
      Continue {stem(last)}
      <Icon name="chevronRight" size={13} />
    </button>
  )
}

// ---------------------------------------------------------- today's note

/** The daily note's text below its `# heading`, written in place. */
function DailyNote({ path, date }: { path: string; date: Date }): JSX.Element {
  const exists = useStore((s) => s.notes.has(path))
  const doc = useStore((s) => s.docs.get(path))
  const ensureDoc = useStore((s) => s.ensureDoc)
  const setDoc = useStore((s) => s.setDoc)
  const saveDoc = useStore((s) => s.saveDoc)
  const [capture, setCapture] = useState('')
  const saveTimer = useRef<number | null>(null)
  const creating = useRef(false)

  useEffect(() => {
    if (exists) void ensureDoc(path)
  }, [exists, path, ensureDoc])

  // Split off the heading so the box holds just what you write.
  const content = doc?.content ?? ''
  const head = /^# .*\n\n?/.exec(content)?.[0] ?? ''
  const body = content.slice(head.length)

  const write = async (nextBody: string): Promise<void> => {
    const st = useStore.getState()
    if (!st.notes.has(path) && !creating.current) {
      creating.current = true
      await window.onyx.file.create(path, `# ${stem(path)}\n\n${nextBody}`)
      await st.refreshVault()
      await st.ensureDoc(path)
      creating.current = false
      return
    }
    const heading = head || `# ${stem(path)}\n\n`
    setDoc(path, heading + nextBody, true)
    if (saveTimer.current) window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(() => void saveDoc(path), 700)
  }

  useEffect(
    () => () => {
      if (saveTimer.current) {
        window.clearTimeout(saveTimer.current)
        void useStore.getState().saveDoc(path)
      }
    },
    [path],
  )

  const addCapture = (): void => {
    const line = capture.trim()
    if (!line) return
    setCapture('')
    // `[]` or `[ ]` at the start makes it a task.
    const entry = /^\[ ?\]\s*/.test(line) ? `- [ ] ${line.replace(/^\[ ?\]\s*/, '')}` : `- ${line}`
    const sep = body && !body.endsWith('\n') ? '\n' : ''
    void write(`${body}${sep}${entry}\n`)
  }

  return (
    <section className="today-card today-note" aria-label="Today's note">
      <div className="today-card-head">
        <h2>Today's note</h2>
        <button type="button" className="today-link" onClick={() => void openDaily(date)}>
          {path}
        </button>
      </div>
      <textarea
        className="today-note-text"
        aria-label="Today's note"
        placeholder="Write here…"
        value={body}
        onChange={(e) => void write(e.target.value)}
      />
      <label className="today-capture">
        <Icon name="plus" size={15} />
        <span className="sr-only">Quick capture</span>
        <input
          placeholder="Capture a thought, or [] a task…"
          value={capture}
          onChange={(e) => setCapture(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              addCapture()
            }
          }}
        />
        <kbd>↵</kbd>
      </label>
    </section>
  )
}

// ------------------------------------------------------------------ week

function Week({ now }: { now: Date }): JSX.Element {
  const settings = useStore((s) => s.settings)
  const notes = useStore((s) => s.notes)
  const [events, setEvents] = useState<CalEvent[]>([])
  const days = useMemo(() => weekOf(now), [now])

  useEffect(() => {
    if (settings?.google.syncCalendar === false) return
    let stale = false
    const months = new Map<string, Date>()
    for (const d of days) months.set(`${d.getFullYear()}-${d.getMonth()}`, d)
    void Promise.all(
      [...months.values()].map((d) => window.onyx.google.events(d.getFullYear(), d.getMonth() + 1).catch(() => [])),
    ).then((all) => !stale && setEvents(all.flat()))
    return () => {
      stale = true
    }
  }, [days, settings?.google.syncCalendar])

  const today = events.filter((e) => e.date === isoDay(now))

  return (
    <section className="today-card today-week-card" aria-label="This week">
      <div className="today-card-head">
        <h2>This week</h2>
        <button type="button" className="today-link" onClick={() => useStore.getState().showContext('calendar')}>
          Month
        </button>
      </div>
      <div className="today-week">
        {days.map((d) => {
          const path = settings ? dailyNotePath(d, settings.dailyNotes.folder, settings.dailyNotes.format) : ''
          const hasNote = notes.has(path)
          const hasEvent = events.some((e) => e.date === isoDay(d))
          return (
            <button
              key={d.toISOString()}
              type="button"
              className={`today-day${sameDay(d, now) ? ' is-today' : ''}`}
              onClick={() => void openDaily(d)}
              aria-label={`${longDate(d)}${hasNote ? ', has a note' : ''}${hasEvent ? ', has events' : ''}`}
            >
              <span className="today-day-name">{formatDate(d, 'ddd')}</span>
              <span className="today-day-num">{d.getDate()}</span>
              <span className="today-day-marks" aria-hidden="true">
                {hasNote && <span className="mark-note" />}
                {hasEvent && <span className="mark-event" />}
              </span>
            </button>
          )
        })}
      </div>
      {today.length > 0 && (
        <ul className="today-events">
          {today.map((e) => (
            <li key={e.id}>
              <span>{e.allDay ? 'All day' : e.timeLabel}</span>
              {e.summary}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

// ----------------------------------------------------------------- tasks

function Tasks(): JSX.Element {
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const [tasks, setTasks] = useState<OpenTask[] | null>(null)

  useEffect(() => {
    let stale = false
    void window.onyx.search
      .tasks()
      .then((t) => !stale && setTasks(t))
      .catch(() => setTasks([]))
    return () => {
      stale = true
    }
  }, [notes])

  // Ticking writes the note; the list refreshes when the vault reports it.
  const tick = async (task: OpenTask): Promise<void> => {
    setTasks((t) => t?.filter((x) => !(x.path === task.path && x.line === task.line)) ?? null)
    const st = useStore.getState()
    const open = st.docs.get(task.path)
    const content = open?.content ?? (await window.onyx.file.read(task.path))
    const next = toggleTaskOnLine(content, task.line)
    if (open) {
      st.setDoc(task.path, next, true)
      await st.saveDoc(task.path)
    } else {
      await window.onyx.file.write(task.path, next)
    }
  }

  const shown = tasks?.slice(0, 8) ?? []
  return (
    <section className="today-card today-tasks-card" aria-label="Open tasks">
      <div className="today-card-head">
        <h2>Tasks across the vault</h2>
        <span className="today-dim">{tasks ? `${tasks.length} open` : '…'}</span>
      </div>
      {tasks && !tasks.length && <div className="today-dim today-pad">Nothing open. Add one with [] above.</div>}
      <ul className="today-tasks">
        {shown.map((t) => (
          <li key={`${t.path}:${t.line}`}>
            <input type="checkbox" aria-label={`Done: ${t.text}`} onChange={() => void tick(t)} />
            <span className="today-task-text">{t.text}</span>
            <button type="button" className="today-task-note" onClick={() => void openFile(t.path)}>
              {stem(t.path)}
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

// ---------------------------------------------------------------- recent

type RecentFilter = 'all' | 'notes' | 'ink'

function Recent(): JSX.Element {
  const notes = useStore((s) => s.notes)
  const scribePages = useStore((s) => s.scribePages)
  const openFile = useStore((s) => s.openFile)
  const [filter, setFilter] = useState<RecentFilter>('all')

  const items = useMemo(() => {
    const recentNotes = [...notes.values()]
      .filter((m) => !m.path.startsWith('.onyx/'))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, 8)
      .map((m) => ({ kind: 'note' as const, at: m.mtime, meta: m }))
    const recentInk = [...scribePages.values()]
      .sort((a, b) => b.modified - a.modified)
      .slice(0, 8)
      .map((p) => ({ kind: 'ink' as const, at: p.modified * 1000, page: p }))
    const pool = filter === 'notes' ? recentNotes : filter === 'ink' ? recentInk : [...recentNotes, ...recentInk]
    return pool.sort((a, b) => b.at - a.at).slice(0, 8)
  }, [notes, scribePages, filter])

  return (
    <section aria-label="Recent" className="today-recent">
      <div className="today-card-head">
        <h2>Pick up where you left off</h2>
        <div className="today-filter" role="group" aria-label="Show">
          {(['all', 'notes', 'ink'] as RecentFilter[]).map((f) => (
            <button
              key={f}
              type="button"
              aria-pressed={filter === f}
              className={filter === f ? 'is-on' : ''}
              onClick={() => setFilter(f)}
            >
              {f === 'all' ? 'All' : f === 'notes' ? 'Notes' : 'Ink'}
            </button>
          ))}
        </div>
      </div>
      <div className="today-tiles">
        {items.map((item) =>
          item.kind === 'note' ? (
            <button key={item.meta.path} type="button" className="today-tile" onClick={() => void openFile(item.meta.path)}>
              <span className="today-tile-kind">Note{item.meta.path.includes('/') ? ` · ${item.meta.path.split('/')[0]}` : ''}</span>
              <span className="today-tile-title">{stem(item.meta.path)}</span>
              <span className="today-tile-when">Edited {relativeTime(item.at)}</span>
            </button>
          ) : (
            <button
              key={item.page.id}
              type="button"
              className="today-tile is-ink"
              onClick={() => void window.onyx.apps.scribeOpen(item.page.path)}
            >
              <span className="today-tile-kind">Ink · {item.page.section}</span>
              <span className="today-tile-title">{item.page.title}</span>
              <span className="today-tile-when">Written {relativeTime(item.at)}</span>
            </button>
          ),
        )}
        {!items.length && <div className="today-dim">Nothing here yet.</div>}
      </div>
    </section>
  )
}
