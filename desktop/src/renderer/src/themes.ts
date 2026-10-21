/**
 * Themes, ported from `src/theme.rs` and expanded with the surface colors an
 * Obsidian-style GUI needs (the TUI only had 21 slots).
 *
 * Every palette is applied as CSS custom properties on `:root`, so components
 * only ever reference `var(--…)` and a theme switch is a single style write.
 */

export interface Palette {
  id: string
  name: string
  dark: boolean

  // Surfaces
  bg: string
  bgAlt: string
  bgSel: string
  fg: string
  fgDim: string
  fgSubtle: string

  // Accents
  accent: string
  accentAlt: string
  link: string
  wikilink: string
  tag: string
  code: string
  heading: string
  headingAlt: string

  // Semantic
  success: string
  warning: string
  error: string
  info: string

  // Borders
  border: string
  borderFocus: string

  /**
   * Structural skin. `velvet` floats the sidebars and panes as rounded cards
   * with soft depth (styles/velvet.css); unset keeps the flat Obsidian chrome.
   */
  style?: 'velvet'
  /** Extra CSS variables, applied after the derived ones so they can override them. */
  vars?: Record<string, string>
}

/** New installs start here; `themeById` also falls back to it. */
export const DEFAULT_THEME_ID = 'electron-velvet'

export const THEMES: Palette[] = [
  {
    id: 'electron-velvet',
    name: 'Electron Velvet',
    dark: true,
    style: 'velvet',
    // The redesign's palette: a near-black plum backdrop, the panels a step
    // up, the note a step above them; lavender for Electron, green tags and
    // coral for Scribe's ink.
    bg: '#1b1722',
    bgAlt: '#1f1a26',
    bgSel: '#2a2335',
    fg: '#ece7f3',
    fgDim: '#b4adc1',
    fgSubtle: '#948ca3',
    accent: '#b39dfb',
    accentAlt: '#e39072',
    link: '#c4b2fd',
    wikilink: '#c4b2fd',
    tag: '#5fd4a4',
    code: '#f0ad93',
    heading: '#f4f0f8',
    headingAlt: '#f4f0f8',
    success: '#5fd4a4',
    warning: '#f0c27a',
    error: '#f7768e',
    info: '#8fb7f0',
    border: '#2c2537',
    borderFocus: '#b39dfb',
    vars: {
      '--bg-chrome': '#120f17',
      '--bg-panel': '#18141e',
      '--bg-ribbon': 'transparent',
      '--bg-hover': 'rgba(236, 231, 243, 0.05)',
      '--bg-active': '#2a2335',
      '--bg-code': '#241f2d',
      '--bg-modal': '#1d1824',
      '--shadow': '0 30px 80px -24px rgba(0, 0, 0, 0.9), 0 0 0 1px rgba(255, 255, 255, 0.05)',
      '--divider': '#2a2433',
      '--accent-soft': 'rgba(179, 157, 251, 0.12)',
      '--selection': 'rgba(179, 157, 251, 0.26)',
      '--scrollbar': 'rgba(236, 231, 243, 0.12)',
      '--text-body': '#ddd7e6',
      '--ink': '#e39072',
    },
  },
  {
    id: 'onyx-dark',
    name: 'Electron Dark',
    dark: true,
    bg: '#1e1e24',
    bgAlt: '#262631',
    bgSel: '#3a3a4d',
    fg: '#dcd7ba',
    fgDim: '#9b97a8',
    fgSubtle: '#6e6a7c',
    accent: '#a78bfa',
    accentAlt: '#f59e0b',
    link: '#7aa2f7',
    wikilink: '#a78bfa',
    tag: '#34d399',
    code: '#f7768e',
    heading: '#e0c889',
    headingAlt: '#bb9af7',
    success: '#9ece6a',
    warning: '#e0af68',
    error: '#f7768e',
    info: '#7dcfff',
    border: '#3a3a4d',
    borderFocus: '#a78bfa',
  },
  {
    id: 'onyx-light',
    name: 'Electron Light',
    dark: false,
    bg: '#faf8f5',
    bgAlt: '#eee9df',
    bgSel: '#d6cfc3',
    fg: '#1c1c2a',
    fgDim: '#5a5870',
    fgSubtle: '#84829a',
    accent: '#6f42c1',
    accentAlt: '#d97706',
    link: '#1d4ed8',
    wikilink: '#7c3aed',
    tag: '#059669',
    code: '#be185d',
    heading: '#9a3412',
    headingAlt: '#6d28d9',
    success: '#15803d',
    warning: '#a16207',
    error: '#b91c1c',
    info: '#0369a1',
    border: '#cdc6b8',
    borderFocus: '#6f42c1',
  },
  {
    id: 'dracula',
    name: 'Dracula',
    dark: true,
    bg: '#282a36',
    bgAlt: '#21222c',
    bgSel: '#44475a',
    fg: '#f8f8f2',
    fgDim: '#bdbdbd',
    fgSubtle: '#6272a4',
    accent: '#bd93f9',
    accentAlt: '#ffb86c',
    link: '#8be9fd',
    wikilink: '#bd93f9',
    tag: '#50fa7b',
    code: '#ff79c6',
    heading: '#ffb86c',
    headingAlt: '#ff79c6',
    success: '#50fa7b',
    warning: '#f1fa8c',
    error: '#ff5555',
    info: '#8be9fd',
    border: '#44475a',
    borderFocus: '#bd93f9',
  },
  {
    id: 'nord',
    name: 'Nord',
    dark: true,
    bg: '#2e3440',
    bgAlt: '#3b4252',
    bgSel: '#434c5e',
    fg: '#eceff4',
    fgDim: '#d8dee9',
    fgSubtle: '#7e8a9e',
    accent: '#88c0d0',
    accentAlt: '#d08770',
    link: '#81a1c1',
    wikilink: '#b48ead',
    tag: '#a3be8c',
    code: '#bf616a',
    heading: '#ebcb8b',
    headingAlt: '#b48ead',
    success: '#a3be8c',
    warning: '#ebcb8b',
    error: '#bf616a',
    info: '#88c0d0',
    border: '#434c5e',
    borderFocus: '#88c0d0',
  },
  {
    id: 'obsidian',
    name: 'Obsidian Default',
    dark: true,
    bg: '#1e1e1e',
    bgAlt: '#262626',
    bgSel: '#363636',
    fg: '#dadada',
    fgDim: '#b3b3b3',
    fgSubtle: '#7a7a7a',
    accent: '#8a5cf6',
    accentAlt: '#e0982c',
    link: '#7f6df2',
    wikilink: '#a882ff',
    tag: '#4eb3d4',
    code: '#e05561',
    heading: '#d4d4d4',
    headingAlt: '#c8c8c8',
    success: '#4caf50',
    warning: '#e0982c',
    error: '#e05561',
    info: '#4eb3d4',
    border: '#3f3f3f',
    borderFocus: '#8a5cf6',
  },
]

export function themeById(id: string | undefined): Palette {
  return THEMES.find((t) => t.id === id) ?? THEMES.find((t) => t.id === DEFAULT_THEME_ID)!
}

/** Mix two hex colors; `t` = 0 returns `a`, 1 returns `b`. */
export function mix(a: string, b: string, t: number): string {
  const pa = hexToRgb(a)
  const pb = hexToRgb(b)
  const r = Math.round(pa[0] + (pb[0] - pa[0]) * t)
  const g = Math.round(pa[1] + (pb[1] - pa[1]) * t)
  const bl = Math.round(pa[2] + (pb[2] - pa[2]) * t)
  return `#${[r, g, bl].map((v) => v.toString(16).padStart(2, '0')).join('')}`
}

export function hexToRgb(hex: string): [number, number, number] {
  let h = hex.replace('#', '')
  if (h.length === 3) h = h.split('').map((c) => c + c).join('')
  const n = parseInt(h, 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

export function rgba(hex: string, alpha: number): string {
  const [r, g, b] = hexToRgb(hex)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

/** Variables the previous theme's `vars` set, so a switch can clear them. */
let extraVars: string[] = []

/** Push a palette onto `:root` as CSS variables. */
export function applyTheme(p: Palette): void {
  const el = document.documentElement
  const set = (k: string, v: string): void => el.style.setProperty(k, v)
  for (const k of extraVars) el.style.removeProperty(k)

  set('--bg', p.bg)
  set('--bg-alt', p.bgAlt)
  set('--bg-sel', p.bgSel)
  set('--fg', p.fg)
  set('--fg-dim', p.fgDim)
  set('--fg-subtle', p.fgSubtle)
  set('--accent', p.accent)
  set('--accent-alt', p.accentAlt)
  set('--link', p.link)
  set('--wikilink', p.wikilink)
  set('--tag', p.tag)
  set('--code', p.code)
  set('--heading', p.heading)
  set('--heading-alt', p.headingAlt)
  set('--success', p.success)
  set('--warning', p.warning)
  set('--error', p.error)
  set('--info', p.info)
  set('--border', p.border)
  set('--border-focus', p.borderFocus)

  // Derived surfaces — Obsidian's chrome sits slightly behind the note area.
  const deeper = p.dark ? '#000000' : '#ffffff'
  set('--bg-chrome', mix(p.bg, deeper, p.dark ? 0.25 : 0.03))
  set('--bg-ribbon', mix(p.bg, deeper, p.dark ? 0.38 : 0.06))
  set('--bg-hover', rgba(p.fg, p.dark ? 0.06 : 0.05))
  set('--bg-active', rgba(p.accent, p.dark ? 0.18 : 0.14))
  set('--bg-code', mix(p.bgAlt, deeper, p.dark ? 0.12 : 0.0))
  set('--bg-modal', mix(p.bgAlt, deeper, p.dark ? 0.05 : 0.0))
  set('--shadow', p.dark ? '0 12px 40px rgba(0,0,0,.55)' : '0 12px 40px rgba(0,0,0,.18)')
  set('--divider', rgba(p.border, 0.8))
  set('--accent-soft', rgba(p.accent, 0.16))
  set('--selection', rgba(p.accent, p.dark ? 0.28 : 0.22))
  set('--scrollbar', rgba(p.fg, p.dark ? 0.16 : 0.2))

  extraVars = Object.keys(p.vars ?? {})
  for (const [k, v] of Object.entries(p.vars ?? {})) set(k, v)

  el.dataset.theme = p.dark ? 'dark' : 'light'
  if (p.style) el.dataset.style = p.style
  else delete el.dataset.style
  el.style.colorScheme = p.dark ? 'dark' : 'light'
}
