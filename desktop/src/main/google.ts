/**
 * Google Calendar + Tasks, ported from `src/integrations/{oauth,gcal,gtasks}.rs`.
 *
 * Deliberately shares the TUI's credentials and token cache: client id/secret
 * come from `[google]` in `~/.config/onyx/config.toml` (or the desktop's own
 * settings), and the token lives in the same `~/.config/onyx/google.json` at
 * mode 600. Authorize in either app and the other one is already signed in.
 *
 * The flow is the installed-app loopback one: spin an ephemeral listener on
 * 127.0.0.1, open the system browser to Google's consent page, catch the
 * redirect, exchange the code. No client secret ever leaves this process.
 */

import { promises as fs } from 'node:fs'
import * as fsSync from 'node:fs'
import * as http from 'node:http'
import * as path from 'node:path'
import { shell } from 'electron'

import { configDir } from './settings.js'

const AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth'
const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
const CALENDAR_API = 'https://www.googleapis.com/calendar/v3'
const TASKS_API = 'https://tasks.googleapis.com/tasks/v1'

/** Same scopes the TUI asks for, so one consent covers both apps. */
export const SCOPES = [
  'https://www.googleapis.com/auth/tasks',
  'https://www.googleapis.com/auth/calendar',
  'https://www.googleapis.com/auth/drive',
].join(' ')

export interface OAuthToken {
  access_token: string
  refresh_token: string
  /** Unix seconds at which `access_token` expires. */
  expires_at: number
  scope: string
  token_type: string
}

export interface GoogleCredentials {
  clientId: string
  clientSecret: string
  /** Where the credentials came from, for the settings UI. */
  source: 'config.toml' | 'desktop' | 'none'
}

export function tokenPath(): string {
  return path.join(configDir(), 'google.json')
}

function nowUnix(): number {
  return Math.floor(Date.now() / 1000)
}

// ------------------------------------------------------------ credentials

/**
 * Read `[google]` out of the TUI's config.toml. A tiny targeted reader rather
 * than a TOML dependency: we only ever need two string keys from one table,
 * and the desktop app must never rewrite that file.
 */
export function parseGoogleTable(raw: string): { clientId: string; clientSecret: string } {
  // Everything between `[google]` and the next table header (or EOF).
  // Note `$(?![\s\S])` for end-of-input: JavaScript has no `\Z`, and using one
  // matches a literal "Z" — which silently truncates the section at the first
  // capital Z inside a client secret.
  const table = /^\[google\][ \t]*\r?\n([\s\S]*?)(?=^\[|$(?![\s\S]))/m.exec(raw)
  const body = table ? table[1] : ''
  const read = (key: string): string => {
    const m = new RegExp(`^\\s*${key}\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"`, 'm').exec(body)
    return m ? m[1].replace(/\\(.)/g, '$1') : ''
  }
  return { clientId: read('client_id'), clientSecret: read('client_secret') }
}

export function credentialsFromTui(): { clientId: string; clientSecret: string } {
  try {
    return parseGoogleTable(fsSync.readFileSync(path.join(configDir(), 'config.toml'), 'utf8'))
  } catch {
    return { clientId: '', clientSecret: '' }
  }
}

/** Desktop settings win when filled in; otherwise fall back to the TUI's. */
export function resolveCredentials(desktop: {
  clientId: string
  clientSecret: string
}): GoogleCredentials {
  if (desktop.clientId.trim() && desktop.clientSecret.trim()) {
    return { clientId: desktop.clientId.trim(), clientSecret: desktop.clientSecret.trim(), source: 'desktop' }
  }
  const tui = credentialsFromTui()
  if (tui.clientId && tui.clientSecret) {
    return { clientId: tui.clientId, clientSecret: tui.clientSecret, source: 'config.toml' }
  }
  return { clientId: '', clientSecret: '', source: 'none' }
}

// ----------------------------------------------------------- token store

export async function loadToken(): Promise<OAuthToken | null> {
  try {
    return JSON.parse(await fs.readFile(tokenPath(), 'utf8')) as OAuthToken
  } catch {
    return null
  }
}

export async function saveToken(token: OAuthToken): Promise<void> {
  await fs.mkdir(configDir(), { recursive: true })
  await fs.writeFile(tokenPath(), JSON.stringify(token, null, 2), { encoding: 'utf8', mode: 0o600 })
  // The file may pre-date this write (the TUI created it) — force the mode.
  try {
    await fs.chmod(tokenPath(), 0o600)
  } catch {
    /* not POSIX */
  }
}

export async function clearToken(): Promise<void> {
  try {
    await fs.unlink(tokenPath())
  } catch {
    /* already gone */
  }
}

function needsRefresh(token: OAuthToken): boolean {
  return !token.access_token || (token.expires_at !== 0 && nowUnix() + 60 >= token.expires_at)
}

function tokenFromResponse(
  r: {
    access_token: string
    refresh_token?: string
    expires_in?: number
    scope?: string
    token_type?: string
  },
  prevRefresh: string,
): OAuthToken {
  return {
    access_token: r.access_token,
    // Google only returns the refresh token on first consent.
    refresh_token: r.refresh_token || prevRefresh,
    expires_at: nowUnix() + (r.expires_in ?? 3600),
    scope: r.scope ?? '',
    token_type: r.token_type ?? 'Bearer',
  }
}

async function postForm(body: Record<string, string>): Promise<Record<string, unknown>> {
  const res = await fetch(TOKEN_ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  })
  const json = (await res.json().catch(() => ({}))) as Record<string, unknown>
  if (!res.ok) {
    const detail = (json.error_description as string) ?? (json.error as string) ?? res.statusText
    throw new Error(`Google token endpoint ${res.status}: ${detail}`)
  }
  return json
}

// ------------------------------------------------------------ consent flow

/**
 * Interactive consent. Binds a loopback listener on an ephemeral port, opens
 * the browser, and resolves once Google redirects back with a code.
 */
export async function runConsentFlow(creds: GoogleCredentials): Promise<OAuthToken> {
  if (creds.source === 'none') {
    throw new Error(
      'No Google OAuth client configured. Add a Desktop-app client id and secret in Settings → Google (or in [google] in config.toml).',
    )
  }
  const state = `onyx${nowUnix()}`

  const { code, redirectUri } = await new Promise<{ code: string; redirectUri: string }>(
    (resolve, reject) => {
      const server = http.createServer((req, res) => {
        const url = new URL(req.url ?? '/', `http://127.0.0.1`)
        const gotCode = url.searchParams.get('code')
        const gotState = url.searchParams.get('state')
        const error = url.searchParams.get('error')
        const body = error
          ? `<html><body style="font-family:sans-serif">Authorization failed: ${error}. You can close this tab.</body></html>`
          : '<html><body style="font-family:sans-serif">Onyx is authorized — you can close this tab.</body></html>'
        res.writeHead(200, { 'Content-Type': 'text/html' })
        res.end(body)
        server.close()
        clearTimeout(timer)
        if (error) return reject(new Error(`Google returned "${error}"`))
        if (!gotCode) return reject(new Error('no authorization code in the redirect'))
        if (gotState !== state) return reject(new Error('OAuth state mismatch (possible CSRF)'))
        const address = server.address()
        const port = typeof address === 'object' && address ? address.port : 0
        resolve({ code: gotCode, redirectUri: `http://127.0.0.1:${port}` })
      })

      const timer = setTimeout(
        () => {
          server.close()
          reject(new Error('timed out waiting for Google authorization'))
        },
        5 * 60 * 1000,
      )

      server.on('error', reject)
      server.listen(0, '127.0.0.1', () => {
        const address = server.address()
        const port = typeof address === 'object' && address ? address.port : 0
        const redirect = `http://127.0.0.1:${port}`
        const url =
          `${AUTH_ENDPOINT}?client_id=${encodeURIComponent(creds.clientId)}` +
          `&redirect_uri=${encodeURIComponent(redirect)}` +
          `&response_type=code&scope=${encodeURIComponent(SCOPES)}` +
          `&access_type=offline&prompt=consent&state=${encodeURIComponent(state)}`
        void shell.openExternal(url)
      })
    },
  )

  const json = await postForm({
    code,
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    redirect_uri: redirectUri,
    grant_type: 'authorization_code',
  })
  const token = tokenFromResponse(json as never, '')
  await saveToken(token)
  return token
}

/** A valid access token, refreshing (and re-saving) when needed. */
export async function accessToken(creds: GoogleCredentials): Promise<string> {
  const token = await loadToken()
  if (!token) throw new Error('Not connected to Google — connect in Settings → Google.')
  if (!needsRefresh(token)) return token.access_token
  if (!token.refresh_token) {
    throw new Error('Google session expired and there is no refresh token — reconnect in Settings.')
  }
  if (creds.source === 'none') throw new Error('No Google OAuth client configured.')
  const json = await postForm({
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    refresh_token: token.refresh_token,
    grant_type: 'refresh_token',
  })
  const next = tokenFromResponse(json as never, token.refresh_token)
  await saveToken(next)
  return next.access_token
}

async function api<T>(url: string, at: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${at}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`Google API ${res.status}: ${text.slice(0, 200)}`)
  }
  if (res.status === 204) return undefined as T
  const text = await res.text()
  return (text ? JSON.parse(text) : undefined) as T
}

// --------------------------------------------------------------- calendar

export interface CalEvent {
  id: string
  calendarId: string
  summary: string
  /** `YYYY-MM-DD` the event starts on. */
  date: string
  allDay: boolean
  /** `all-day` or `HH:MM`, for the agenda. */
  timeLabel: string
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

function ymd(d: Date): string {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/** First of the month and first of the next — the API's timeMin/timeMax. */
export function monthBounds(year: number, month: number): [string, string] {
  const first = new Date(year, month - 1, 1)
  const next = new Date(month === 12 ? year + 1 : year, month === 12 ? 0 : month, 1)
  return [ymd(first), ymd(next)]
}

export function parseEvents(
  json: { items?: Array<Record<string, unknown>> },
  calendarId: string,
): CalEvent[] {
  const out: CalEvent[] = []
  for (const raw of json.items ?? []) {
    if (raw.status === 'cancelled') continue
    const start = raw.start as { date?: string; dateTime?: string } | undefined
    if (!start) continue
    let date: string
    let allDay: boolean
    let timeLabel: string
    if (start.date) {
      date = start.date
      allDay = true
      timeLabel = 'all-day'
    } else if (start.dateTime) {
      const d = new Date(start.dateTime)
      if (Number.isNaN(d.getTime())) continue
      date = ymd(d)
      allDay = false
      timeLabel = `${pad(d.getHours())}:${pad(d.getMinutes())}`
    } else {
      continue
    }
    out.push({
      id: String(raw.id ?? ''),
      calendarId,
      summary: (raw.summary as string) || '(no title)',
      date,
      allDay,
      timeLabel,
    })
  }
  return out
}

/** Every event in the month, across all of the user's calendars. */
export async function fetchMonth(
  creds: GoogleCredentials,
  year: number,
  month: number,
): Promise<CalEvent[]> {
  const at = await accessToken(creds)
  const [first, next] = monthBounds(year, month)
  const timeMin = `${first}T00:00:00Z`
  const timeMax = `${next}T00:00:00Z`

  const list = await api<{ items?: Array<{ id: string; summary?: string }> }>(
    `${CALENDAR_API}/users/me/calendarList`,
    at,
  )
  const out: CalEvent[] = []
  for (const cal of list.items ?? []) {
    const url =
      `${CALENDAR_API}/calendars/${encodeURIComponent(cal.id)}/events` +
      `?singleEvents=true&orderBy=startTime&maxResults=250` +
      `&timeMin=${encodeURIComponent(timeMin)}&timeMax=${encodeURIComponent(timeMax)}`
    try {
      out.push(...parseEvents(await api(url, at), cal.id))
    } catch {
      // A calendar we can't read shouldn't fail the whole month.
    }
  }
  out.sort((a, b) => a.date.localeCompare(b.date) || a.timeLabel.localeCompare(b.timeLabel))
  return out
}

/** Create an all-day event (end is exclusive, so the next day). */
export async function createEvent(
  creds: GoogleCredentials,
  date: string,
  summary: string,
  calendarId = 'primary',
): Promise<CalEvent> {
  const at = await accessToken(creds)
  const end = new Date(`${date}T00:00:00`)
  end.setDate(end.getDate() + 1)
  const created = await api<Record<string, unknown>>(
    `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events`,
    at,
    {
      method: 'POST',
      body: JSON.stringify({ summary, start: { date }, end: { date: ymd(end) } }),
    },
  )
  return {
    id: String(created.id ?? ''),
    calendarId,
    summary,
    date,
    allDay: true,
    timeLabel: 'all-day',
  }
}

export async function deleteEvent(
  creds: GoogleCredentials,
  calendarId: string,
  eventId: string,
): Promise<void> {
  const at = await accessToken(creds)
  await api<void>(
    `${CALENDAR_API}/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`,
    at,
    { method: 'DELETE' },
  )
}

// ------------------------------------------------------------------ tasks

export interface GTask {
  id: string
  listId: string
  listTitle: string
  title: string
  notes: string
  /** RFC-3339 due date, if any. */
  due: string | null
  completed: boolean
}

export async function fetchTasks(creds: GoogleCredentials): Promise<GTask[]> {
  const at = await accessToken(creds)
  const lists = await api<{ items?: Array<{ id: string; title?: string }> }>(
    `${TASKS_API}/users/@me/lists`,
    at,
  )
  const out: GTask[] = []
  for (const list of lists.items ?? []) {
    const url =
      `${TASKS_API}/lists/${encodeURIComponent(list.id)}/tasks` +
      `?showCompleted=true&showHidden=false&maxResults=100`
    try {
      const res = await api<{ items?: Array<Record<string, unknown>> }>(url, at)
      for (const t of res.items ?? []) {
        out.push({
          id: String(t.id ?? ''),
          listId: list.id,
          listTitle: list.title ?? 'Tasks',
          title: (t.title as string) ?? '',
          notes: (t.notes as string) ?? '',
          due: (t.due as string) ?? null,
          completed: t.status === 'completed',
        })
      }
    } catch {
      // Skip a list we can't read.
    }
  }
  return out
}

export async function setTaskCompleted(
  creds: GoogleCredentials,
  listId: string,
  taskId: string,
  completed: boolean,
): Promise<void> {
  const at = await accessToken(creds)
  await api<void>(
    `${TASKS_API}/lists/${encodeURIComponent(listId)}/tasks/${encodeURIComponent(taskId)}`,
    at,
    {
      method: 'PATCH',
      // Clearing `completed` alongside the status is what moves a task back to
      // "needsAction"; leaving the timestamp set makes Google ignore the change.
      body: JSON.stringify(
        completed ? { status: 'completed' } : { status: 'needsAction', completed: null },
      ),
    },
  )
}

export async function createTask(
  creds: GoogleCredentials,
  listId: string,
  title: string,
  notes = '',
): Promise<GTask> {
  const at = await accessToken(creds)
  const created = await api<Record<string, unknown>>(
    `${TASKS_API}/lists/${encodeURIComponent(listId)}/tasks`,
    at,
    { method: 'POST', body: JSON.stringify({ title, notes }) },
  )
  return {
    id: String(created.id ?? ''),
    listId,
    listTitle: '',
    title,
    notes,
    due: null,
    completed: false,
  }
}

export async function deleteTask(
  creds: GoogleCredentials,
  listId: string,
  taskId: string,
): Promise<void> {
  const at = await accessToken(creds)
  await api<void>(
    `${TASKS_API}/lists/${encodeURIComponent(listId)}/tasks/${encodeURIComponent(taskId)}`,
    at,
    { method: 'DELETE' },
  )
}

/** The first task list, which is where a new task goes by default. */
export async function defaultTaskList(creds: GoogleCredentials): Promise<string> {
  const at = await accessToken(creds)
  const lists = await api<{ items?: Array<{ id: string }> }>(`${TASKS_API}/users/@me/lists`, at)
  const first = lists.items?.[0]?.id
  if (!first) throw new Error('No Google task lists found')
  return first
}
