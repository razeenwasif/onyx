/**
 * The graph docked in the right sidebar: the full vault graph, not a local
 * neighbourhood — the same view the Graph tab shows, sharing its settings, with
 * the note you're reading highlighted in the accent colour.
 *
 * It runs in `compact` mode: no control panel (there's no room), and the
 * simulation is allowed to freeze once it settles rather than drifting
 * forever, so a docked graph over a thousand notes doesn't burn CPU in the
 * background. The maximize button in the pane header opens the full tab.
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

  return <GraphView focusPath={focus} local={false} compact />
}
