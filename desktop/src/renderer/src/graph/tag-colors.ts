/**
 * Stable colors for tags in the graph view.
 *
 * A tag's color comes from a hash of its **top-level segment**, so `project/web`
 * and `project/api` share a hue and read as one family, and so a color never
 * changes when notes or tags are added elsewhere in the vault. Hues are spread
 * by the golden angle, which keeps neighbouring hashes visually far apart
 * without needing a fixed palette (a vault can have hundreds of tags).
 */

/** The family a tag belongs to: `project/web/api` → `project`. */
export function tagFamily(tag: string): string {
  const slash = tag.indexOf('/')
  return (slash < 0 ? tag : tag.slice(0, slash)).toLowerCase()
}

/** FNV-1a — small, fast, and well spread for short strings. */
function hash(s: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return h >>> 0
}

const GOLDEN_ANGLE = 137.508

/** `#rrggbb` for a tag, tuned for the current theme's background. */
export function tagColor(tag: string, dark: boolean): string {
  const hue = (hash(tagFamily(tag)) * GOLDEN_ANGLE) % 360
  // Nudge saturation/lightness by the hash too, so same-hue collisions still
  // differ a little, and keep both inside a range that reads on either theme.
  const jitter = hash(`${tagFamily(tag)}~`) % 100
  const sat = (dark ? 58 : 62) + (jitter % 14)
  const light = dark ? 60 + (jitter % 9) : 42 + (jitter % 8)
  return hslToHex(hue, sat, light)
}

/**
 * The tag that decides a node's color: the alphabetically first one. Picking a
 * deterministic tag rather than, say, the most common one means a note's color
 * never shifts because some other note changed.
 */
export function primaryTag(tags: string[]): string | null {
  if (!tags.length) return null
  let best = tags[0]
  for (const t of tags) if (t.localeCompare(best) < 0) best = t
  return best
}

export function hslToHex(h: number, s: number, l: number): string {
  const sat = s / 100
  const light = l / 100
  const c = (1 - Math.abs(2 * light - 1)) * sat
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  const m = light - c / 2
  let r = 0
  let g = 0
  let b = 0
  if (h < 60) [r, g, b] = [c, x, 0]
  else if (h < 120) [r, g, b] = [x, c, 0]
  else if (h < 180) [r, g, b] = [0, c, x]
  else if (h < 240) [r, g, b] = [0, x, c]
  else if (h < 300) [r, g, b] = [x, 0, c]
  else [r, g, b] = [c, 0, x]
  const to = (v: number): string =>
    Math.round((v + m) * 255)
      .toString(16)
      .padStart(2, '0')
  return `#${to(r)}${to(g)}${to(b)}`
}
