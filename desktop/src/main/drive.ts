/**
 * Google Drive API v3 — browse folders, open a text file, write edits back,
 * upload a note. Port of `src/integrations/gdrive.rs`.
 *
 * Shares the OAuth client and token with `google.ts` (and therefore with the
 * TUI): the Drive scope is already part of the single consent Onyx asks for.
 *
 * Google-native docs (Docs/Sheets/Slides) are listed but can't be opened — they
 * need an export conversion rather than a download, and round-tripping an edit
 * back into one isn't something Onyx should pretend to do.
 */

import { promises as fs } from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { shell } from 'electron'

import { accessToken, type GoogleCredentials } from './google.js'

const API = 'https://www.googleapis.com/drive/v3'
const UPLOAD = 'https://www.googleapis.com/upload/drive/v3'

export const FOLDER_MIME = 'application/vnd.google-apps.folder'

export interface DriveFile {
  id: string
  name: string
  mimeType: string
  isFolder: boolean
  /** Onyx can open this as editable text. */
  isText: boolean
  /** A Google-native doc: needs export, not download. */
  isGoogleDoc: boolean
  modifiedTime: string | null
  size: number | null
}

const TEXT_MIMES = new Set(['application/json', 'application/xml', 'application/x-yaml'])
const TEXT_EXTS = [
  '.md',
  '.markdown',
  '.txt',
  '.org',
  '.csv',
  '.log',
  '.rs',
  '.py',
  '.js',
  '.ts',
  '.tsx',
  '.toml',
  '.yaml',
  '.yml',
  '.json',
  '.html',
  '.css',
]

function classify(raw: {
  id?: string
  name?: string
  mimeType?: string
  modifiedTime?: string
  size?: string
}): DriveFile {
  const mimeType = raw.mimeType ?? ''
  const name = raw.name ?? ''
  const isFolder = mimeType === FOLDER_MIME
  const lower = name.toLowerCase()
  const isText =
    !isFolder &&
    (mimeType.startsWith('text/') ||
      TEXT_MIMES.has(mimeType) ||
      TEXT_EXTS.some((e) => lower.endsWith(e)))
  return {
    id: raw.id ?? '',
    name,
    mimeType,
    isFolder,
    isText,
    isGoogleDoc: mimeType.startsWith('application/vnd.google-apps.') && !isFolder,
    modifiedTime: raw.modifiedTime ?? null,
    size: raw.size ? Number(raw.size) : null,
  }
}

async function api<T>(url: string, at: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(url, {
    ...init,
    headers: { Authorization: `Bearer ${at}`, ...(init.headers ?? {}) },
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`Google Drive ${res.status}: ${text.slice(0, 200)}`)
  }
  return (await res.json()) as T
}

/** One folder's children, folders first then by name (Drive's `orderBy`). */
export async function listFolder(
  creds: GoogleCredentials,
  folderId = 'root',
): Promise<DriveFile[]> {
  const at = await accessToken(creds)
  const q = encodeURIComponent(`'${folderId}' in parents and trashed = false`)
  const fields = encodeURIComponent('files(id,name,mimeType,modifiedTime,size)')
  const url = `${API}/files?q=${q}&fields=${fields}&pageSize=200&orderBy=folder,name`
  const json = await api<{ files?: Array<Record<string, string>> }>(url, at)
  return (json.files ?? []).map(classify)
}

/** Search the whole Drive by name. */
export async function searchFiles(creds: GoogleCredentials, term: string): Promise<DriveFile[]> {
  const at = await accessToken(creds)
  const escaped = term.replace(/'/g, "\\'")
  const q = encodeURIComponent(`name contains '${escaped}' and trashed = false`)
  const fields = encodeURIComponent('files(id,name,mimeType,modifiedTime,size)')
  const url = `${API}/files?q=${q}&fields=${fields}&pageSize=100&orderBy=folder,name`
  const json = await api<{ files?: Array<Record<string, string>> }>(url, at)
  return (json.files ?? []).map(classify)
}

/** A file's metadata, for the breadcrumb and for re-checking a mime type. */
export async function fileInfo(creds: GoogleCredentials, fileId: string): Promise<DriveFile> {
  const at = await accessToken(creds)
  const fields = encodeURIComponent('id,name,mimeType,modifiedTime,size,parents')
  return classify(await api(`${API}/files/${encodeURIComponent(fileId)}?fields=${fields}`, at))
}

export async function downloadText(creds: GoogleCredentials, fileId: string): Promise<string> {
  const at = await accessToken(creds)
  const res = await fetch(`${API}/files/${encodeURIComponent(fileId)}?alt=media`, {
    headers: { Authorization: `Bearer ${at}` },
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`Google Drive ${res.status}: ${text.slice(0, 200)}`)
  }
  return res.text()
}

/**
 * Download a binary file to a temp path and hand it to the system viewer —
 * how the TUI opens a PDF or an image from Drive.
 */
export async function openExternally(creds: GoogleCredentials, file: DriveFile): Promise<string> {
  const at = await accessToken(creds)
  const res = await fetch(`${API}/files/${encodeURIComponent(file.id)}?alt=media`, {
    headers: { Authorization: `Bearer ${at}` },
  })
  if (!res.ok) throw new Error(`Google Drive ${res.status}`)
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'onyx-drive-'))
  // Keep the original name so the viewer picks the right handler.
  const target = path.join(dir, file.name.replace(/[/\\]/g, '_'))
  await fs.writeFile(target, Buffer.from(await res.arrayBuffer()))
  const err = await shell.openPath(target)
  if (err) throw new Error(err)
  return target
}

/** Overwrite an existing file's contents (the two-way save). */
export async function updateText(
  creds: GoogleCredentials,
  fileId: string,
  content: string,
  mime = 'text/markdown',
): Promise<void> {
  const at = await accessToken(creds)
  const res = await fetch(
    `${UPLOAD}/files/${encodeURIComponent(fileId)}?uploadType=media&fields=id`,
    {
      method: 'PATCH',
      headers: { Authorization: `Bearer ${at}`, 'Content-Type': mime },
      body: content,
    },
  )
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`Google Drive ${res.status}: ${text.slice(0, 200)}`)
  }
}

/** Create a new file via a multipart upload (metadata + content in one request). */
export async function createFile(
  creds: GoogleCredentials,
  name: string,
  content: string,
  parentId = 'root',
  mime = 'text/markdown',
): Promise<DriveFile> {
  const at = await accessToken(creds)
  const boundary = `onyx${Date.now().toString(36)}`
  const metadata = JSON.stringify({ name, parents: [parentId] })
  const body =
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n` +
    `--${boundary}\r\nContent-Type: ${mime}\r\n\r\n${content}\r\n` +
    `--${boundary}--\r\n`
  const res = await fetch(`${UPLOAD}/files?uploadType=multipart&fields=id,name,mimeType`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${at}`,
      'Content-Type': `multipart/related; boundary=${boundary}`,
    },
    body,
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`Google Drive ${res.status}: ${text.slice(0, 200)}`)
  }
  return classify((await res.json()) as Record<string, string>)
}

export async function createFolder(
  creds: GoogleCredentials,
  name: string,
  parentId = 'root',
): Promise<DriveFile> {
  const at = await accessToken(creds)
  const res = await fetch(`${API}/files?fields=id,name,mimeType`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${at}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, mimeType: FOLDER_MIME, parents: [parentId] }),
  })
  if (!res.ok) throw new Error(`Google Drive ${res.status}`)
  return classify((await res.json()) as Record<string, string>)
}

/** Move a file to the Drive trash (not a hard delete). */
export async function trashFile(creds: GoogleCredentials, fileId: string): Promise<void> {
  const at = await accessToken(creds)
  const res = await fetch(`${API}/files/${encodeURIComponent(fileId)}`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${at}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ trashed: true }),
  })
  if (!res.ok) throw new Error(`Google Drive ${res.status}`)
}

/** Guess an upload mime type from a filename. */
export function mimeForName(name: string): string {
  const lower = name.toLowerCase()
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) return 'text/markdown'
  if (lower.endsWith('.json')) return 'application/json'
  if (lower.endsWith('.csv')) return 'text/csv'
  if (lower.endsWith('.html')) return 'text/html'
  return 'text/plain'
}
