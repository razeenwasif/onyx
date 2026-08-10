/**
 * A sidebar as a vertical stack of panes, the way the Onyx TUI lays them out —
 * files/quicknote/todo down the left, backlinks/graph/calendar down the right —
 * rather than Obsidian's one-visible-tab-at-a-time sidebar.
 *
 * Each pane has a header (click to collapse), an optional fixed height, and a
 * drag handle along its bottom edge. A pane with `height: 0` is flexible and
 * shares whatever is left over, which is how the TUI's `Min(…)` constraints
 * behave.
 */

import { useCallback, useRef, useState } from 'react'
import type { SectionId } from '@shared/types'
import { Icon, type IconName } from './Icon'

export interface StackSection {
  id: SectionId
  title: string
  icon: IconName
  /** 0 = flexible; otherwise a pixel height. */
  height: number
  collapsed: boolean
  /** Header buttons, rendered right-aligned. */
  actions?: Array<{ icon: IconName; title: string; onClick: () => void }>
  body: JSX.Element
}

const HEADER_H = 26
const MIN_BODY_H = 60

export function SidebarStack({
  sections,
  onResize,
  onToggleCollapse,
  onMenu,
}: {
  sections: StackSection[]
  onResize: (id: SectionId, height: number) => void
  onToggleCollapse: (id: SectionId) => void
  /** Right-click / “…” on the sidebar background, for showing hidden panes. */
  onMenu?: (x: number, y: number) => void
}): JSX.Element {
  const hostRef = useRef<HTMLDivElement>(null)
  const [dragging, setDragging] = useState<SectionId | null>(null)
  const dragState = useRef<{ id: SectionId; startY: number; startH: number } | null>(null)

  const beginResize = useCallback(
    (e: React.PointerEvent, section: StackSection, index: number) => {
      e.preventDefault()
      e.stopPropagation()
      ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
      // A flexible pane has no explicit height yet; seed from what it renders as.
      const el = hostRef.current?.querySelectorAll('.stack-pane')[index] as HTMLElement | undefined
      const startH = section.height || (el?.getBoundingClientRect().height ?? 200)
      dragState.current = { id: section.id, startY: e.clientY, startH }
      setDragging(section.id)
    },
    [],
  )

  return (
    <div
      className="sidebar-stack"
      ref={hostRef}
      onContextMenu={(e) => {
        if (!onMenu) return
        e.preventDefault()
        onMenu(e.clientX, e.clientY)
      }}
      onPointerMove={(e) => {
        const drag = dragState.current
        if (!drag) return
        onResize(drag.id, Math.max(MIN_BODY_H, drag.startH + (e.clientY - drag.startY)))
      }}
      onPointerUp={() => {
        dragState.current = null
        setDragging(null)
      }}
    >
      {sections.map((section, i) => {
        const isLast = i === sections.length - 1
        const style = section.collapsed
          ? { flex: `0 0 ${HEADER_H}px` }
          : section.height > 0
            ? { flex: `0 0 ${section.height}px` }
            : { flex: '1 1 0', minHeight: MIN_BODY_H }
        return (
          <div className="stack-pane" key={section.id} style={style}>
            <div className="stack-header" onClick={() => onToggleCollapse(section.id)}>
              <Icon
                name="chevronDown"
                size={12}
                className={`twisty${section.collapsed ? ' collapsed' : ''}`}
              />
              <Icon name={section.icon} size={12} />
              <span className="stack-title">{section.title}</span>
              {section.actions && section.actions.length > 0 && (
                <span className="stack-actions" onClick={(e) => e.stopPropagation()}>
                  {section.actions.map((a) => (
                    <button key={a.title} title={a.title} onClick={a.onClick}>
                      <Icon name={a.icon} size={13} />
                    </button>
                  ))}
                </span>
              )}
            </div>
            {!section.collapsed && <div className="stack-body">{section.body}</div>}
            {!isLast && (
              <div
                className={`stack-resizer${dragging === section.id ? ' dragging' : ''}`}
                onPointerDown={(e) => beginResize(e, section, i)}
                onDoubleClick={() => onResize(section.id, 0)}
                title="Drag to resize · double-click to make flexible"
              />
            )}
          </div>
        )
      })}
    </div>
  )
}
