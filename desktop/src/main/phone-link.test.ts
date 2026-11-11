import { afterEach, describe, expect, it } from 'vitest'
import { request } from 'node:https'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import * as path from 'node:path'

import { PhoneLink, isTailscale, makeCertificate, pinOf, tailscaleAddress } from './phone-link'
import type { AgentEvent, AgentRunRequest } from '../shared/types'

const NAME = 'mac.tail1234.ts.net'

interface Reply {
  status: number
  body: any
  text: string
}

/** One request to the link, as a paired device would make it (but without pinning: the test checks the pin itself). */
function call(port: number, method: string, url: string, { key, body, host = `${NAME}:${port}`, origin }: { key?: string; body?: unknown; host?: string; origin?: string } = {}): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { host }
    if (key) headers.authorization = `Bearer ${key}`
    if (origin) headers.origin = origin
    if (body !== undefined) headers['content-type'] = 'application/json'
    const req = request({ host: '127.0.0.1', port, method, path: url, headers, rejectUnauthorized: false, agent: false }, (res) => {
      let text = ''
      res.setEncoding('utf8')
      res.on('data', (c: string) => (text += c))
      res.on('end', () => {
        let parsed: any = null
        try {
          parsed = JSON.parse(text)
        } catch {
          /* server-sent events */
        }
        resolve({ status: res.statusCode ?? 0, body: parsed, text })
      })
    })
    req.on('error', reject)
    if (body !== undefined) req.write(JSON.stringify(body))
    req.end()
  })
}

const events = (text: string): Array<{ i: number; event: AgentEvent }> =>
  text
    .split('\n\n')
    .filter((chunk) => chunk.startsWith('data: '))
    .map((chunk) => JSON.parse(chunk.slice(6)))

describe('Tailscale', () => {
  it('knows its own addresses, and only on a utun interface', () => {
    expect(isTailscale('100.101.102.103')).toBe(true)
    expect(isTailscale('::ffff:100.64.0.1')).toBe(true)
    expect(isTailscale('100.128.0.1')).toBe(false)
    expect(isTailscale('192.168.1.4')).toBe(false)
    const nets = (): any => ({ en0: [{ family: 'IPv4', address: '100.70.0.1' }], utun4: [{ family: 'IPv4', address: '100.80.1.2' }] })
    expect(tailscaleAddress(nets)).toBe('100.80.1.2')
  })
})

describe('the device link', () => {
  let link: PhoneLink | null = null
  afterEach(async () => {
    await link?.stop()
    link = null
  })

  async function startLink(over: { runAgent?: (req: AgentRunRequest, emit: (e: AgentEvent) => void) => Promise<void>; stopAgent?: (id: string) => void; accepts?: () => boolean } = {}) {
    const dir = mkdtempSync(path.join(tmpdir(), 'link-'))
    const file = path.join(dir, 'device-link.json')
    const runs: AgentRunRequest[] = []
    link = new PhoneLink({
      file,
      address: () => '127.0.0.1',
      name: async () => NAME,
      certificate: makeCertificate,
      accepts: over.accepts ?? (() => true),
      seal: (t) => `sealed:${Buffer.from(t).toString('base64')}`,
      unseal: (t) => Buffer.from(t.slice(7), 'base64').toString(),
      port: 0,
      runAgent: async (req, emit) => {
        runs.push(req)
        await (over.runAgent ?? (async (_r, e) => e({ kind: 'done' })))(req, emit)
      },
      stopAgent: over.stopAgent ?? (() => {}),
      about: async () => ({ name: 'Electron', vault: 'OnyxVault', agents: { claude: true, antigravity: false, fairy: true }, defaultAgent: 'claude', allowEdits: true }),
    })
    await link.setEnabled(true)
    const { url } = link.pair()
    const q = new URL(url)
    const port = Number(q.searchParams.get('port'))
    return { link, file, url: q, port, runs }
  }

  async function paired() {
    const started = await startLink()
    const res = await call(started.port, 'POST', '/v1/pair', { body: { code: started.url.searchParams.get('code'), name: 'Izanami' } })
    return { ...started, key: res.body.key as string }
  }

  it('pairs once with the code, pins this certificate, and keeps only hashes', async () => {
    const { url, port, file } = await startLink()
    expect(url.protocol).toBe('onyx:')
    expect(url.searchParams.get('host')).toBe(NAME)
    const saved = JSON.parse(readFileSync(file, 'utf8'))
    expect(url.searchParams.get('pin')).toBe(pinOf(saved.cert))
    expect(saved.sealedKey.startsWith('sealed:')).toBe(true)

    expect((await call(port, 'POST', '/v1/pair', { body: { code: 'wrong', name: 'x' } })).status).toBe(403)
    const ok = await call(port, 'POST', '/v1/pair', { body: { code: url.searchParams.get('code'), name: 'Izanami' } })
    expect(ok.status).toBe(200)
    expect(typeof ok.body.key).toBe('string')
    expect((await call(port, 'POST', '/v1/pair', { body: { code: url.searchParams.get('code'), name: 'again' } })).status).toBe(403)

    const after = readFileSync(file, 'utf8')
    expect(after).not.toContain(ok.body.key)
    expect(link!.state().devices.map((d) => d.name)).toEqual(['Izanami'])
  })

  it('answers only paired devices, at its own name, and never a web page', async () => {
    const { port, key } = await paired()
    expect((await call(port, 'GET', '/v1/about')).status).toBe(401)
    expect((await call(port, 'GET', '/v1/about', { key: 'nope' })).status).toBe(401)
    expect((await call(port, 'GET', '/v1/about', { key, host: `127.0.0.1:${port}` })).status).toBe(421)
    expect((await call(port, 'GET', '/v1/about', { key, origin: 'https://evil.example' })).status).toBe(403)
    expect((await call(port, 'GET', '/v1/settings', { key })).status).toBe(404)
    const about = await call(port, 'GET', '/v1/about', { key })
    expect(about.body).toMatchObject({ vault: 'OnyxVault', agents: { fairy: true } })
  })

  it('refuses anything from outside Tailscale outright', async () => {
    const { port } = await startLink({ accepts: () => false })
    await expect(call(port, 'GET', '/v1/about')).rejects.toThrow()
  })

  it('runs the agent, streams its steps, picks up where a device left off, and stops it', async () => {
    let finish: () => void = () => {}
    const stopped: string[] = []
    const started = await startLink({
      runAgent: async (_req, emit) => {
        emit({ kind: 'session', id: 's1' })
        emit({ kind: 'tool', id: 't1', name: 'Read', summary: 'Week 7.md', state: 'done', writes: false })
        finish = () => {
          emit({ kind: 'text', delta: 'Linked.' })
          emit({ kind: 'done', sessionId: 's1' })
        }
      },
      stopAgent: (id) => stopped.push(id),
    })
    const res = await call(started.port, 'POST', '/v1/pair', { body: { code: started.url.searchParams.get('code'), name: 'iPhone' } })
    const key = res.body.key

    expect((await call(started.port, 'POST', '/v1/agent/run', { key, body: { agent: 'shell', prompt: 'x' } })).status).toBe(400)
    const run = await call(started.port, 'POST', '/v1/agent/run', { key, body: { agent: 'fairy', prompt: ' Link the notes ', sessionId: 'chat-1', notePath: 'Week 7.md' } })
    expect(run.status).toBe(200)
    expect(started.runs[0]).toMatchObject({ agent: 'fairy', prompt: 'Link the notes', sessionId: 'chat-1', notePath: 'Week 7.md' })
    expect((await call(started.port, 'POST', '/v1/agent/run', { key, body: { agent: 'claude', prompt: 'again' } })).status).toBe(409)

    const following = call(started.port, 'GET', `/v1/agent/events?run=${run.body.run}&after=1`, { key })
    await new Promise((r) => setTimeout(r, 50))
    expect((await call(started.port, 'POST', '/v1/agent/stop', { key, body: { run: run.body.run } })).status).toBe(200)
    expect(stopped).toEqual([run.body.run])
    finish()
    const got = events((await following).text)
    expect(got.map((g) => g.i)).toEqual([2, 3, 4])
    expect(got.map((g) => g.event.kind)).toEqual(['tool', 'text', 'done'])

    // A finished run can still be read from the start.
    const again = events((await call(started.port, 'GET', `/v1/agent/events?run=${run.body.run}`, { key })).text)
    expect(again.map((g) => g.event.kind)).toEqual(['session', 'tool', 'text', 'done'])
  })

  it('forgets a device that leaves', async () => {
    const { port, key } = await paired()
    expect((await call(port, 'POST', '/v1/leave', { key, body: {} })).status).toBe(200)
    expect((await call(port, 'GET', '/v1/about', { key })).status).toBe(401)
    expect(link!.state().devices).toEqual([])
  })
})
