/**
 * The Agent pane's conversation: what was asked, and what Claude Code or
 * Antigravity did and said back, built from the events main/agents.ts
 * sends. Kept outside the view so a turn keeps running (and is still there)
 * when the pane's tab isn't on screen.
 */

import { create } from 'zustand'
import type { AgentEvent, AgentId } from '@shared/types'
import { useStore } from '../store'

export interface ToolStep {
  id: string
  name: string
  summary: string
  state: 'running' | 'done' | 'error'
  detail?: string
  writes: boolean
}

/** A turn's reply: text and tool steps in the order they happened. */
export type ReplyPart = { kind: 'text'; text: string } | { kind: 'tool'; step: ToolStep }

export type Turn =
  | { role: 'user'; id: string; text: string; notePath: string | null }
  | {
      role: 'agent'
      id: string
      agent: AgentId
      parts: ReplyPart[]
      running: boolean
      thinking: boolean
      error?: string
      costUsd?: number
      denied?: string[]
    }

interface AgentState {
  agent: AgentId
  /** The CLI's session, so the next turn continues the conversation. */
  sessionId: string | null
  /** The agent the session belongs to (a session can't move between them). */
  sessionAgent: AgentId | null
  turns: Turn[]
  runId: string | null
  available: { claude: boolean; antigravity: boolean } | null

  setAgent(agent: AgentId): void
  send(prompt: string, notePath: string | null): void
  stop(): void
  reset(): void
}

let counter = 0
const uid = (): string => `agent-${Date.now().toString(36)}-${counter++}`

export const useAgent = create<AgentState>((set, get) => ({
  agent: 'claude',
  sessionId: null,
  sessionAgent: null,
  turns: [],
  runId: null,
  available: null,

  setAgent(agent) {
    set({ agent })
  },

  send(prompt, notePath) {
    const text = prompt.trim()
    if (!text || get().runId) return
    const st = get()
    const settings = useStore.getState().settings?.agents
    const runId = uid()
    const reply: Turn = { role: 'agent', id: runId, agent: st.agent, parts: [], running: true, thinking: false }
    set({
      runId,
      turns: [...st.turns, { role: 'user', id: uid(), text, notePath }, reply],
    })
    void window.onyx.agent.run({
      runId,
      agent: st.agent,
      prompt: text,
      sessionId: st.sessionAgent === st.agent ? st.sessionId : null,
      model: (st.agent === 'claude' ? settings?.claudeModel : settings?.antigravityModel) ?? '',
      notePath,
      allowEdits: settings?.allowEdits !== false,
    })
  },

  stop() {
    const runId = get().runId
    if (runId) void window.onyx.agent.stop(runId)
  },

  reset() {
    get().stop()
    set({ sessionId: null, sessionAgent: null, turns: [], runId: null })
  },
}))

/** Folds one event into the turn it belongs to. */
export function applyAgentEvent(runId: string, event: AgentEvent): void {
  const st = useAgent.getState()
  const turns = st.turns.map((t) => {
    if (t.role !== 'agent' || t.id !== runId) return t
    const turn = { ...t, parts: [...t.parts] }
    switch (event.kind) {
      case 'text': {
        const last = turn.parts[turn.parts.length - 1]
        if (last?.kind === 'text') turn.parts[turn.parts.length - 1] = { kind: 'text', text: last.text + event.delta }
        else turn.parts.push({ kind: 'text', text: event.delta })
        turn.thinking = false
        break
      }
      case 'thinking':
        turn.thinking = true
        break
      case 'tool': {
        const { kind: _k, ...step } = event
        const i = turn.parts.findIndex((p) => p.kind === 'tool' && p.step.id === step.id)
        if (i >= 0) turn.parts[i] = { kind: 'tool', step }
        else turn.parts.push({ kind: 'tool', step })
        turn.thinking = false
        break
      }
      case 'done':
        turn.running = false
        turn.thinking = false
        turn.error = event.error
        turn.costUsd = event.costUsd
        turn.denied = event.denied
        break
      case 'error':
        turn.running = false
        turn.thinking = false
        turn.error = event.message
        break
    }
    return turn
  })
  const patch: Partial<AgentState> = { turns }
  if (event.kind === 'session') {
    const turn = st.turns.find((t) => t.id === runId)
    if (turn?.role === 'agent') Object.assign(patch, { sessionId: event.id, sessionAgent: turn.agent })
  }
  if (event.kind === 'done' && event.sessionId) {
    const turn = st.turns.find((t) => t.id === runId)
    if (turn?.role === 'agent') Object.assign(patch, { sessionId: event.sessionId, sessionAgent: turn.agent })
  }
  if ((event.kind === 'done' || event.kind === 'error') && st.runId === runId) patch.runId = null
  useAgent.setState(patch)
  // A note the agent wrote: pick up the change now rather than at the next poll.
  if (event.kind === 'tool' && event.writes && event.state === 'done') void useStore.getState().refreshVault()
}

let listening = false

/** Starts routing agent events into the store (once). */
export function listenForAgents(): void {
  if (listening) return
  listening = true
  window.onyx.agent.onEvent(applyAgentEvent)
  void window.onyx.agent.available().then((available) => {
    useAgent.setState({ available })
    const preferred = useStore.getState().settings?.agents?.default
    if (preferred && available[preferred]) useAgent.setState({ agent: preferred })
    else if (!available.claude && available.antigravity) useAgent.setState({ agent: 'antigravity' })
  })
}
