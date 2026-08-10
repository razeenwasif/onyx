/**
 * Monthly calendar wired to daily notes, like the TUI's Ctrl-K pane, with
 * optional Google Calendar events layered on top: a dot marks a day that has
 * events, and selecting a day shows its agenda underneath.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { CalEvent } from '@shared/types'
import { useStore } from '../store'
import { Icon } from './Icon'
import { dailyNotePath, formatDate } from '../lib/notes'

const DOW = ['S', 'M', 'T', 'W', 'T', 'F', 'S']

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export function CalendarPane(): JSX.Element {
  const [cursor, setCursor] = useState(() => new Date())
  const [selected, setSelected] = useState<string | null>(null)
  const [events, setEvents] = useState<CalEvent[]>([])
  const [gErr, setGErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [adding, setAdding] = useState(false)
  const [draft, setDraft] = useState('')

  const notes = useStore((s) => s.notes)
  const settings = useStore((s) => s.settings)
  const openFile = useStore((s) => s.openFile)
  const refreshVault = useStore((s) => s.refreshVault)
  const setStatus = useStore((s) => s.setStatus)

  const folder = settings?.dailyNotes.folder ?? 'Daily'
  const format = settings?.dailyNotes.format ?? 'YYYY-MM-DD'
  const syncCalendar = settings?.google.syncCalendar !== false

  const loadEvents = useCallback(async () => {
    if (!syncCalendar) {
      setEvents([])
      return
    }
    setBusy(true)
    try {
      setEvents(await window.onyx.google.events(cursor.getFullYear(), cursor.getMonth() + 1))
      setGErr(null)
    } catch (e) {
      // Not connected is the normal case, not an error worth shouting about.
      const msg = (e as Error).message
      setEvents([])
      setGErr(/not connected|no google oauth/i.test(msg) ? null : msg)
    } finally {
      setBusy(false)
    }
  }, [cursor, syncCalendar])

  useEffect(() => {
    void loadEvents()
  }, [loadEvents])

  const days = useMemo(() => {
    const first = new Date(cursor.getFullYear(), cursor.getMonth(), 1)
    const start = new Date(first)
    start.setDate(1 - first.getDay())
    return Array.from({ length: 42 }, (_, i) => {
      const d = new Date(start)
      d.setDate(start.getDate() + i)
      return d
    })
  }, [cursor])

  const byDay = useMemo(() => {
    const map = new Map<string, CalEvent[]>()
    for (const e of events) {
      const list = map.get(e.date)
      if (list) list.push(e)
      else map.set(e.date, [e])
    }
    return map
  }, [events])

  const todayKey = new Date().toDateString()
  const agenda = selected ? (byDay.get(selected) ?? []) : []

  const openDaily = async (d: Date): Promise<void> => {
    const path = dailyNotePath(d, folder, format)
    if (!notes.has(path)) {
      await window.onyx.file.create(path, `# ${formatDate(d, format)}\n\n`)
      await refreshVault()
    }
    void openFile(path)
  }

  const addEvent = async (): Promise<void> => {
    if (!selected || !draft.trim()) return
    try {
      const created = await window.onyx.google.createEvent(selected, draft.trim())
      setEvents((prev) => [...prev, created])
      setDraft('')
      setAdding(false)
      setStatus('Event added to Google Calendar')
    } catch (e) {
      setStatus((e as Error).message)
    }
  }

  const removeEvent = async (event: CalEvent): Promise<void> => {
    try {
      await window.onyx.google.deleteEvent(event.calendarId, event.id)
      setEvents((prev) => prev.filter((e) => e.id !== event.id))
    } catch (e) {
      setStatus((e as Error).message)
    }
  }

  return (
    <div>
      
      <div className="calendar">
        <div className="calendar-head">
          <button
            className="icon-btn"
            onClick={() => setCursor(new Date(cursor.getFullYear(), cursor.getMonth() - 1, 1))}
          >
            <Icon name="chevronLeft" size={14} />
          </button>
          <span>{formatDate(cursor, 'MMMM YYYY')}</span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 2 }}>
            <button
              className="icon-btn"
              onClick={() => setCursor(new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1))}
            >
              <Icon name="chevronRight" size={14} />
            </button>
            {busy ? (
              <span className="spinner" />
            ) : (
              syncCalendar && (
                <button
                  className="icon-btn"
                  title="Refresh Google events"
                  onClick={() => void loadEvents()}
                >
                  <Icon name="history" size={13} />
                </button>
              )
            )}
          </span>
        </div>
        <div className="calendar-grid">
          {DOW.map((d, i) => (
            <div className="calendar-dow" key={i}>
              {d}
            </div>
          ))}
          {days.map((d, i) => {
            const key = ymd(d)
            const other = d.getMonth() !== cursor.getMonth()
            const has = notes.has(dailyNotePath(d, folder, format))
            const hasEvents = byDay.has(key)
            const isToday = d.toDateString() === todayKey
            return (
              <div
                key={i}
                className={[
                  'calendar-day',
                  other ? 'is-other' : '',
                  isToday ? 'is-today' : '',
                  has ? 'has-note' : '',
                  hasEvents ? 'has-events' : '',
                  selected === key ? 'is-selected' : '',
                ]
                  .filter(Boolean)
                  .join(' ')}
                onClick={() => setSelected(selected === key ? null : key)}
                onDoubleClick={() => void openDaily(d)}
                title={
                  hasEvents
                    ? `${byDay.get(key)!.length} event(s) — double-click for the daily note`
                    : 'Double-click for the daily note'
                }
              >
                {d.getDate()}
              </div>
            )
          })}
        </div>

        {gErr && (
          <div className="empty-note" style={{ color: 'var(--warning)' }}>
            {gErr}
          </div>
        )}

        {selected && (
          <div className="agenda">
            <div className="agenda-head">
              <span>{selected}</span>
              <span className="actions">
                <button
                  title="Open the daily note"
                  onClick={() => void openDaily(new Date(`${selected}T00:00:00`))}
                >
                  <Icon name="newNote" size={13} />
                </button>
                {syncCalendar && (
                  <button title="Add an event" onClick={() => setAdding(true)}>
                    <Icon name="plus" size={13} />
                  </button>
                )}
              </span>
            </div>
            {adding && (
              <input
                className="todo-add"
                autoFocus
                placeholder="Event title…"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onBlur={() => setAdding(false)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void addEvent()
                  if (e.key === 'Escape') setAdding(false)
                }}
              />
            )}
            {!agenda.length && !adding && (
              <div className="empty-note" style={{ padding: '4px 12px' }}>
                Nothing scheduled.
              </div>
            )}
            {agenda.map((e) => (
              <div className="agenda-row" key={e.id}>
                <span className="when">{e.timeLabel}</span>
                <span className="what">{e.summary}</span>
                <button
                  className="icon-btn"
                  style={{ width: 18, height: 18 }}
                  title="Delete from Google Calendar"
                  onClick={() => void removeEvent(e)}
                >
                  <Icon name="close" size={11} />
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
