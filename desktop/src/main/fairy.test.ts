import { afterEach, describe, expect, it } from 'vitest'
import * as net from 'node:net'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import * as path from 'node:path'

import { fairyAvailable, newFairyState, parseFairyLine, runFairy, stopFairy } from './fairy'
import { contextPrompt } from './agents'
import type { AgentEvent, AgentRunRequest } from '../shared/types'

const req = (over: Partial<AgentRunRequest> = {}): AgentRunRequest => ({
  runId: 'r1',
  agent: 'fairy',
  prompt: 'Link the eigenvalue notes',
  sessionId: null,
  model: '',
  notePath: 'Week 7.md',
  allowEdits: true,
  ...over,
})

describe('Fairy’s messages', () => {
  it('turns her steps, whole-so-far text, approvals and end into pane events', () => {
    const st = newFairyState()
    const lines = [
      { type: 'started', id: 'r1', chat: 'chat-1' },
      { type: 'step', id: 'r1', row: { id: 's1', tool: 'read', summary: 'Week 6.md', status: 'running' } },
      { type: 'step', id: 'r1', row: { id: 's2', tool: 'edit', summary: 'Week 7.md', status: 'done' } },
      { type: 'text', id: 'r1', text: 'Linked' },
      { type: 'text', id: 'r1', text: 'Linked two notes.' },
      { type: 'text', id: 'r1', text: 'Done: linked two notes.' },
      { type: 'approval', id: 'r1', approval: 'a1', title: 'Run make', detail: 'make' },
      { type: 'approval-closed', id: 'r1', approval: 'a1' },
      { type: 'done', id: 'r1', text: 'Done: linked two notes.', failed: false },
    ].flatMap((l) => parseFairyLine(JSON.stringify(l), st))
    expect(lines).toEqual([
      { kind: 'session', id: 'chat-1' },
      { kind: 'tool', id: 's1', name: 'read', summary: 'Week 6.md', state: 'running', writes: false },
      { kind: 'tool', id: 's2', name: 'edit', summary: 'Week 7.md', state: 'done', writes: true },
      { kind: 'text', delta: 'Linked', replace: undefined },
      { kind: 'text', delta: ' two notes.', replace: undefined },
      { kind: 'text', delta: 'Done: linked two notes.', replace: true },
      { kind: 'approval', id: 'a1', title: 'Run make', detail: 'make' },
      { kind: 'approval', id: 'a1', closed: true },
      { kind: 'done', sessionId: 'chat-1', error: undefined },
    ])
  })

  it('reports a failed turn and a refusal', () => {
    const st = newFairyState()
    expect(parseFairyLine(JSON.stringify({ type: 'done', text: 'I stopped.', failed: true }), st).at(-1)).toEqual({ kind: 'done', sessionId: undefined, error: 'Fairy didn’t finish' })
    expect(parseFairyLine(JSON.stringify({ type: 'error', message: 'Fairy is still working in this chat.' }), st)).toEqual([{ kind: 'error', message: 'Fairy is still working in this chat.' }])
    expect(parseFairyLine('not json', st)).toEqual([])
  })

  it('tells her about the vault without the other agents’ no-commands rule, and lists fewer notes', () => {
    const notes = Array.from({ length: 300 }, (_, i) => `n${i}.md`)
    const forFairy = contextPrompt('/v', 'Week 7.md', notes, true)
    expect(forFairy).not.toContain('shell commands')
    expect(forFairy).toContain('The note open in the editor now is Week 7.md.')
    expect(forFairy.split('\n').length).toBe(152)
  })
})

describe('Fairy’s socket', () => {
  const saved = process.env.LYRA_DATA_DIR
  afterEach(() => {
    process.env.LYRA_DATA_DIR = saved
  })

  /** A stand-in for Fairy: answers each `work` with `script`, and records what came in. */
  async function fakeFairy(script: (msg: any, send: (m: object) => void) => void): Promise<{ got: any[]; close: () => void }> {
    const dir = mkdtempSync(path.join(tmpdir(), 'fairy-'))
    process.env.LYRA_DATA_DIR = dir
    const got: any[] = []
    const server = net.createServer((conn) => {
      let buf = ''
      conn.setEncoding('utf8')
      conn.on('data', (chunk: string) => {
        buf += chunk
        let nl: number
        while ((nl = buf.indexOf('\n')) >= 0) {
          const msg = JSON.parse(buf.slice(0, nl))
          buf = buf.slice(nl + 1)
          got.push(msg)
          script(msg, (m) => conn.write(JSON.stringify(m) + '\n'))
        }
      })
    })
    await new Promise<void>((r) => server.listen(path.join(dir, 'electron.sock'), r))
    return { got, close: () => server.close() }
  }

  it('sends the vault, the request, the context and the mode, and streams the turn', async () => {
    const fairy = await fakeFairy((msg, send) => {
      if (msg.type !== 'work') return
      send({ type: 'started', id: msg.id, chat: 'chat-7' })
      send({ type: 'text', id: msg.id, text: 'Linked.' })
      send({ type: 'done', id: msg.id, text: 'Linked.', failed: false })
    })
    expect(fairyAvailable()).toBe(true)
    const events: AgentEvent[] = []
    await new Promise<void>((done) => {
      void runFairy(req({ sessionId: 'chat-7', allowEdits: false }), '/v', 'About the vault', (e) => {
        events.push(e)
        if (e.kind === 'done' || e.kind === 'error') done()
      })
    })
    fairy.close()
    expect(fairy.got[0]).toEqual({ type: 'work', id: 'r1', folder: '/v', prompt: 'Link the eigenvalue notes', context: 'About the vault', chat: 'chat-7', mode: 'read' })
    expect(events.map((e) => e.kind)).toEqual(['session', 'text', 'done'])
  })

  it('passes Stop on, and says so when Fairy isn’t running', async () => {
    const fairy = await fakeFairy((msg, send) => {
      if (msg.type === 'work') send({ type: 'started', id: msg.id, chat: 'c' })
      if (msg.type === 'stop') send({ type: 'done', id: msg.id, text: 'Stopped.', failed: true })
    })
    const events: AgentEvent[] = []
    const finished = new Promise<void>((done) => {
      void runFairy(req(), '/v', '', (e) => {
        events.push(e)
        if (e.kind === 'session') stopFairy('r1')
        if (e.kind === 'done' || e.kind === 'error') done()
      })
    })
    await finished
    fairy.close()
    expect(fairy.got.map((m) => m.type)).toEqual(['work', 'stop'])
    expect(events.at(-1)).toMatchObject({ kind: 'done', error: 'Fairy didn’t finish' })

    process.env.LYRA_DATA_DIR = mkdtempSync(path.join(tmpdir(), 'nofairy-'))
    expect(fairyAvailable()).toBe(false)
    const lonely: AgentEvent[] = []
    await runFairy(req(), '/v', '', (e) => lonely.push(e))
    expect(lonely).toEqual([{ kind: 'error', message: 'Fairy isn’t running on this Mac. Open Fairy, then try again.' }])
  })
})
