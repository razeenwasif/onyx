/**
 * The Agent pane: Claude Code or Antigravity working on the vault. Ask in
 * plain words; the agent reads, searches and (when allowed) edits notes,
 * and each step it takes shows as a row: the note it read, the one it
 * changed. Notes it mentions open on click. A conversation continues until
 * New conversation; switching agents starts a fresh one with the other.
 */

import { useEffect, useMemo, useRef, useState } from 'react'
import type { AgentId } from '@shared/types'
import { useStore, type Tab } from '../store'
import { useAgent, listenForAgents, type ReplyPart, type Turn } from '../lib/agent'
import { renderMarkdown } from '../editor/render'
import { Icon } from './Icon'

const AGENTS: Array<{ id: AgentId; name: string }> = [
  { id: 'claude', name: 'Claude Code' },
  { id: 'antigravity', name: 'Antigravity' },
]

const SUGGESTIONS = [
  'Summarise this note and add the summary at the top',
  'Find notes that should link to this one and add the links',
  'Turn the tasks in this note into a checklist by priority',
  'Which of my notes cover duality? List them with a line each',
]

export function AgentView({ tab: _tab }: { tab: Tab }): JSX.Element {
  const { agent, turns, runId, available, sessionId, sessionAgent, setAgent, send, stop, reset } = useAgent()
  const notePath = useStore((s) => s.lastNotePath)
  const notes = useStore((s) => s.notes)
  const settings = useStore((s) => s.settings)
  const openFile = useStore((s) => s.openFile)
  const vaultRoot = useStore((s) => s.vault?.root ?? '')
  const [draft, setDraft] = useState('')
  const [withNote, setWithNote] = useState(true)
  const logRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => listenForAgents(), [])
  useEffect(() => inputRef.current?.focus(), [])
  useEffect(() => {
    const log = logRef.current
    if (log) log.scrollTop = log.scrollHeight
  }, [turns])

  const busy = runId !== null
  const context = withNote && notePath && notes.has(notePath) ? notePath : null
  const missing = available && !available[agent]

  const submit = (text = draft): void => {
    if (!text.trim() || busy || missing) return
    send(text, context)
    setDraft('')
  }

  const pick = (id: AgentId): void => {
    if (id === agent) return
    // A conversation belongs to one agent; the other starts afresh.
    if (turns.length) reset()
    setAgent(id)
  }

  /** A path the agent named (vault-relative, absolute or file://) as a note to open. */
  const resolve = (target: string): string | null => {
    let t = decodeURIComponent(target.replace(/^file:\/\//, '')).replace(/#.*$/, '')
    if (vaultRoot && t.startsWith(vaultRoot + '/')) t = t.slice(vaultRoot.length + 1)
    if (notes.has(t)) return t
    const name = t.replace(/\.md$/i, '').toLowerCase()
    for (const key of notes.keys()) {
      if (key.replace(/\.md$/i, '').toLowerCase() === name) return key
      if ((key.split('/').pop() ?? '').replace(/\.md$/i, '').toLowerCase() === name) return key
    }
    return null
  }

  const onLogClick = (e: React.MouseEvent): void => {
    const a = (e.target as HTMLElement).closest('a')
    if (!a) return
    e.preventDefault()
    const href = a.getAttribute('data-href') ?? a.getAttribute('href') ?? ''
    const rel = resolve(href)
    if (rel) void openFile(rel, { newTab: e.metaKey || e.ctrlKey })
    else if (/^https?:/i.test(href)) void window.onyx.url.open(href)
  }

  return (
    <div className="agent-view">
      <header className="agent-head">
        <div className="agent-picker" role="tablist" aria-label="Agent">
          {AGENTS.map((a) => (
            <button
              key={a.id}
              type="button"
              role="tab"
              aria-selected={agent === a.id}
              className={agent === a.id ? 'is-on' : ''}
              disabled={busy}
              onClick={() => pick(a.id)}
              title={available && !available[a.id] ? `${a.name} isn’t installed` : a.name}
            >
              <span className={`agent-dot is-${a.id}`} aria-hidden="true" />
              {a.name}
            </button>
          ))}
        </div>
        <span className="agent-meta">
          {settings?.agents?.allowEdits === false ? 'Read only' : 'Can edit notes'}
          {sessionId && sessionAgent === agent ? ' · continuing' : ''}
        </span>
        <button type="button" className="agent-new" onClick={reset} disabled={!turns.length}>
          <Icon name="plus" size={13} />
          New conversation
        </button>
      </header>

      <div className="agent-log" ref={logRef} onClick={onLogClick}>
        {!turns.length && (
          <div className="agent-empty">
            <h2>What should {AGENTS.find((a) => a.id === agent)?.name} do in your vault?</h2>
            <p>
              It reads, searches and {settings?.agents?.allowEdits === false ? 'plans changes to' : 'edits'} your notes
              in <b>{useStore.getState().vault?.name ?? 'the vault'}</b>. It can’t run commands.
            </p>
            {missing && (
              <p className="agent-warn">
                {agent === 'claude'
                  ? 'Claude Code isn’t installed: install it from claude.com/claude-code, then sign in with `claude` in a terminal.'
                  : 'Antigravity’s CLI isn’t installed: install Antigravity, then run `agy` once in a terminal to sign in.'}
              </p>
            )}
            <div className="agent-suggestions">
              {SUGGESTIONS.map((s) => (
                <button key={s} type="button" disabled={Boolean(missing)} onClick={() => submit(s)}>
                  {s}
                </button>
              ))}
            </div>
          </div>
        )}
        {turns.map((t) => (t.role === 'user' ? <UserTurn key={t.id} turn={t} /> : <AgentTurn key={t.id} turn={t} resolve={resolve} />))}
      </div>

      <div className="agent-composer">
        {notePath && notes.has(notePath) && (
          <button
            type="button"
            className={`agent-context${withNote ? ' is-on' : ''}`}
            onClick={() => setWithNote(!withNote)}
            title={withNote ? 'The agent is told this note is open. Click to leave it out.' : 'Tell the agent which note is open'}
          >
            <Icon name="note" size={12} />
            {notePath.split('/').pop()?.replace(/\.md$/i, '')}
            {!withNote && ' (left out)'}
          </button>
        )}
        <div className="agent-input">
          <textarea
            ref={inputRef}
            rows={2}
            value={draft}
            placeholder={missing ? 'Install the agent to start' : 'Ask the agent to find, write or tidy notes…'}
            disabled={Boolean(missing)}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault()
                submit()
              }
            }}
          />
          {busy ? (
            <button type="button" className="btn" onClick={stop}>
              Stop
            </button>
          ) : (
            <button type="button" className="btn primary" disabled={!draft.trim() || Boolean(missing)} onClick={() => submit()}>
              Send
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

function UserTurn({ turn }: { turn: Extract<Turn, { role: 'user' }> }): JSX.Element {
  return (
    <div className="agent-turn is-user">
      <div className="agent-bubble">{turn.text}</div>
      {turn.notePath && <div className="agent-turn-note">with {turn.notePath.split('/').pop()?.replace(/\.md$/i, '')} open</div>}
    </div>
  )
}

function AgentTurn({
  turn,
  resolve,
}: {
  turn: Extract<Turn, { role: 'agent' }>
  resolve: (target: string) => string | null
}): JSX.Element {
  const touched = useMemo(() => {
    const files = new Set<string>()
    for (const p of turn.parts) if (p.kind === 'tool' && p.step.writes && p.step.state === 'done' && p.step.summary) files.add(p.step.summary)
    return [...files]
  }, [turn.parts])

  return (
    <div className="agent-turn is-agent">
      <div className="agent-who">
        <span className={`agent-dot is-${turn.agent}`} aria-hidden="true" />
        {turn.agent === 'claude' ? 'Claude Code' : 'Antigravity'}
      </div>
      {turn.parts.map((part, i) => (
        <Part key={i} part={part} resolve={resolve} />
      ))}
      {turn.running && (
        <div className="agent-working">
          <span className="spinner" />
          {turn.thinking ? 'Thinking…' : turn.parts.length ? 'Working…' : 'Starting…'}
        </div>
      )}
      {turn.error && turn.error !== 'Stopped' && <div className="agent-error">{turn.error}</div>}
      {turn.error === 'Stopped' && <div className="agent-foot">Stopped.</div>}
      {!turn.running && (touched.length > 0 || turn.denied || turn.costUsd !== undefined) && (
        <div className="agent-foot">
          {touched.length > 0 && (
            <span>
              Changed{' '}
              {touched.map((f, i) => (
                <span key={f}>
                  {i > 0 && ', '}
                  <a href={f} data-href={f}>
                    {f.replace(/\.md$/i, '')}
                  </a>
                </span>
              ))}
            </span>
          )}
          {turn.denied && <span>Not allowed: {turn.denied.join(', ')}</span>}
          {turn.costUsd !== undefined && <span>${turn.costUsd.toFixed(turn.costUsd < 0.1 ? 3 : 2)}</span>}
        </div>
      )}
    </div>
  )
}

const TOOL_VERB: Record<string, string> = {
  Read: 'Read', view_file: 'Read', read_file: 'Read',
  Edit: 'Edited', MultiEdit: 'Edited', edit_file: 'Edited', replace_file_content: 'Edited', multi_replace_file_content: 'Edited', sed_file: 'Edited',
  Write: 'Wrote', write_to_file: 'Wrote', create_file: 'Created',
  Glob: 'Found files', find_by_name: 'Found files', list_dir: 'Listed',
  Grep: 'Searched for', grep_search: 'Searched for',
  WebSearch: 'Searched the web for', search_web: 'Searched the web for',
  WebFetch: 'Read', read_url_content: 'Read',
  run_command: 'Ran', Bash: 'Ran',
}

/** A file name the renderer took for a web address (`.md` is a country's domain). */
const BARE_MD_LINK = /<a href="https?:\/\/[^"]+\.md"[^>]*>([^<]+)<\/a>/g

/** Links to files in the vault (agy writes them as file:// URLs) as note links. */
function noteLinks(text: string, resolve: (target: string) => string | null): string {
  return text.replace(/\[([^\]\n]+)\]\((file:\/\/[^)\s]+)\)/g, (m, label: string, url: string) => {
    const rel = resolve(url)
    return rel ? `[[${rel.replace(/\.md$/i, '')}|${label.replace(/\.md$/i, '').replace(/\|/g, '-')}]]` : label
  })
}

function Part({ part, resolve }: { part: ReplyPart; resolve: (target: string) => string | null }): JSX.Element {
  if (part.kind === 'text') {
    return (
      <div
        className="rendered agent-text"
        dangerouslySetInnerHTML={{
          __html: renderMarkdown(noteLinks(part.text, resolve), {
            path: '',
            resolve,
            fileUrl: () => null,
            embed: () => null,
          }).replace(BARE_MD_LINK, '$1'),
        }}
      />
    )
  }
  const { step } = part
  const verb = TOOL_VERB[step.name] ?? step.name.replace(/_/g, ' ')
  const note = step.summary && resolve(step.summary)
  return (
    <div className={`agent-step is-${step.state}${step.writes ? ' is-write' : ''}`} title={step.detail}>
      <span className="agent-step-mark" aria-hidden="true">
        {step.state === 'running' ? <span className="spinner" /> : step.state === 'error' ? '✕' : '✓'}
      </span>
      <span className="agent-step-verb">{verb}</span>
      {step.summary &&
        (note ? (
          <a href={note} data-href={note}>
            {step.summary.replace(/\.md$/i, '')}
          </a>
        ) : (
          <span className="agent-step-what">{step.summary}</span>
        ))}
      {step.state === 'error' && step.detail && <span className="agent-step-why">{step.detail.split('\n')[0]}</span>}
    </div>
  )
}
