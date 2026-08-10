/**
 * A markdown tab: Live Preview, Source, or Reading — Obsidian's three modes.
 *
 * Live Preview and Source share one CodeMirror instance (they differ only in
 * whether the decoration layer hides syntax markers). Reading swaps in the
 * HTML renderer.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { EditorState, Compartment, Prec, type Extension } from '@codemirror/state'
import { EditorView, keymap, drawSelection, highlightActiveLine, rectangularSelection, dropCursor, lineNumbers, highlightActiveLineGutter } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { languages } from '@codemirror/language-data'
import { HighlightStyle, syntaxHighlighting, bracketMatching, indentUnit } from '@codemirror/language'
import { tags as t } from '@lezer/highlight'
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from '@codemirror/autocomplete'
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search'
import { vim } from '@replit/codemirror-vim'

import { useStore, type Tab } from '../store'
import {
  blockWidgets,
  hostField,
  markdownDecorations,
  setHost,
  type EditorHost,
} from './decorations'

import { slashCompletion, tagCompletion, wikilinkCompletion } from './completions'
import { ghostAutocomplete, ghostField, ghostKeymap } from './ghost'
import { renderMarkdown, type RenderContext } from './render'
import { assetUrl, onAssetLoaded } from '../lib/assets'
import { toggleTaskOnLine } from '../lib/notes'
import { frontmatterLength } from '@shared/parse'

/** Decoration layers for a mode: Live Preview also renders the block widgets. */
function livePreviewExtensions(live: boolean): Extension {
  return live ? [markdownDecorations(true), blockWidgets] : markdownDecorations(false)
}


const highlightStyle = HighlightStyle.define([
  { tag: t.keyword, color: 'var(--accent)' },
  { tag: [t.name, t.deleted, t.character, t.propertyName, t.macroName], color: 'var(--fg)' },
  { tag: [t.function(t.variableName), t.labelName], color: 'var(--info)' },
  { tag: [t.color, t.constant(t.name), t.standard(t.name)], color: 'var(--accent-alt)' },
  { tag: [t.definition(t.name), t.separator], color: 'var(--fg-dim)' },
  { tag: [t.typeName, t.className, t.number, t.changed, t.annotation, t.self, t.namespace], color: 'var(--warning)' },
  { tag: [t.operator, t.operatorKeyword, t.url, t.escape, t.regexp, t.link], color: 'var(--link)' },
  { tag: [t.meta, t.comment], color: 'var(--fg-subtle)', fontStyle: 'italic' },
  { tag: t.strong, fontWeight: 'bold' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.strikethrough, textDecoration: 'line-through' },
  { tag: t.heading, fontWeight: 'bold', color: 'var(--heading)' },
  { tag: [t.atom, t.bool], color: 'var(--accent-alt)' },
  { tag: [t.processingInstruction, t.string, t.inserted], color: 'var(--success)' },
  { tag: t.invalid, color: 'var(--error)' },
])

const baseTheme = EditorView.theme({
  '&': { height: '100%' },
  // CodeMirror's base theme hardcodes a monospace scroller; this is scoped to
  // the generated theme class, so it wins without an `!important`.
  '.cm-scroller': { overflow: 'auto', fontFamily: 'var(--font-text)' },
  // Same reason: CodeMirror's base theme paints a pale blue active line and a
  // blue selection, neither of which belongs in a themed note editor.
  '.cm-activeLine': { backgroundColor: 'transparent' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': {
    backgroundColor: 'var(--selection)',
  },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--accent)' },
})

export function MarkdownView({ tab }: { tab: Tab }): JSX.Element {
  const mode = tab.mode ?? 'livePreview'
  return mode === 'reading' ? <ReadingView tab={tab} /> : <CodeMirrorView tab={tab} mode={mode} />
}

// ------------------------------------------------------------- CodeMirror

function CodeMirrorView({ tab, mode }: { tab: Tab; mode: 'livePreview' | 'source' }): JSX.Element {
  const path = tab.path!
  const hostRef = useRef<HTMLDivElement>(null)
  const viewRef = useRef<EditorView | null>(null)
  const modeComp = useRef(new Compartment())
  const vimComp = useRef(new Compartment())
  const gutterComp = useRef(new Compartment())

  const doc = useStore((s) => s.docs.get(path))
  const settings = useStore((s) => s.settings)
  const setDoc = useStore((s) => s.setDoc)
  const saveDoc = useStore((s) => s.saveDoc)
  const openFile = useStore((s) => s.openFile)
  const notes = useStore((s) => s.notes)

  const host: EditorHost = useMemo(
    () => ({
      resolve: (target) => resolveSync(target, path),
      openLink: (target, newTab) => {
        void (async () => {
          const resolved = await window.onyx.vault.resolve(target, path)
          if (resolved) {
            void openFile(resolved, { newTab })
            return
          }
          // Obsidian creates the note on click when it doesn't exist yet.
          const dir = path.split('/').slice(0, -1).join('/')
          const rel = `${target.replace(/[#^].*$/, '')}.md`
          const full = dir ? `${dir}/${rel}` : rel
          await window.onyx.file.create(full, `# ${target}\n\n`)
          await useStore.getState().refreshVault()
          void openFile(full, { newTab })
        })()
      },
      openTag: (tag) => {
        useStore.getState().setLeftPanel('search')
        useStore.setState({ modal: { kind: 'search', initial: `tag:${tag}` } })
      },
      imageSrc: (target) => {
        const rel = target.replace(/^\.\//, '')
        return assetUrl(rel)
      },
      toggleTask: (line) => {
        const current = useStore.getState().docs.get(path)
        if (!current) return
        const next = toggleTaskOnLine(current.content, line)
        if (next !== current.content) {
          const view = viewRef.current
          if (view) {
            view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: next } })
          }
        }
      },
    }),
    [path, openFile],
  )

  const resolveSync = useCallback(
    (target: string, from: string): string | null => {
      const name = target.replace(/[#^].*$/, '').trim().toLowerCase()
      if (!name) return null
      for (const key of notes.keys()) {
        if (key.replace(/\.md$/i, '').toLowerCase() === name) return key
      }
      const dir = from.split('/').slice(0, -1).join('/')
      const sameFolder = `${dir ? `${dir}/` : ''}${name}.md`.toLowerCase()
      for (const key of notes.keys()) {
        if (key.toLowerCase() === sameFolder) return key
      }
      for (const key of notes.keys()) {
        const base = (key.split('/').pop() ?? '').replace(/\.md$/i, '').toLowerCase()
        if (base === name) return key
      }
      for (const [key, meta] of notes) {
        if (meta.aliases.some((a) => a.toLowerCase() === name)) return key
      }
      return null
    },
    [notes],
  )

  // Build the editor once per tab.
  useLayoutEffect(() => {
    const parent = hostRef.current
    if (!parent) return

    const initial = doc?.content ?? ''
    // Start the cursor at the top of the body, not inside the frontmatter —
    // otherwise Live Preview opens showing raw YAML instead of properties.
    const bodyStart = Math.min(frontmatterLength(initial), initial.length)

    const state = EditorState.create({
      doc: initial,
      selection: { anchor: bodyStart },
      extensions: [
        hostField,
        ghostField,
        history(),
        drawSelection(),
        dropCursor(),
        rectangularSelection(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        bracketMatching(),
        closeBrackets(),
        EditorState.allowMultipleSelections.of(true),
        indentUnit.of(settings?.useSpaces === false ? '\t' : ' '.repeat(settings?.tabSize ?? 4)),
        EditorView.lineWrapping,
        markdown({ base: markdownLanguage, codeLanguages: languages, addKeymap: true }),
        syntaxHighlighting(highlightStyle),
        gutterComp.current.of(settings?.lineNumbers ? [lineNumbers(), highlightActiveLineGutter()] : []),
        vimComp.current.of(settings?.vimMode ? vim() : []),
        modeComp.current.of(livePreviewExtensions(mode === 'livePreview')),
        autocompletion({
          override: [wikilinkCompletion, tagCompletion, slashCompletion],
          activateOnTyping: true,
          maxRenderedOptions: 60,
          icons: false,
        }),
        ghostAutocomplete(() => Boolean(useStore.getState().settings?.ai.autocomplete)),
        ghostKeymap,
        Prec.high(
          keymap.of([
            {
              key: 'Mod-s',
              run: () => {
                void saveDoc(path)
                return true
              },
            },
            {
              key: 'Mod-Enter',
              run: (view) => {
                // Follow the wikilink under the cursor, like the TUI's Ctrl-Enter.
                const pos = view.state.selection.main.head
                const line = view.state.doc.lineAt(pos)
                const re = /\[\[([^[\]\n]+?)\]\]/g
                for (let m = re.exec(line.text); m; m = re.exec(line.text)) {
                  const from = line.from + m.index
                  if (pos >= from && pos <= from + m[0].length) {
                    host.openLink(m[1].split('|')[0].trim(), false)
                    return true
                  }
                }
                return false
              },
            },
          ]),
        ),
        keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap, ...completionKeymap, ...searchKeymap, indentWithTab]),
        baseTheme,
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            setDoc(path, update.state.doc.toString())
          }
        }),
      ],
    })

    const view = new EditorView({ state, parent })
    viewRef.current = view
    view.dispatch({ effects: setHost.of(host) })
    view.focus()

    return () => {
      view.destroy()
      viewRef.current = null
    }
    // Rebuilt only when the file changes — everything else reconfigures below.
  }, [path])

  // Mode / settings reconfiguration without losing the buffer or cursor.
  useEffect(() => {
    const view = viewRef.current
    if (!view) return
    view.dispatch({
      effects: [
        modeComp.current.reconfigure(livePreviewExtensions(mode === 'livePreview')),
        vimComp.current.reconfigure(settings?.vimMode ? vim() : []),
        gutterComp.current.reconfigure(
          settings?.lineNumbers ? [lineNumbers(), highlightActiveLineGutter()] : [],
        ),
        setHost.of(host),
      ],
    })
  }, [mode, settings?.vimMode, settings?.lineNumbers, host])

  // External edits (watcher, rename, AI rewrite) replace the buffer.
  useEffect(() => {
    const view = viewRef.current
    if (!view || doc === undefined) return
    const current = view.state.doc.toString()
    if (current !== doc.content) {
      view.dispatch({
        changes: { from: 0, to: current.length, insert: doc.content },
        selection: { anchor: Math.min(view.state.selection.main.anchor, doc.content.length) },
      })
    }
  }, [doc?.content])

  // Autosave after an idle pause.
  useEffect(() => {
    if (!settings?.autosave || !doc?.dirty) return
    const timer = setTimeout(() => void saveDoc(path), settings.autosaveIdleMs)
    return () => clearTimeout(timer)
  }, [doc?.content, doc?.dirty, settings?.autosave, settings?.autosaveIdleMs, path, saveDoc])

  const width = settings?.readableLineLength === false ? 'none' : '720px'
  return (
    <div
      className="markdown-view"
      style={
        {
          '--content-width': width,
          '--editor-font-size': `${settings?.fontSize ?? 16}px`,
        } as React.CSSProperties
      }
    >
      <div
        ref={hostRef}
        style={{ height: '100%' }}
        className={settings?.readableLineLength === false ? 'onyx-wide' : ''}
      />
    </div>
  )
}

// ----------------------------------------------------------- reading view

function ReadingView({ tab }: { tab: Tab }): JSX.Element {
  const path = tab.path!
  const doc = useStore((s) => s.docs.get(path))
  const notes = useStore((s) => s.notes)
  const settings = useStore((s) => s.settings)
  const openFile = useStore((s) => s.openFile)
  const setDoc = useStore((s) => s.setDoc)
  const [, forceRender] = useState(0)
  const [embeds, setEmbeds] = useState<Map<string, string>>(new Map())
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => onAssetLoaded(() => forceRender((n) => n + 1)), [])

  const resolve = useCallback(
    (target: string): string | null => {
      const name = target.replace(/[#^].*$/, '').trim().toLowerCase()
      for (const key of notes.keys()) {
        if (key.replace(/\.md$/i, '').toLowerCase() === name) return key
        const base = (key.split('/').pop() ?? '').replace(/\.md$/i, '').toLowerCase()
        if (base === name) return key
      }
      return null
    },
    [notes],
  )

  // Preload embedded notes so the render pass stays synchronous.
  const content = doc?.content ?? ''
  useEffect(() => {
    const targets = [...content.matchAll(/!\[\[([^[\]|]+)/g)].map((m) => m[1].trim())
    let cancelled = false
    void (async () => {
      const next = new Map(embeds)
      let changed = false
      for (const target of targets) {
        if (next.has(target)) continue
        const resolved = resolve(target)
        if (!resolved) continue
        try {
          next.set(target, await window.onyx.file.read(resolved))
          changed = true
        } catch {
          /* skip */
        }
      }
      if (changed && !cancelled) setEmbeds(next)
    })()
    return () => {
      cancelled = true
    }
  }, [content, resolve])

  const ctx: RenderContext = useMemo(
    () => ({
      path,
      resolve,
      fileUrl: (target) => {
        const clean = target.replace(/^\.\//, '').split('|')[0].trim()
        if (!/\.(png|jpe?g|gif|webp|svg|bmp|avif|pdf|mp4|webm|mp3|wav|ogg)$/i.test(clean)) return null
        const attachments = useStore.getState().attachments
        const hit =
          attachments.find((a) => a.toLowerCase() === clean.toLowerCase()) ??
          attachments.find((a) => (a.split('/').pop() ?? '').toLowerCase() === clean.toLowerCase())
        return hit ? assetUrl(hit) : null
      },
      embed: (target) => embeds.get(target) ?? null,
    }),
    [path, resolve, embeds],
  )

  const html = useMemo(
    () => renderMarkdown(content, ctx, { showFrontmatter: settings?.showFrontmatter !== false }),
    [content, ctx, settings?.showFrontmatter],
  )

  const onClick = (e: React.MouseEvent): void => {
    const target = e.target as HTMLElement
    const link = target.closest('a')
    if (link) {
      e.preventDefault()
      const href = link.getAttribute('data-href')
      const tag = link.getAttribute('data-tag')
      if (href) {
        const resolved = resolve(href)
        if (resolved) void openFile(resolved, { newTab: e.ctrlKey || e.metaKey })
        return
      }
      if (tag) {
        useStore.setState({ modal: { kind: 'search', initial: `tag:${tag}` } })
        return
      }
      const raw = link.getAttribute('href')
      if (raw && /^https?:/i.test(raw)) void window.onyx.url.open(raw)
      return
    }
    const foldable = target.closest('.callout.is-collapsible > .callout-title')
    if (foldable) {
      foldable.parentElement?.classList.toggle('is-collapsed')
      return
    }
    if (target instanceof HTMLInputElement && target.type === 'checkbox') {
      // Map the clicked checkbox back to its source line and toggle it.
      const boxes = [...(ref.current?.querySelectorAll('.task-list-item input') ?? [])]
      const nth = boxes.indexOf(target)
      if (nth < 0) return
      const lines = content.split('\n')
      let seen = -1
      for (let i = 0; i < lines.length; i++) {
        if (/^\s*[-*+]\s+\[[ xX]\]/.test(lines[i])) {
          seen++
          if (seen === nth) {
            setDoc(path, toggleTaskOnLine(content, i))
            void useStore.getState().saveDoc(path)
            return
          }
        }
      }
    }
  }

  return (
    <div
      className="markdown-view"
      style={
        {
          '--content-width': settings?.readableLineLength === false ? 'none' : '720px',
          '--editor-font-size': `${settings?.fontSize ?? 16}px`,
        } as React.CSSProperties
      }
    >
      <div className="markdown-sizer">
        <div
          className="rendered"
          ref={ref}
          onClick={onClick}
          dangerouslySetInnerHTML={{ __html: html }}
        />
      </div>
    </div>
  )
}
