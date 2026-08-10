/**
 * The Google Drive browser — the desktop version of the TUI's `:drive`.
 *
 * Navigate folders, open a text file in an editor tab (saving writes it straight
 * back to Drive), hand a PDF or image to the system viewer, upload the open note,
 * or pull a Drive file into the vault as a note.
 */

import { useCallback, useEffect, useState } from 'react'
import type { DriveFile } from '@shared/types'
import { useStore, type Tab } from '../store'
import { Icon } from './Icon'
import { relativeTime } from '../lib/notes'

interface Crumb {
  id: string
  name: string
}

function sizeLabel(bytes: number | null): string {
  if (bytes === null) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function DriveView({ tab }: { tab: Tab }): JSX.Element {
  const [crumbs, setCrumbs] = useState<Crumb[]>([{ id: 'root', name: 'My Drive' }])
  const [files, setFiles] = useState<DriveFile[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [term, setTerm] = useState('')
  const [searching, setSearching] = useState(false)
  const [menu, setMenu] = useState<{ x: number; y: number; file: DriveFile } | null>(null)

  const setStatus = useStore((s) => s.setStatus)
  const setModal = useStore((s) => s.setModal)
  const openDriveFile = useStore((s) => s.openDriveFile)
  const refreshVault = useStore((s) => s.refreshVault)
  const openFile = useStore((s) => s.openFile)
  const lastNotePath = useStore((s) => s.lastNotePath)

  const here = crumbs[crumbs.length - 1]

  const load = useCallback(async () => {
    setBusy(true)
    try {
      setFiles(await window.onyx.drive.list(here.id))
      setError(null)
      setSearching(false)
    } catch (e) {
      setError((e as Error).message)
      setFiles([])
    } finally {
      setBusy(false)
    }
  }, [here.id])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    if (!menu) return
    const close = (): void => setMenu(null)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [menu])

  const runSearch = async (): Promise<void> => {
    if (!term.trim()) return void load()
    setBusy(true)
    try {
      setFiles(await window.onyx.drive.search(term.trim()))
      setSearching(true)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const activate = async (file: DriveFile): Promise<void> => {
    if (file.isFolder) {
      setCrumbs([...crumbs, { id: file.id, name: file.name }])
      setTerm('')
      return
    }
    if (file.isGoogleDoc) {
      setStatus(`"${file.name}" is a Google-native doc — Onyx can't edit those yet`)
      return
    }
    if (file.isText) {
      await openDriveFile(file)
      return
    }
    setStatus(`Opening ${file.name}…`)
    try {
      await window.onyx.drive.openExternal(file.id)
      setStatus('')
    } catch (e) {
      setStatus((e as Error).message)
    }
  }

  const uploadCurrentNote = (): void => {
    if (!lastNotePath) return setStatus('Open a note first')
    void window.onyx.drive
      .uploadNote(lastNotePath, here.id)
      .then((f) => {
        setStatus(`Uploaded "${f.name}" to ${here.name}`)
        void load()
      })
      .catch((e: Error) => setStatus(e.message))
  }

  return (
    <div className="drive-view">
      <div className="db-toolbar">
        <div className="drive-crumbs">
          {crumbs.map((c, i) => (
            <span key={c.id}>
              {i > 0 && <span className="sep">/</span>}
              <button
                className="crumb"
                onClick={() => setCrumbs(crumbs.slice(0, i + 1))}
                disabled={i === crumbs.length - 1 && !searching}
              >
                {c.name}
              </button>
            </span>
          ))}
          {searching && <span className="sep">· search results</span>}
        </div>
        <div style={{ flex: 1 }} />
        <input
          placeholder="Search Drive…"
          value={term}
          onChange={(e) => setTerm(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void runSearch()
            if (e.key === 'Escape') {
              setTerm('')
              void load()
            }
          }}
        />
        {busy && <span className="spinner" />}
        <button className="icon-btn" title="Refresh" onClick={() => void load()}>
          <Icon name="history" size={14} />
        </button>
        <button
          className="icon-btn"
          title="New folder here"
          onClick={() =>
            setModal({
              kind: 'prompt',
              title: 'New Drive folder',
              value: '',
              onSubmit: (v) => {
                if (!v.trim()) return
                void window.onyx.drive
                  .createFolder(v.trim(), here.id)
                  .then(() => load())
                  .catch((e: Error) => setStatus(e.message))
              },
            })
          }
        >
          <Icon name="newFolder" size={14} />
        </button>
        <button className="icon-btn" title="Upload the open note here" onClick={uploadCurrentNote}>
          <Icon name="newNote" size={14} />
        </button>
      </div>

      {error && (
        <div className="empty-note" style={{ color: 'var(--warning)' }}>
          {error}
          {/not connected|no google oauth/i.test(error) && (
            <>
              {' '}
              Connect in Settings → Google.
            </>
          )}
        </div>
      )}

      {!error && !files.length && !busy && <div className="empty-note">This folder is empty.</div>}

      <div className="drive-list">
        {files.map((f) => (
          <div
            className="drive-row"
            key={f.id}
            onDoubleClick={() => void activate(f)}
            onClick={() => f.isFolder && void activate(f)}
            onContextMenu={(e) => {
              e.preventDefault()
              setMenu({ x: e.clientX, y: e.clientY, file: f })
            }}
            title={f.isGoogleDoc ? 'Google-native doc — not editable in Onyx' : f.mimeType}
          >
            <Icon
              name={f.isFolder ? 'files' : f.isText ? 'text' : f.isGoogleDoc ? 'book' : 'link'}
              size={14}
            />
            <span className={`name${f.isGoogleDoc ? ' is-muted' : ''}`}>{f.name}</span>
            <span className="meta">{sizeLabel(f.size)}</span>
            <span className="meta">
              {f.modifiedTime ? relativeTime(Date.parse(f.modifiedTime)) : ''}
            </span>
          </div>
        ))}
      </div>

      {menu && (
        <div className="context-menu" style={{ left: menu.x, top: menu.y }}>
          <button onClick={() => void activate(menu.file)}>
            {menu.file.isFolder ? 'Open folder' : menu.file.isText ? 'Edit in Onyx' : 'Open externally'}
          </button>
          {menu.file.isText && (
            <button
              onClick={() =>
                setModal({
                  kind: 'prompt',
                  title: 'Save into the vault as',
                  value: menu.file.name.replace(/\.[^.]+$/, '') + '.md',
                  onSubmit: (v) => {
                    if (!v.trim()) return
                    void window.onyx.drive
                      .importFile(menu.file.id, v.trim())
                      .then(async (rel) => {
                        await refreshVault()
                        void openFile(rel)
                        setStatus(`Saved to ${rel}`)
                      })
                      .catch((e: Error) => setStatus(e.message))
                  },
                })
              }
            >
              Copy into the vault…
            </button>
          )}
          <div className="sep" />
          <button
            className="danger"
            onClick={() =>
              setModal({
                kind: 'confirm',
                title: `Move "${menu.file.name}" to Drive trash?`,
                body: 'It stays recoverable from the Google Drive trash for 30 days.',
                onConfirm: () => {
                  void window.onyx.drive
                    .trash(menu.file.id)
                    .then(() => load())
                    .catch((e: Error) => setStatus(e.message))
                },
              })
            }
          >
            Move to Drive trash
          </button>
        </div>
      )}
      {void tab}
    </div>
  )
}
