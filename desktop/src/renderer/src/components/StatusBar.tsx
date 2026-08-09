import { useStore } from '../store'
import { runCommand } from '../commands'
import { relativeTime } from '../lib/notes'

export function StatusBar(): JSX.Element {
  const tab = useStore((s) => s.activeTab())
  const doc = useStore((s) => (tab?.path ? s.docs.get(tab.path) : undefined))
  const meta = useStore((s) => (tab?.path ? s.notes.get(tab.path) : undefined))
  const notes = useStore((s) => s.notes)
  const settings = useStore((s) => s.settings)
  const vault = useStore((s) => s.vault)

  const words = doc ? doc.content.trim().split(/\s+/).filter(Boolean).length : (meta?.wordCount ?? 0)
  const chars = doc?.content.length ?? meta?.size ?? 0

  return (
    <div className="statusbar">
      <span className="left">
        {vault?.name} · {notes.size} note{notes.size === 1 ? '' : 's'}
      </span>
      {tab?.type === 'markdown' && (
        <>
          <span className="item">{words} words</span>
          <span className="item">{chars} characters</span>
          {meta && <span className="item">{relativeTime(meta.mtime)}</span>}
          <span className="item">{doc?.dirty ? 'Unsaved' : 'Saved'}</span>
        </>
      )}
      <span className="item" onClick={() => runCommand('theme:cycle')} title="Cycle theme">
        {settings?.theme}
      </span>
      {settings?.vimMode && <span className="item">VIM</span>}
    </div>
  )
}
