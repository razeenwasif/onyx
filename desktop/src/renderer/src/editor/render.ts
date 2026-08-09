/**
 * Reading view: markdown → HTML, with the Obsidian/Onyx extensions the plain
 * CommonMark renderer doesn't know about — `[[wikilinks]]`, `![[embeds]]`,
 * `#tags`, `==highlights==`, `> [!callout]` blocks (collapsible with `-`),
 * `::: columns … +++ … :::`, `$math$`, and task lists.
 */

import MarkdownIt from 'markdown-it'
import hljs from 'highlight.js/lib/common'
import katex from 'katex'

import { extractFrontmatterProperties, frontmatterLength } from '@shared/parse'

export interface RenderContext {
  /** Resolve a wikilink target to a vault path, or null when unresolved. */
  resolve(target: string): string | null
  /** Resolve an attachment (image, pdf) to a displayable URL. */
  fileUrl(target: string): string | null
  /** Body of an embedded note, for `![[Note]]`. */
  embed(target: string): string | null
  /** The note being rendered, for relative resolution. */
  path: string
}

const CALLOUT_COLORS: Record<string, string> = {
  note: 'var(--info)',
  abstract: 'var(--info)',
  summary: 'var(--info)',
  tldr: 'var(--info)',
  info: 'var(--info)',
  todo: 'var(--info)',
  tip: 'var(--success)',
  hint: 'var(--success)',
  important: 'var(--success)',
  success: 'var(--success)',
  check: 'var(--success)',
  done: 'var(--success)',
  question: 'var(--warning)',
  help: 'var(--warning)',
  faq: 'var(--warning)',
  warning: 'var(--warning)',
  caution: 'var(--warning)',
  attention: 'var(--warning)',
  failure: 'var(--error)',
  fail: 'var(--error)',
  missing: 'var(--error)',
  danger: 'var(--error)',
  error: 'var(--error)',
  bug: 'var(--error)',
  example: 'var(--accent)',
  quote: 'var(--fg-subtle)',
  cite: 'var(--fg-subtle)',
}

const CALLOUT_ICONS: Record<string, string> = {
  note: '✎',
  info: 'ℹ',
  tip: '★',
  hint: '★',
  success: '✓',
  check: '✓',
  done: '✓',
  question: '?',
  help: '?',
  faq: '?',
  warning: '⚠',
  caution: '⚠',
  attention: '⚠',
  failure: '✗',
  fail: '✗',
  danger: '⚡',
  error: '⚡',
  bug: '🐞',
  example: '❯',
  quote: '❝',
  todo: '☐',
  abstract: '≡',
  summary: '≡',
  tldr: '≡',
  important: '❗',
  missing: '✗',
  cite: '❝',
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => {
    switch (c) {
      case '&':
        return '&amp;'
      case '<':
        return '&lt;'
      case '>':
        return '&gt;'
      case '"':
        return '&quot;'
      default:
        return '&#39;'
    }
  })
}

function createMd(): MarkdownIt {
  const md = new MarkdownIt({
    // Obsidian renders inline HTML in notes, and the callout/columns
    // preprocessor below emits HTML of its own. Everything is run through
    // `sanitize()` before it reaches the DOM, and the renderer's CSP
    // (`script-src 'self'`) blocks inline scripts and event handlers outright.
    html: true,
    linkify: true,
    breaks: false,
    typographer: false,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) {
        try {
          return `<pre><code class="hljs language-${escapeHtml(lang)}">${hljs.highlight(code, { language: lang }).value}</code></pre>`
        } catch {
          /* fall through */
        }
      }
      return `<pre><code class="hljs">${escapeHtml(code)}</code></pre>`
    },
  })

  // ==highlight==
  md.inline.ruler.before('emphasis', 'mark', (state, silent) => {
    const src = state.src
    if (src.charCodeAt(state.pos) !== 0x3d || src.charCodeAt(state.pos + 1) !== 0x3d) return false
    const end = src.indexOf('==', state.pos + 2)
    if (end < 0) return false
    if (!silent) {
      state.push('mark_open', 'mark', 1)
      const t = state.push('text', '', 0)
      t.content = src.slice(state.pos + 2, end)
      state.push('mark_close', 'mark', -1)
    }
    state.pos = end + 2
    return true
  })

  // $inline math$ and $$block math$$
  md.inline.ruler.before('escape', 'math_inline', (state, silent) => {
    const src = state.src
    if (src.charCodeAt(state.pos) !== 0x24) return false
    const dollars = src.startsWith('$$', state.pos) ? 2 : 1
    const close = src.indexOf(dollars === 2 ? '$$' : '$', state.pos + dollars)
    if (close < 0) return false
    const content = src.slice(state.pos + dollars, close)
    if (!content.trim()) return false
    if (!silent) {
      const token = state.push('math_inline', 'span', 0)
      token.content = content
      token.markup = dollars === 2 ? '$$' : '$'
    }
    state.pos = close + dollars
    return true
  })

  md.renderer.rules.math_inline = (tokens, idx) => {
    try {
      return katex.renderToString(tokens[idx].content, {
        displayMode: tokens[idx].markup === '$$',
        throwOnError: false,
      })
    } catch {
      return escapeHtml(tokens[idx].content)
    }
  }

  return md
}

const md = createMd()

/** Pre-pass: turn Onyx/Obsidian block syntax into HTML markdown-it passes through. */
function preprocessBlocks(source: string): string {
  const lines = source.split('\n')
  const out: string[] = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i]

    // ::: columns … +++ … :::
    if (/^:::\s*columns\s*$/i.test(line.trim())) {
      const body: string[] = []
      i++
      while (i < lines.length && lines[i].trim() !== ':::') body.push(lines[i++])
      i++ // closing :::
      const cols = body.join('\n').split(/^\+\+\+\s*$/m)
      out.push('<div class="columns-block">')
      for (const col of cols) out.push(`<div>\n\n${col.trim()}\n\n</div>`)
      out.push('</div>')
      continue
    }

    // > [!type]±  Title
    const callout = /^>\s*\[!([A-Za-z-]+)\]([+-]?)\s*(.*)$/.exec(line)
    if (callout) {
      const type = callout[1].toLowerCase()
      const fold = callout[2]
      const title = callout[3].trim() || type[0].toUpperCase() + type.slice(1)
      const body: string[] = []
      i++
      while (i < lines.length && /^>/.test(lines[i])) {
        body.push(lines[i].replace(/^>\s?/, ''))
        i++
      }
      const color = CALLOUT_COLORS[type] ?? 'var(--accent)'
      const icon = CALLOUT_ICONS[type] ?? '●'
      const collapsible = fold === '-' || fold === '+'
      const classes = [
        'callout',
        collapsible ? 'is-collapsible' : '',
        fold === '-' ? 'is-collapsed' : '',
      ]
        .filter(Boolean)
        .join(' ')
      out.push(`<div class="${classes}" data-callout="${escapeHtml(type)}" style="--callout-color:${color}">`)
      out.push(
        `<div class="callout-title"><span class="callout-icon">${icon}</span><span>${escapeHtml(title)}</span>${collapsible ? '<span class="callout-fold">▾</span>' : ''}</div>`,
      )
      out.push(`<div class="callout-content">\n\n${body.join('\n')}\n\n</div>`)
      out.push('</div>')
      continue
    }

    out.push(line)
    i++
  }
  return out.join('\n')
}

/** Inline pass over the produced HTML for wikilinks, embeds and tags. */
function postprocessInline(html: string, ctx: RenderContext): string {
  // Embeds first (they consume the whole `![[…]]`).
  html = html.replace(/!\[\[([^[\]]+?)\]\]/g, (_m, inner: string) => {
    const [rawTarget] = String(inner).split('|')
    const target = rawTarget.trim()
    const url = ctx.fileUrl(target)
    if (url) return `<img class="embed-image" src="${escapeHtml(url)}" alt="${escapeHtml(target)}" />`
    const body = ctx.embed(target)
    if (body === null) {
      return `<span class="internal-link is-unresolved">![[${escapeHtml(target)}]]</span>`
    }
    return `<div class="embed"><div class="embed-title">${escapeHtml(target)}</div>${renderInner(body, ctx)}</div>`
  })

  html = html.replace(/\[\[([^[\]]+?)\]\]/g, (_m, inner: string) => {
    const parts = String(inner).split('|')
    const target = parts[0].trim()
    const label = (parts[1] ?? target).trim()
    const resolved = ctx.resolve(target)
    const cls = resolved ? 'internal-link' : 'internal-link is-unresolved'
    return `<a class="${cls}" data-href="${escapeHtml(target)}" href="#">${escapeHtml(label)}</a>`
  })

  // Tags, skipping anything inside a tag attribute or code block.
  html = html.replace(
    /(^|[\s(>])#([A-Za-z][\w/-]*)/g,
    (m, pre: string, tag: string) =>
      `${pre}<a class="tag-pill" data-tag="${escapeHtml(tag)}" href="#">#${escapeHtml(tag)}</a>`,
  )

  return html
}

function renderInner(source: string, ctx: RenderContext): string {
  return postprocessInline(md.render(preprocessBlocks(source)), ctx)
}

/**
 * Defense in depth for the HTML that reaches `dangerouslySetInnerHTML`: drop
 * executable elements, inline event handlers, and `javascript:` URLs. The CSP
 * already blocks all three; this makes a note that carries them render as
 * inert markup rather than silently doing nothing.
 */
function sanitize(html: string): string {
  const doc = new DOMParser().parseFromString(html, 'text/html')
  const banned = doc.body.querySelectorAll(
    'script, iframe, object, embed, link, meta, base, form, input:not([type="checkbox"]), style',
  )
  banned.forEach((el) => el.remove())
  const all = doc.body.querySelectorAll('*')
  all.forEach((el) => {
    for (const attr of [...el.attributes]) {
      const name = attr.name.toLowerCase()
      if (name.startsWith('on')) el.removeAttribute(attr.name)
      else if (
        (name === 'href' || name === 'src' || name === 'xlink:href') &&
        /^\s*javascript:/i.test(attr.value)
      ) {
        el.removeAttribute(attr.name)
      }
    }
  })
  return doc.body.innerHTML
}

/** The frontmatter properties block Obsidian shows above the note body. */
function renderProperties(source: string): string {
  const props = extractFrontmatterProperties(source)
  if (!props.length) return ''
  const rows = props
    .map(([key, values]) => {
      const vals = values.length
        ? values.map((v) => `<span class="prop-chip">${escapeHtml(v)}</span>`).join('')
        : '<span style="color:var(--fg-subtle)">—</span>'
      return `<div class="properties-row"><div class="properties-key">${escapeHtml(key)}</div><div class="properties-val">${vals}</div></div>`
    })
    .join('')
  return `<div class="properties">${rows}</div>`
}

export function renderMarkdown(
  source: string,
  ctx: RenderContext,
  opts: { showFrontmatter?: boolean } = {},
): string {
  const fmLen = frontmatterLength(source)
  const body = fmLen > 0 ? source.slice(fmLen) : source
  const head = opts.showFrontmatter !== false && fmLen > 0 ? renderProperties(source) : ''
  let html = renderInner(body, ctx)

  // Task list items: markdown-it emits `[ ]` as literal text.
  html = html.replace(
    /<li>\s*\[( |x|X)\]\s?/g,
    (_m, mark: string) =>
      `<li class="task-list-item${mark !== ' ' ? ' is-done' : ''}"><input type="checkbox" ${mark !== ' ' ? 'checked' : ''} />`,
  )

  return sanitize(head + html)
}
