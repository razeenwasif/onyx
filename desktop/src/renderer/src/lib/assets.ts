/**
 * Attachment loader. The renderer can't read files and the CSP blocks `file:`
 * URLs, so images and PDFs come over IPC as base64 and get cached as blob URLs
 * (cheaper for the compositor than giant data: URLs).
 */

const MIME: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  svg: 'image/svg+xml',
  bmp: 'image/bmp',
  avif: 'image/avif',
  pdf: 'application/pdf',
  mp4: 'video/mp4',
  webm: 'video/webm',
  mp3: 'audio/mpeg',
  wav: 'audio/wav',
  ogg: 'audio/ogg',
}

const cache = new Map<string, string>()
const pending = new Map<string, Promise<string | null>>()
/** Notified when a URL lands so views can re-render. */
const listeners = new Set<() => void>()

export function onAssetLoaded(fn: () => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

export function cachedAssetUrl(rel: string): string | null {
  return cache.get(rel) ?? null
}

/**
 * Synchronous accessor for render passes: returns the URL if cached, otherwise
 * kicks off the load and returns null (the view re-renders when it arrives).
 */
export function assetUrl(rel: string): string | null {
  const hit = cache.get(rel)
  if (hit) return hit
  if (!pending.has(rel)) {
    pending.set(
      rel,
      (async () => {
        try {
          const b64 = await window.onyx.file.readBinary(rel)
          const ext = (rel.split('.').pop() ?? '').toLowerCase()
          const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
          const url = URL.createObjectURL(
            new Blob([bytes], { type: MIME[ext] ?? 'application/octet-stream' }),
          )
          cache.set(rel, url)
          for (const fn of listeners) fn()
          return url
        } catch {
          return null
        } finally {
          pending.delete(rel)
        }
      })(),
    )
  }
  return null
}

/** Drop a cached URL after the underlying file changed on disk. */
export function invalidateAsset(rel: string): void {
  const url = cache.get(rel)
  if (url) {
    URL.revokeObjectURL(url)
    cache.delete(rel)
  }
}
