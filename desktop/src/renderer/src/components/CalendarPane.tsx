/** Monthly calendar wired to daily notes, like the TUI's Ctrl-K pane. */

import { useMemo, useState } from 'react'
import { useStore } from '../store'
import { Icon } from './Icon'
import { dailyNotePath, formatDate } from '../lib/notes'

const DOW = ['S', 'M', 'T', 'W', 'T', 'F', 'S']

export function CalendarPane(): JSX.Element {
  const [cursor, setCursor] = useState(() => new Date())
  const notes = useStore((s) => s.notes)
  const settings = useStore((s) => s.settings)
  const openFile = useStore((s) => s.openFile)
  const refreshVault = useStore((s) => s.refreshVault)

  const folder = settings?.dailyNotes.folder ?? 'Daily'
  const format = settings?.dailyNotes.format ?? 'YYYY-MM-DD'

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

  const todayKey = new Date().toDateString()

  const open = async (d: Date): Promise<void> => {
    const path = dailyNotePath(d, folder, format)
    if (!notes.has(path)) {
      await window.onyx.file.create(path, `# ${formatDate(d, format)}\n\n`)
      await refreshVault()
    }
    void openFile(path)
  }

  return (
    <div>
      <div className="pane-title">Calendar</div>
      <div className="calendar">
        <div className="calendar-head">
          <button
            className="icon-btn"
            onClick={() => setCursor(new Date(cursor.getFullYear(), cursor.getMonth() - 1, 1))}
          >
            <Icon name="chevronLeft" size={14} />
          </button>
          <span>{formatDate(cursor, 'MMMM YYYY')}</span>
          <button
            className="icon-btn"
            onClick={() => setCursor(new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1))}
          >
            <Icon name="chevronRight" size={14} />
          </button>
        </div>
        <div className="calendar-grid">
          {DOW.map((d, i) => (
            <div className="calendar-dow" key={i}>
              {d}
            </div>
          ))}
          {days.map((d, i) => {
            const other = d.getMonth() !== cursor.getMonth()
            const has = notes.has(dailyNotePath(d, folder, format))
            const isToday = d.toDateString() === todayKey
            return (
              <div
                key={i}
                className={`calendar-day${other ? ' is-other' : ''}${isToday ? ' is-today' : ''}${has ? ' has-note' : ''}`}
                onClick={() => void open(d)}
                title={formatDate(d, format)}
              >
                {d.getDate()}
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
