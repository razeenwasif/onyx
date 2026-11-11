/**
 * Fairy, the user's own assistant (desktop-buddies/Lyra), as the Agent
 * pane's third agent.
 *
 * Fairy runs each request as a turn of one of her work sessions in the
 * vault's folder, with her own provider, file tools, sandbox and approvals;
 * the chat shows in her sidebar under the vault's name. Electron reaches her
 * through a private socket in her data folder (Lyra's
 * desktop/electron-link.mjs), one line of JSON each way: `work` and `stop`
 * in; `started`, steps, text, approvals and `done` out. Electron shows an
 * approval but can't answer it: that's done in Fairy, her companion, or on
 * the iPhone she's paired with.
 */

import * as net from 'node:net'
import * as os from 'node:os'
import * as path from 'node:path'
import { statSync } from 'node:fs'

import type { AgentEvent, AgentRunRequest } from '../shared/types.js'

/** Where Fairy listens for Electron. */
export function fairySocketPath(): string {
  const dir = process.env.LYRA_DATA_DIR
  if (dir) return path.join(dir, 'electron.sock')
  return path.join(os.homedir(), 'Library', 'Application Support', 'lyra-companion', 'lyra', 'electron.sock')
}

/** Whether Fairy is running with the Electron link (her socket is there). */
export function fairyAvailable(): boolean {
  try {
    return statSync(fairySocketPath()).isSocket()
  } catch {
    return false
  }
}

/** Fairy's file steps that change notes. */
const WRITES = new Set(['edit', 'write', 'bring-back'])

export interface FairyState {
  /** Her reply so far: she sends the whole text each time, the pane wants what's new. */
  text: string
  chat: string | null
}

export function newFairyState(): FairyState {
  return { text: '', chat: null }
}

/** One line from Fairy's socket, as Agent pane events. */
export function parseFairyLine(line: string, state: FairyState): AgentEvent[] {
  let j: Record<string, any>
  try {
    j = JSON.parse(line)
  } catch {
    return []
  }
  const text = (next: string): AgentEvent[] => {
    if (next === state.text) return []
    const replace = !next.startsWith(state.text)
    const delta = replace ? next : next.slice(state.text.length)
    state.text = next
    return [{ kind: 'text', delta, replace: replace || undefined }]
  }
  switch (j.type) {
    case 'started':
      state.chat = typeof j.chat === 'string' ? j.chat : null
      return state.chat ? [{ kind: 'session', id: state.chat }] : []
    case 'step': {
      const row = j.row ?? {}
      if (typeof row.id !== 'string' || typeof row.tool !== 'string') return []
      const s = row.status === 'running' ? 'running' : row.status === 'failed' ? 'error' : 'done'
      return [{ kind: 'tool', id: row.id, name: row.tool, summary: String(row.summary ?? ''), state: s, writes: WRITES.has(row.tool) }]
    }
    case 'text':
      return typeof j.text === 'string' ? text(j.text) : []
    case 'approval':
      return [{ kind: 'approval', id: String(j.approval ?? ''), title: String(j.title ?? 'Fairy needs your OK'), detail: j.detail ? String(j.detail) : undefined }]
    case 'approval-closed':
      return [{ kind: 'approval', id: String(j.approval ?? ''), closed: true }]
    case 'done': {
      const out = typeof j.text === 'string' && j.text.trim() ? text(j.text) : []
      out.push({ kind: 'done', sessionId: state.chat ?? undefined, error: j.failed ? 'Fairy didn’t finish' : undefined })
      return out
    }
    case 'error':
      return [{ kind: 'error', message: String(j.message ?? 'Fairy couldn’t start this.') }]
    default:
      return []
  }
}

const conns = new Map<string, net.Socket>()

/** Asks Fairy to run one turn, reporting through `emit` until `done` or `error`. */
export function runFairy(
  req: AgentRunRequest,
  vaultRoot: string,
  context: string,
  emit: (event: AgentEvent) => void,
): Promise<void> {
  return new Promise((resolve) => {
    const state = newFairyState()
    let finished = false
    let buffer = ''
    const end = (event?: AgentEvent): void => {
      if (finished) return
      finished = true
      conns.delete(req.runId)
      if (event) emit(event)
      conn.end()
    }
    const conn = net.createConnection(fairySocketPath(), () => {
      conns.set(req.runId, conn)
      conn.write(
        JSON.stringify({
          type: 'work',
          id: req.runId,
          folder: vaultRoot,
          prompt: req.prompt,
          context,
          chat: req.sessionId ?? undefined,
          mode: req.allowEdits ? 'edit' : 'read',
        }) + '\n',
      )
      resolve()
    })
    conn.setEncoding('utf8')
    conn.on('data', (chunk: string) => {
      buffer += chunk
      let nl: number
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl).trim()
        buffer = buffer.slice(nl + 1)
        if (!line) continue
        for (const event of parseFairyLine(line, state)) {
          if (event.kind === 'done' || event.kind === 'error') end(event)
          else emit(event)
        }
      }
    })
    conn.on('error', () => {
      end({ kind: 'error', message: 'Fairy isn’t running on this Mac. Open Fairy, then try again.' })
      resolve()
    })
    conn.on('close', () => {
      // She quit part way: the work stopped with her, and the chat keeps what was done.
      end({ kind: 'error', message: 'Fairy closed the connection before finishing. What she did is in her chat.' })
    })
  })
}

export function stopFairy(runId: string): boolean {
  const conn = conns.get(runId)
  if (!conn) return false
  conn.write(JSON.stringify({ type: 'stop', id: runId }) + '\n')
  return true
}
