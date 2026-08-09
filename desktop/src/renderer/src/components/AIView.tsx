/**
 * The AI pane: a streaming chat over your notes, powered by a local model via
 * Ollama. Includes `/ask` (semantic RAG across the whole vault, with cited
 * sources), summarize, and rewrite-in-place. Port of the TUI's Ctrl-A pane.
 */

import { useEffect, useRef, useState } from 'react'
import { useStore, type Tab } from '../store'
import { Icon } from './Icon'
import { renderMarkdown } from '../editor/render'

interface Message {
  role: 'user' | 'assistant'
  content: string
  thinking?: string
  sources?: Array<{ path: string; line: number; title: string }>
  error?: string | null
  streaming?: boolean
}

let counter = 0
const nextId = (): string => `ai-${Date.now()}-${counter++}`

export function AIView({ tab }: { tab: Tab }): JSX.Element {
  const [messages, setMessages] = useState<Message[]>([])
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const [ragProgress, setRagProgress] = useState<{ done: number; total: number } | null>(null)
  const activeId = useRef<string | null>(null)
  const logRef = useRef<HTMLDivElement>(null)

  // Prefer a markdown tab that's actually on screen; fall back to the last one
  // focused, so opening the AI pane doesn't drop the note as context.
  const notePath = useStore((s) => {
    for (const pane of s.panes) {
      const t = pane.tabs.find((x) => x.id === pane.activeTabId)
      if (t?.type === 'markdown' && t.path) return t.path
    }
    return s.lastNotePath
  })
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const setStatus = useStore((s) => s.setStatus)
  const settings = useStore((s) => s.settings)

  // Stream plumbing.
  useEffect(() => {
    const offChunk = window.onyx.ai.onChunk((id, chunk) => {
      if (id !== activeId.current) return
      setMessages((prev) => {
        const next = [...prev]
        const last = next[next.length - 1]
        if (!last || last.role !== 'assistant') return prev
        next[next.length - 1] = {
          ...last,
          content: last.content + chunk.content,
          thinking: (last.thinking ?? '') + chunk.thinking,
        }
        return next
      })
    })
    const offDone = window.onyx.ai.onDone((id, error) => {
      if (id !== activeId.current) return
      activeId.current = null
      setBusy(false)
      setMessages((prev) => {
        const next = [...prev]
        const last = next[next.length - 1]
        if (last?.role === 'assistant') next[next.length - 1] = { ...last, streaming: false, error }
        return next
      })
    })
    const offSources = window.onyx.ai.onSources((id, hits) => {
      if (id !== activeId.current) return
      setMessages((prev) => {
        const next = [...prev]
        const last = next[next.length - 1]
        if (last?.role === 'assistant')
          next[next.length - 1] = {
            ...last,
            sources: hits as Array<{ path: string; line: number; title: string }>,
          }
        return next
      })
    })
    const offProgress = window.onyx.ai.onProgress((_id, p) => setRagProgress(p))
    return () => {
      offChunk()
      offDone()
      offSources()
      offProgress()
    }
  }, [])

  useEffect(() => {
    logRef.current?.scrollTo({ top: logRef.current.scrollHeight })
  }, [messages])

  const beginAssistant = (): string => {
    const id = nextId()
    activeId.current = id
    setBusy(true)
    setMessages((prev) => [...prev, { role: 'assistant', content: '', streaming: true }])
    return id
  }

  const send = (text: string): void => {
    if (!text.trim() || busy) return
    const history = messages
      .filter((m) => !m.error)
      .map((m) => ({ role: m.role, content: m.content }))
    setMessages((prev) => [...prev, { role: 'user', content: text }])
    setDraft('')

    if (text.trim().startsWith('/ask ')) {
      const q = text.trim().slice(5)
      const id = beginAssistant()
      void window.onyx.ai.ask(id, q)
      return
    }
    if (text.trim() === '/summarize') {
      if (!notePath) {
        setStatus('Open a note first')
        return
      }
      const id = beginAssistant()
      void window.onyx.ai.summarize(id, notePath)
      return
    }
    if (text.trim() === '/index') {
      const id = nextId()
      setRagProgress({ done: 0, total: 0 })
      void window.onyx.ai
        .buildRag(id)
        .then((r) => {
          setRagProgress(null)
          setMessages((prev) => [
            ...prev,
            {
              role: 'assistant',
              content: `Indexed **${r.total}** notes (${r.embedded} new chunks embedded). \`/ask\` is ready.`,
            },
          ])
        })
        .catch((e: Error) => {
          setRagProgress(null)
          setMessages((prev) => [...prev, { role: 'assistant', content: '', error: e.message }])
        })
      return
    }

    const id = beginAssistant()
    void window.onyx.ai.chat(id, [...history, { role: 'user', content: text }], {
      notePath: notePath ?? undefined,
    })
  }

  // `AI: summarize this note` / `AI: ask my vault` open this pane with a
  // pending action; run it once, then clear it so a tab switch doesn't repeat.
  const pending = tab.state.pending as { kind: string; path?: string } | undefined
  useEffect(() => {
    if (!pending) return
    tab.state.pending = undefined
    if (pending.kind === 'summarize') send('/summarize')
    else if (pending.kind === 'ask') setDraft('/ask ')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pending])

  const cancel = (): void => {
    if (activeId.current) void window.onyx.ai.cancel(activeId.current)
    activeId.current = null
    setBusy(false)
  }

  const rewriteSelection = async (): Promise<void> => {
    if (!notePath) return setStatus('Open a note first')
    const doc = useStore.getState().docs.get(notePath)
    if (!doc) return
    const selection = window.getSelection()?.toString()
    const target = selection && selection.trim() ? selection : doc.content
    setStatus('Rewriting…')
    try {
      const out = await window.onyx.ai.rewrite(target, 'improve clarity and flow')
      if (!out) return setStatus('The model returned nothing')
      const next = selection && selection.trim() ? doc.content.replace(selection, out) : out
      useStore.getState().setDoc(notePath, next)
      setStatus('Rewritten — Ctrl+Z to undo')
    } catch (e) {
      setStatus((e as Error).message)
    }
  }

  return (
    <div className="ai-view">
      <div className="ai-toolbar">
        <Icon name="bot" size={14} />
        <span>{settings?.ai.model}</span>
        <div style={{ flex: 1 }} />
        {notePath && <span className="chip">context: {notePath.split('/').pop()}</span>}
        <button className="chip" onClick={() => send('/summarize')} disabled={busy}>
          Summarize
        </button>
        <button className="chip" onClick={() => void rewriteSelection()}>
          Rewrite
        </button>
        <button className="chip" onClick={() => send('/index')} disabled={busy}>
          Index vault
        </button>
      </div>

      <div className="ai-log" ref={logRef}>
        {!messages.length && (
          <div className="empty-note">
            Ask about the open note, or use <code>/ask …</code> to search the whole vault (run{' '}
            <code>/index</code> once first), <code>/summarize</code> for the current note, and the
            Rewrite button on a selection.
          </div>
        )}
        {ragProgress && (
          <div className="ai-msg">
            <span className="spinner" /> Embedding {ragProgress.done}/{ragProgress.total} chunks…
          </div>
        )}
        {messages.map((m, i) => (
          <div className={`ai-msg ${m.role}`} key={i}>
            <div className="who">{m.role === 'user' ? 'You' : 'Onyx'}</div>
            {m.thinking && <div className="ai-thinking">{m.thinking}</div>}
            {m.role === 'user' ? (
              <div className="bubble">{m.content}</div>
            ) : (
              <div
                className="rendered"
                dangerouslySetInnerHTML={{
                  __html: renderMarkdown(m.content, {
                    path: notePath ?? '',
                    resolve: (t) =>
                      [...notes.keys()].find(
                        (p) => p.replace(/\.md$/i, '').toLowerCase() === t.toLowerCase(),
                      ) ?? null,
                    fileUrl: () => null,
                    embed: () => null,
                  }),
                }}
              />
            )}
            {m.streaming && !m.content && <span className="spinner" />}
            {m.error && <div style={{ color: 'var(--error)' }}>{m.error}</div>}
            {m.sources && m.sources.length > 0 && (
              <div className="ai-sources">
                {m.sources.map((s, k) => (
                  <span
                    key={k}
                    style={{ cursor: 'pointer' }}
                    onClick={() => void openFile(s.path)}
                  >
                    [{k + 1}] {s.path}:{s.line + 1}
                  </span>
                ))}
              </div>
            )}
          </div>
        ))}
      </div>

      <div className="ai-input">
        <textarea
          rows={2}
          value={draft}
          placeholder="Ask Onyx…  (/ask, /summarize, /index)"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              send(draft)
            }
          }}
        />
        {busy ? (
          <button className="btn" onClick={cancel}>
            Stop
          </button>
        ) : (
          <button className="btn primary" onClick={() => send(draft)}>
            Send
          </button>
        )}
      </div>
    </div>
  )
}
