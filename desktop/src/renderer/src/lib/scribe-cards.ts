/**
 * Ink cards: a `[[scribe:…]]` link on a line of its own shows as a card in
 * the note, with a picture of the linked page (or lassoed area) drawn by
 * Scribe, its title and notebook, and "Open in Scribe". Links inside a
 * sentence stay links.
 *
 * The pictures come from Scribe over IPC and are cached as blob URLs per
 * link and page version, so editing the page in Scribe redraws the card.
 */

import { parseScribeTarget } from '@shared/scribe-link'
import type { ScribePage } from '@shared/types'
import { scribePageFor } from './scribe-links'

/** A line that is nothing but a Scribe link: `[[scribe:id#area|Title]]`. */
export const CARD_LINE = /^\s*!?\[\[(scribe:[^\]|\n]+)(?:\|([^\]\n]*))?\]\]\s*$/i

/** Card pictures are drawn this many pixels wide (the column at 2×). */
const PIXELS = 1300

type Entry = { url: string | null }
const cache = new Map<string, Entry>()
const pending = new Set<string>()
const listeners = new Set<() => void>()

/** Called when a card's picture arrives, so views can redraw. */
export function onCardLoaded(fn: () => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

function keyFor(target: string, page: ScribePage): string {
  return `${target.trim()}@${page.modified}`
}

/**
 * The card's picture: a URL, null when Scribe couldn't draw it, or
 * undefined while it's on its way (the load starts here).
 */
export function cardPicture(target: string): string | null | undefined {
  const page = scribePageFor(target)
  if (!page) return null
  const key = keyFor(target, page)
  const hit = cache.get(key)
  if (hit) return hit.url
  if (!pending.has(key)) {
    pending.add(key)
    void window.onyx.apps
      .scribeCard(target.trim(), PIXELS)
      .catch(() => null)
      .then((b64) => {
        // A newer version of the page replaces the older picture.
        for (const [k, old] of cache) {
          if (k.startsWith(`${target.trim()}@`) && old.url) URL.revokeObjectURL(old.url)
          if (k.startsWith(`${target.trim()}@`)) cache.delete(k)
        }
        const url = b64
          ? URL.createObjectURL(new Blob([Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))], { type: 'image/png' }))
          : null
        cache.set(key, { url })
        pending.delete(key)
        for (const fn of listeners) fn()
      })
  }
  return undefined
}

export interface CardInfo {
  target: string
  title: string
  /** "Scribe · Notebook · Section", and whether it's an area of the page. */
  meta: string
  picture: string | null | undefined
}

/** What a card shows for a link, or null when the page isn't known (no card). */
export function cardInfo(target: string, label?: string): CardInfo | null {
  const link = parseScribeTarget(target)
  const page = scribePageFor(target)
  if (!link || !page) return null
  const where = [page.notebook, page.section].filter(Boolean).join(' · ')
  return {
    target: target.trim(),
    title: label?.trim() || page.title || 'Scribe page',
    meta: `Scribe${where ? ` · ${where}` : ''}${link.area ? ' · a lassoed area' : ''}`,
    picture: cardPicture(target),
  }
}

const escape = (s: string): string =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

const ARROW =
  '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9"/></svg>'

/** The card's markup; links carry `data-href` so the views' click handlers open them. */
export function cardHtml(card: CardInfo): string {
  const href = escape(card.target)
  const picture =
    card.picture === undefined
      ? '<div class="ink-card-wait">Drawing the page…</div>'
      : card.picture === null
        ? '<div class="ink-card-wait">Scribe couldn’t draw this page</div>'
        : `<img src="${escape(card.picture)}" alt="${escape(card.title)}" draggable="false" />`
  return (
    `<figure class="ink-card">` +
    `<a class="ink-card-ink" data-href="${href}" href="#" title="Open in Scribe">${picture}</a>` +
    `<figcaption><span class="ink-card-mark" aria-hidden="true"></span>` +
    `<span class="ink-card-text"><span class="ink-card-title">${escape(card.title)}</span>` +
    `<span class="ink-card-meta">${escape(card.meta)}</span></span>` +
    `<a class="ink-card-open" data-href="${href}" href="#">Open in Scribe ${ARROW}</a>` +
    `</figcaption></figure>`
  )
}
