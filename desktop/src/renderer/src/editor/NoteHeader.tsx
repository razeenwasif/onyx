/**
 * The top of a note's reading column: the folder it lives in, its title
 * (the file name, renamed by editing it), and its tags as chips.
 */

import { useEffect, useState } from 'react'
import { useStore } from '../store'
import { Icon } from '../components/Icon'

export function NoteHeader({ path }: { path: string }): JSX.Element {
  const tags = useStore((s) => s.notes.get(path)?.tags)
  const parts = path.split('/')
  const stem = parts.pop()!.replace(/\.md$/i, '')
  const [title, setTitle] = useState(stem)

  useEffect(() => setTitle(stem), [stem])

  const rename = async (): Promise<void> => {
    const name = title.trim().replace(/[\\/:]/g, '-')
    if (!name || name === stem) {
      setTitle(stem)
      return
    }
    const to = [...parts, `${name}.md`].join('/')
    const st = useStore.getState()
    try {
      const touched = await window.onyx.file.rename(path, to)
      await st.refreshVault()
      await st.refreshGraph()
      await st.openFile(to)
      st.setStatus(touched.length ? `Renamed — updated ${touched.length} link(s)` : 'Renamed')
    } catch (err) {
      setTitle(stem)
      st.setStatus(`Couldn't rename: ${(err as Error).message}`)
    }
  }

  return (
    <header className="note-header">
      {parts.length > 0 && (
        <div className="note-crumbs">
          <Icon name="files" size={12} />
          {parts.map((part, i) => (
            <span key={i}>
              {i > 0 && <span className="note-crumb-sep">/</span>}
              {part}
            </span>
          ))}
        </div>
      )}
      <input
        className="inline-title"
        value={title}
        spellCheck={false}
        aria-label="Note title"
        onChange={(e) => setTitle(e.target.value)}
        onBlur={() => void rename()}
        onKeyDown={(e) => {
          if (e.key === 'Enter') e.currentTarget.blur()
          if (e.key === 'Escape') {
            setTitle(stem)
            requestAnimationFrame(() => (e.target as HTMLInputElement).blur())
          }
        }}
      />
      {tags && tags.length > 0 && (
        <div className="note-tags">
          {tags.map((tag) => (
            <button
              key={tag}
              type="button"
              className="note-tag"
              title={`Notes tagged #${tag}`}
              onClick={() => useStore.setState({ modal: { kind: 'search', initial: `tag:${tag}` } })}
            >
              #{tag}
            </button>
          ))}
        </div>
      )}
    </header>
  )
}
