import { useEffect } from 'react'
import { useStore } from './store'
import { COMMANDS, keyString, runCommand } from './commands'
import { Ribbon } from './components/Ribbon'
import { LeftSidebar } from './components/LeftSidebar'
import { RightSidebar } from './components/RightSidebar'
import { Workspace } from './components/Workspace'
import { StatusBar } from './components/StatusBar'
import { Modals } from './components/Modals'
import { Icon } from './components/Icon'
import { invalidateAsset } from './lib/assets'

export function App(): JSX.Element {
  const ready = useStore((s) => s.ready)
  const vault = useStore((s) => s.vault)
  const leftOpen = useStore((s) => s.leftOpen)
  const rightOpen = useStore((s) => s.rightOpen)
  const status = useStore((s) => s.status)
  const zen = useStore((s) => s.zenPaneId)

  useEffect(() => {
    void useStore.getState().init()
  }, [])

  // Menu accelerators come from the main process. `open:<path>` is also
  // accepted so a headless capture run can put a specific note on screen.
  useEffect(
    () =>
      window.onyx.app.onMenuCommand((id) => {
        if (id.startsWith('open:')) void useStore.getState().openFile(id.slice(5))
        else runCommand(id)
      }),
    [],
  )

  // Filesystem changes: refresh the index, and reload any clean open buffer.
  useEffect(() => {
    const offChanged = window.onyx.vault.onChanged((kind, rel) => {
      invalidateAsset(rel)
      const st = useStore.getState()
      const doc = st.docs.get(rel)
      if (kind === 'unlink') {
        const docs = new Map(st.docs)
        docs.delete(rel)
        useStore.setState({ docs })
        return
      }
      if (doc && !doc.dirty) {
        void window.onyx.file.read(rel).then((content) => {
          if (content !== doc.content) st.setDoc(rel, content, false)
        })
      } else if (doc?.dirty) {
        st.setStatus(`"${rel}" changed on disk — your unsaved copy is still open`)
      }
    })
    const offSettled = window.onyx.vault.onSettled(() => {
      const st = useStore.getState()
      void st.refreshVault()
      void st.refreshGraph()
    })
    return () => {
      offChanged()
      offSettled()
    }
  }, [])

  // Global hotkeys. Editors get first refusal on plain keys; only chords with a
  // modifier (or F-keys) are intercepted here.
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      const key = keyString(e)
      const hasMod = e.ctrlKey || e.metaKey || e.altKey || /^f\d+$/.test(e.key.toLowerCase())
      if (!hasMod) return
      for (const cmd of COMMANDS) {
        if (cmd.keys?.includes(key)) {
          e.preventDefault()
          e.stopPropagation()
          void cmd.run()
          return
        }
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [])

  // Save everything before the window goes away.
  useEffect(() => {
    const onBeforeUnload = (): void => {
      void useStore.getState().saveAll()
    }
    window.addEventListener('beforeunload', onBeforeUnload)
    return () => window.removeEventListener('beforeunload', onBeforeUnload)
  }, [])

  if (!ready) {
    return (
      <div className="vault-picker">
        <div>
          <span className="spinner" />
        </div>
      </div>
    )
  }

  if (!vault) {
    return (
      <div className="vault-picker">
        <div>
          <h1>Onyx</h1>
          <p>Open a folder of markdown notes to use as your vault.</p>
          <button
            className="btn primary"
            onClick={async () => {
              const picked = await window.onyx.vault.pick()
              if (picked) window.location.reload()
            }}
          >
            <Icon name="vault" size={14} /> Open vault
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="app">
      <Ribbon />
      <div className="app-body">
        <div className="app-main">
          {leftOpen && !zen && <LeftSidebar />}
          <Workspace />
          {rightOpen && !zen && <RightSidebar />}
        </div>
        <StatusBar />
      </div>
      <Modals />
      {status && <div className="notice">{status}</div>}
    </div>
  )
}
