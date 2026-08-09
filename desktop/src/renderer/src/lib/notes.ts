/** Small note helpers shared across views. */

import type { NoteMeta } from '@shared/types'

export function basename(p: string): string {
  return p.split('/').pop() ?? p
}

export function stem(p: string): string {
  return basename(p).replace(/\.[^.]+$/, '')
}

export function dirname(p: string): string {
  const i = p.lastIndexOf('/')
  return i < 0 ? '' : p.slice(0, i)
}

export function joinPath(dir: string, name: string): string {
  return dir ? `${dir}/${name}` : name
}

/** `Untitled.md`, `Untitled 1.md`, … in `folder`. */
export function uniqueUntitled(folder: string, notes: Map<string, NoteMeta>): string {
  let candidate = joinPath(folder, 'Untitled.md')
  let n = 0
  while (notes.has(candidate)) {
    n += 1
    candidate = joinPath(folder, `Untitled ${n}.md`)
  }
  return candidate
}

const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
]
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

/**
 * Format a date with the Moment-style tokens Obsidian's daily-note setting
 * uses (`YYYY-MM-DD`, `MMMM Do, YYYY`, …). Also accepts the TUI's strftime
 * tokens (`%Y-%m-%d`) so a shared config keeps working.
 */
export function formatDate(d: Date, format: string): string {
  if (format.includes('%')) {
    return format
      .replace(/%Y/g, String(d.getFullYear()))
      .replace(/%m/g, pad(d.getMonth() + 1))
      .replace(/%d/g, pad(d.getDate()))
      .replace(/%H/g, pad(d.getHours()))
      .replace(/%M/g, pad(d.getMinutes()))
      .replace(/%B/g, MONTHS[d.getMonth()])
      .replace(/%A/g, DAYS[d.getDay()])
  }
  return format.replace(
    /YYYY|YY|MMMM|MMM|MM|DDDD|dddd|ddd|DD|Do|HH|mm|ss/g,
    (tok) => {
      switch (tok) {
        case 'YYYY':
          return String(d.getFullYear())
        case 'YY':
          return pad(d.getFullYear() % 100)
        case 'MMMM':
          return MONTHS[d.getMonth()]
        case 'MMM':
          return MONTHS[d.getMonth()].slice(0, 3)
        case 'MM':
          return pad(d.getMonth() + 1)
        case 'DDDD':
        case 'dddd':
          return DAYS[d.getDay()]
        case 'ddd':
          return DAYS[d.getDay()].slice(0, 3)
        case 'DD':
          return pad(d.getDate())
        case 'Do':
          return ordinal(d.getDate())
        case 'HH':
          return pad(d.getHours())
        case 'mm':
          return pad(d.getMinutes())
        case 'ss':
          return pad(d.getSeconds())
        default:
          return tok
      }
    },
  )
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return n + (s[(v - 20) % 10] || s[v] || s[0])
}

export function dailyNotePath(d: Date, folder: string, format: string): string {
  return joinPath(folder, `${formatDate(d, format)}.md`)
}

/** Frontmatter block + body, for editors that rewrite properties in place. */
export function splitFrontmatter(content: string): { frontmatter: string | null; body: string } {
  const m = /^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(content)
  if (!m) return { frontmatter: null, body: content }
  return { frontmatter: m[1], body: content.slice(m[0].length) }
}

export function withFrontmatter(frontmatter: string | null, body: string): string {
  if (frontmatter === null) return body
  return `---\n${frontmatter}\n---\n${body}`
}

/** Toggle the `- [ ]` / `- [x]` checkbox on `line` (0-based). */
export function toggleTaskOnLine(content: string, line: number): string {
  const lines = content.split('\n')
  const l = lines[line]
  if (l === undefined) return content
  const m = /^(\s*[-*+]\s+\[)([ xX])(\].*)$/.exec(l)
  if (!m) return content
  lines[line] = `${m[1]}${m[2] === ' ' ? 'x' : ' '}${m[3]}`
  return lines.join('\n')
}

export function relativeTime(ms: number): string {
  const diff = Date.now() - ms
  const min = Math.round(diff / 60000)
  if (min < 1) return 'just now'
  if (min < 60) return `${min}m ago`
  const h = Math.round(min / 60)
  if (h < 24) return `${h}h ago`
  const d = Math.round(h / 24)
  if (d < 30) return `${d}d ago`
  return new Date(ms).toLocaleDateString()
}
