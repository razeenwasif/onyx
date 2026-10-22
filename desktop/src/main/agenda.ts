/**
 * The Google agenda, shared with the iPad through the vault.
 *
 * The iPad can't use the Mac's Google sign-in, so the Mac does the talking:
 * whenever Electron syncs Google, it writes the coming weeks' events and
 * the open Google Tasks to `.onyx/agenda.json`, which iCloud Drive carries
 * to the iPad's Today. Tasks ticked on the iPad are queued in
 * `.onyx/agenda-actions.json`; the Mac applies them on its next sync and
 * clears the queue. The file is rewritten only when something in it changed,
 * so iCloud isn't kept busy.
 */

import * as google from './google.js'
import type { Vault } from './vault.js'

export const AGENDA_PATH = '.onyx/agenda.json'
export const ACTIONS_PATH = '.onyx/agenda-actions.json'

export interface AgendaEvent {
  date: string
  timeLabel: string
  allDay: boolean
  summary: string
}

export interface AgendaTask {
  id: string
  listId: string
  listTitle: string
  title: string
  due: string | null
}

export interface Agenda {
  /** When the Mac last synced (ISO time). */
  updated: string
  events: AgendaEvent[]
  tasks: AgendaTask[]
}

/** Something done on the iPad, for the Mac to carry out. */
export interface AgendaAction {
  op: 'complete'
  listId: string
  taskId: string
}

const STAMP_EVERY = 6 * 60 * 60 * 1000

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** The days the agenda covers: a week back to three weeks ahead. */
export function agendaRange(now = new Date()): { from: string; to: string; months: Array<[number, number]> } {
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 7)
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 21)
  const months: Array<[number, number]> = []
  for (let d = new Date(start.getFullYear(), start.getMonth(), 1); d <= end; d = new Date(d.getFullYear(), d.getMonth() + 1, 1)) {
    months.push([d.getFullYear(), d.getMonth() + 1])
  }
  return { from: ymd(start), to: ymd(end), months }
}

/** The agenda's content, without its time stamp, to tell whether it changed. */
export function agendaBody(events: AgendaEvent[], tasks: AgendaTask[]): string {
  return JSON.stringify({ events, tasks })
}

/**
 * Applies queued iPad actions, fetches the agenda and writes it if it
 * changed. Quietly does nothing when Google isn't connected.
 */
export async function syncAgenda(
  vault: Vault,
  creds: google.GoogleCredentials,
  opts: { calendar: boolean; tasks: boolean },
): Promise<void> {
  if (!(await google.loadToken())) return

  // Ticks from the iPad first, so the fetch below already shows them done.
  let actions: AgendaAction[] = []
  try {
    actions = JSON.parse(await vault.read(ACTIONS_PATH)) as AgendaAction[]
  } catch {
    /* no queue */
  }
  if (actions.length) {
    for (const a of actions) {
      if (a.op === 'complete') {
        try {
          await google.setTaskCompleted(creds, a.listId, a.taskId, true)
        } catch {
          /* the task is gone; drop it */
        }
      }
    }
    await vault.write(ACTIONS_PATH, '[]\n')
  }

  const range = agendaRange()
  const events: AgendaEvent[] = []
  if (opts.calendar) {
    for (const [y, m] of range.months) {
      for (const e of await google.fetchMonth(creds, y, m)) {
        if (e.date >= range.from && e.date <= range.to) {
          events.push({ date: e.date, timeLabel: e.timeLabel, allDay: e.allDay, summary: e.summary })
        }
      }
    }
    events.sort((a, b) => a.date.localeCompare(b.date) || a.timeLabel.localeCompare(b.timeLabel))
  }
  const tasks: AgendaTask[] = opts.tasks
    ? (await google.fetchTasks(creds))
        .filter((t) => !t.completed && t.title.trim())
        .map((t) => ({ id: t.id, listId: t.listId, listTitle: t.listTitle, title: t.title, due: t.due }))
    : []

  let previous = ''
  let age = Infinity
  try {
    const old = JSON.parse(await vault.read(AGENDA_PATH)) as Agenda
    previous = agendaBody(old.events, old.tasks)
    age = Date.now() - Date.parse(old.updated)
  } catch {
    /* first sync */
  }
  // Unchanged: leave the file be, but refresh its stamp now and then so the
  // iPad can tell the Mac is still syncing.
  if (previous === agendaBody(events, tasks) && age < STAMP_EVERY) return
  const agenda: Agenda = { updated: new Date().toISOString(), events, tasks }
  await vault.write(AGENDA_PATH, JSON.stringify(agenda, null, 1) + '\n')
}
