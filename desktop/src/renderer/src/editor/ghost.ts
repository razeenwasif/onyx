/**
 * Inline AI autocomplete — ghost text after a typing pause, Tab to accept.
 * Port of the TUI's inline-completion feature, backed by the same local model.
 */

import { EditorView, Decoration, DecorationSet, WidgetType, keymap } from '@codemirror/view'
import { StateEffect, StateField, Prec } from '@codemirror/state'

class GhostWidget extends WidgetType {
  constructor(readonly text: string) {
    super()
  }

  eq(o: GhostWidget): boolean {
    return o.text === this.text
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'cm-ghost-text'
    el.textContent = this.text
    return el
  }
}

export const setGhost = StateEffect.define<{ pos: number; text: string } | null>()

export const ghostField = StateField.define<{ pos: number; text: string } | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setGhost)) return e.value
    // Any edit or cursor move invalidates a pending suggestion.
    if (tr.docChanged || tr.selection) return null
    return value
  },
  provide: (f) =>
    EditorView.decorations.from(f, (value): DecorationSet => {
      if (!value || !value.text) return Decoration.none
      return Decoration.set([
        Decoration.widget({ widget: new GhostWidget(value.text), side: 1 }).range(value.pos),
      ])
    }),
})

export function acceptGhost(view: EditorView): boolean {
  const ghost = view.state.field(ghostField, false)
  if (!ghost || !ghost.text) return false
  view.dispatch({
    changes: { from: ghost.pos, insert: ghost.text },
    selection: { anchor: ghost.pos + ghost.text.length },
    effects: setGhost.of(null),
  })
  return true
}

export const ghostKeymap = Prec.highest(
  keymap.of([
    { key: 'Tab', run: acceptGhost },
    {
      key: 'Escape',
      run: (view) => {
        if (!view.state.field(ghostField, false)) return false
        view.dispatch({ effects: setGhost.of(null) })
        return true
      },
    },
  ]),
)

/**
 * Ask the local model for a continuation after `idleMs` of quiet. Only fires
 * at the end of a non-empty line with a collapsed cursor, so it never fights
 * with an active selection or mid-word editing.
 */
export function ghostAutocomplete(enabled: () => boolean, idleMs = 700) {
  let timer: ReturnType<typeof setTimeout> | null = null
  let generation = 0

  return EditorView.updateListener.of((update) => {
    if (!update.docChanged && !update.selectionSet) return
    if (timer) clearTimeout(timer)
    if (!enabled()) return

    const view = update.view
    timer = setTimeout(() => {
      const state = view.state
      const sel = state.selection.main
      if (!sel.empty) return
      const line = state.doc.lineAt(sel.head)
      if (sel.head !== line.to) return
      if (!line.text.trim()) return

      const before = state.doc.sliceString(Math.max(0, sel.head - 2000), sel.head)
      const after = state.doc.sliceString(sel.head, Math.min(state.doc.length, sel.head + 600))
      const mine = ++generation
      void window.onyx.ai
        .complete(before, after)
        .then((text) => {
          if (mine !== generation) return
          const trimmed = text.trim()
          if (!trimmed) return
          const current = view.state.selection.main
          if (!current.empty || current.head !== sel.head) return
          const needsSpace = /\S$/.test(line.text) && !/^[\s.,;:!?)]/.test(trimmed)
          view.dispatch({ effects: setGhost.of({ pos: sel.head, text: (needsSpace ? ' ' : '') + trimmed }) })
        })
        .catch(() => undefined)
    }, idleMs)
  })
}
