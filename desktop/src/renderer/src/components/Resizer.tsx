import { useCallback, useRef, useState } from 'react'

/** Drag handle for a sidebar edge. */
export function Resizer({
  edge,
  value,
  onChange,
}: {
  edge: 'left' | 'right'
  value: number
  onChange: (v: number) => void
}): JSX.Element {
  const [dragging, setDragging] = useState(false)
  const start = useRef({ x: 0, v: 0 })

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      ;(e.target as HTMLElement).setPointerCapture(e.pointerId)
      start.current = { x: e.clientX, v: value }
      setDragging(true)
    },
    [value],
  )

  return (
    <div
      className={`resizer ${edge === 'right' ? 'right-edge' : 'left-edge'}${dragging ? ' dragging' : ''}`}
      onPointerDown={onPointerDown}
      onPointerMove={(e) => {
        if (!dragging) return
        const delta = e.clientX - start.current.x
        onChange(start.current.v + (edge === 'right' ? delta : -delta))
      }}
      onPointerUp={() => setDragging(false)}
      onDoubleClick={() => onChange(edge === 'right' ? 260 : 300)}
    />
  )
}
