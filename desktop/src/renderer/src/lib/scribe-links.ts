/** `[[scribe:…]]` links in the renderer: resolving them and opening them. */

import { isScribeTarget, parseScribeTarget } from '@shared/scribe-link'
import type { ScribePage } from '@shared/types'
import { useStore } from '../store'

/** The Scribe page a link target names, or null (also when Scribe isn't here). */
export function scribePageFor(target: string): ScribePage | null {
  const link = parseScribeTarget(target)
  return link ? (useStore.getState().scribePages.get(link.pageId) ?? null) : null
}

/**
 * Opens a `scribe:` target in Scribe and returns true; false for any other
 * target, so callers fall through to opening a note.
 */
export function openScribeTarget(target: string): boolean {
  if (!isScribeTarget(target)) return false
  void window.onyx.apps.scribeOpenLink(target).then((ok) => {
    if (!ok) useStore.getState().setStatus('Links to Scribe pages open on a Mac with Scribe')
  })
  return true
}
