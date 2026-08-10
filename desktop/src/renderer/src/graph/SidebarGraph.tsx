/**
 * The small graph docked in the right sidebar — the TUI's graph pane, which
 * shows the neighbourhood of whatever note you're reading.
 *
 * It's the same `GraphView` the full tab uses, sharing the same local-graph
 * settings; only the control panel is hidden, since there's no room for it.
 */

import { useStore } from '../store'
import { GraphView } from './GraphView'

export function SidebarGraph(): JSX.Element {
  const focus = useStore((s) => {
    for (const pane of s.panes) {
      const tab = pane.tabs.find((t) => t.id === pane.activeTabId)
      if (tab?.type === 'markdown' && tab.path) return tab.path
    }
    return s.lastNotePath
  })

  if (!focus) {
    return <div className="empty-note">Open a note to see its neighbourhood.</div>
  }
  return <GraphView focusPath={focus} local compact />
}
