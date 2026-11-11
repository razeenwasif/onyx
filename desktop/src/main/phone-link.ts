/**
 * The iPad and iPhone's way to the Agent: Electron on the Mac listens on
 * its Tailscale address, and a paired device asks it to run Claude Code,
 * Antigravity or Fairy on the vault, then follows the steps as they happen.
 * Built like Fairy's phone link (desktop-buddies/Lyra, phone-link.mjs).
 *
 * - HTTPS on this Mac's Tailscale address only, never the local network,
 *   with a self-signed certificate. The pairing code carries its
 *   fingerprint, so the device trusts this Mac from the first request and
 *   no other.
 * - Pairing: a one-time code that lasts five minutes, shown as a QR code
 *   in Settings. The device gets a key; only its hash is kept here.
 * - What a device can do is the short list of routes in receive(): run the
 *   agent with the Mac's own Agent settings (edits allowed or not, models),
 *   follow a run, stop it, and leave. Nothing else on the Mac is reachable.
 */

import { execFile } from 'node:child_process'
import { X509Certificate, createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { mkdtemp, readFile, rm, writeFile, rename } from 'node:fs/promises'
import { createServer, type Server } from 'node:https'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { isIPv4 } from 'node:net'
import { networkInterfaces, tmpdir } from 'node:os'
import * as path from 'node:path'

import type { AgentEvent, AgentId, AgentRunRequest, DeviceLinkState as LinkState } from '../shared/types.js'

export const LINK_PORT = 47620
const PAIR_LIFETIME = 5 * 60 * 1000
const PAIR_TRIES = 5
const MAX_BODY = 8 * 1024
const MAX_PROMPT_BODY = 64 * 1024
const MAX_STREAMS = 8
const STREAM_PING = 15000
const CERTIFICATE_DAYS = 800
const RENEW_BEFORE = 30 * 24 * 60 * 60 * 1000
/** A finished run's steps stay this long, for a device that reconnects to read the end. */
const KEEP_FINISHED = 15 * 60 * 1000
const AGENTS: AgentId[] = ['claude', 'antigravity', 'fairy']
const HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
const TAILSCALE = ['/Applications/Tailscale.app/Contents/MacOS/Tailscale', 'tailscale']

// ------------------------------------------------------------ Tailscale

const plainAddress = (address: string | undefined): string => String(address ?? '').replace(/^::ffff:/, '')

/** Tailscale gives out addresses from 100.64.0.0/10. */
export function isTailscale(address: string | undefined): boolean {
  const plain = plainAddress(address)
  if (!isIPv4(plain)) return false
  const [first, second] = plain.split('.').map(Number)
  return first === 100 && second >= 64 && second <= 127
}

/** This Mac's Tailscale address. Only a utun interface counts: some networks use that range too. */
export function tailscaleAddress(interfaces = networkInterfaces): string {
  for (const [name, entries] of Object.entries(interfaces())) {
    if (!/^utun\d+$/.test(name)) continue
    const entry = (entries ?? []).find((item) => item.family === 'IPv4' && isTailscale(item.address))
    if (entry) return entry.address
  }
  return ''
}

const run = (command: string, args: string[]): Promise<string> =>
  new Promise((resolve) => execFile(command, args, { timeout: 5000 }, (error, stdout) => resolve(error ? '' : String(stdout))))

/** iOS lets an app trust a certificate for a domain, not an address, so devices connect by this name. */
export async function tailscaleName(command = run): Promise<string> {
  for (const bin of TAILSCALE) {
    try {
      const name = JSON.parse(await command(bin, ['status', '--json'])).Self?.DNSName?.replace(/\.$/, '')
      if (name) return name
    } catch {
      /* try the next place it might be */
    }
  }
  return ''
}

export interface Certificate {
  key: string
  cert: string
  expires: number
}

/** macOS's openssl spells the curve out unless told to name it, and iOS refuses that. */
export async function makeCertificate(name: string, address: string): Promise<Certificate> {
  const dir = await mkdtemp(path.join(tmpdir(), 'electron-link-'))
  const keyFile = path.join(dir, 'key')
  const certFile = path.join(dir, 'cert')
  try {
    await new Promise<void>((resolve, reject) =>
      execFile(
        '/usr/bin/openssl',
        [
          'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-pkeyopt', 'ec_param_enc:named_curve',
          '-nodes', '-keyout', keyFile, '-out', certFile, '-days', String(CERTIFICATE_DAYS), '-subj', '/CN=Electron',
          '-addext', `subjectAltName=DNS:${name}${address ? `,IP:${address}` : ''}`, '-addext', 'extendedKeyUsage=serverAuth',
        ],
        { timeout: 15000 },
        (error) => (error ? reject(new Error('Electron couldn’t make its certificate.')) : resolve()),
      ),
    )
    const key = await readFile(keyFile, 'utf8')
    const cert = await readFile(certFile, 'utf8')
    return { key, cert, expires: new Date(new X509Certificate(cert).validTo).getTime() }
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

export const pinOf = (cert: string): string => new X509Certificate(cert).fingerprint256.replaceAll(':', '').toLowerCase()
const hashed = (text: string): Buffer => createHash('sha256').update(text).digest()
const sameText = (a: string, b: string): boolean => timingSafeEqual(hashed(a), hashed(b))

const failure = (status: number, message: string): Error & { status: number } => Object.assign(new Error(message), { status })

// ------------------------------------------------------------------ link

interface Device {
  id: string
  name: string
  keyHash: string
  paired: string
  lastSeen: string
}

interface Store {
  enabled: boolean
  sealedKey: string
  cert: string
  certName: string
  expires: number
  devices: Device[]
}

/** A run a device started: its steps so far, for anyone following it. */
interface Run {
  id: string
  device: string
  events: AgentEvent[]
  finished: number
  listeners: Set<(event: AgentEvent, index: number) => void>
}

export interface LinkAbout {
  name: string
  vault: string
  agents: Record<AgentId, boolean>
  defaultAgent: AgentId
  allowEdits: boolean
}

export interface PhoneLinkOptions {
  /** Where the link keeps its settings and paired devices. */
  file: string
  /** Runs one agent turn on the vault (agents.ts), with the Mac's own settings filled in. */
  runAgent: (req: AgentRunRequest, emit: (event: AgentEvent) => void) => Promise<void>
  stopAgent: (runId: string) => void
  about: () => Promise<LinkAbout>
  onChange?: () => void
  address?: () => string
  name?: () => Promise<string>
  certificate?: (name: string, address: string) => Promise<Certificate>
  accepts?: (address: string | undefined) => boolean
  seal?: (text: string) => string
  unseal?: (text: string) => string
  port?: number
  now?: () => number
  every?: number
}

export class PhoneLink {
  private o: Required<PhoneLinkOptions>
  private store: Store = { enabled: false, sealedKey: '', cert: '', certName: '', expires: 0, devices: [] }
  private server: Server | null = null
  private here = ''
  private hostName = ''
  private pairing: { code: string; expires: number; tries: number } | null = null
  private problem = ''
  private runs = new Map<string, Run>()
  private streams = new Set<ServerResponse>()
  private queue: Promise<unknown> = Promise.resolve()
  private timer: NodeJS.Timeout | null = null

  constructor(options: PhoneLinkOptions) {
    this.o = {
      onChange: () => {},
      address: () => tailscaleAddress(),
      name: () => tailscaleName(),
      certificate: makeCertificate,
      accepts: isTailscale,
      seal: (t) => t,
      unseal: (t) => t,
      port: LINK_PORT,
      now: Date.now,
      every: 30000,
      ...options,
    }
  }

  /** One change to the server at a time, so a network check can't race turning it off. */
  private inTurn<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work)
    this.queue = next.catch(() => {})
    return next
  }

  private async save(): Promise<void> {
    const tmp = `${this.o.file}.${process.pid}.tmp`
    await writeFile(tmp, JSON.stringify(this.store, null, 2), { mode: 0o600 })
    await rename(tmp, this.o.file)
  }

  async start(): Promise<void> {
    try {
      const saved = JSON.parse(await readFile(this.o.file, 'utf8'))
      this.store = { ...this.store, ...saved, enabled: saved.enabled === true, devices: Array.isArray(saved.devices) ? saved.devices : [] }
    } catch (error: any) {
      if (error?.code !== 'ENOENT') console.warn('Could not read the device link settings:', error?.message)
    }
    await this.refresh()
    this.timer = setInterval(() => void this.refresh(), this.o.every)
    this.timer.unref?.()
  }

  stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer)
    return this.inTurn(() => this.close())
  }

  state(): LinkState {
    return {
      enabled: this.store.enabled,
      listening: Boolean(this.server),
      name: this.hostName,
      tailscale: Boolean(this.here || this.o.address()),
      problem: this.problem,
      pairing: Boolean(this.pairing && this.pairing.expires > this.o.now()),
      devices: this.store.devices.map(({ id, name, paired, lastSeen }) => ({ id, name, paired, lastSeen })),
    }
  }

  async setEnabled(on: boolean): Promise<LinkState> {
    await this.inTurn(async () => {
      this.store.enabled = on
      if (!on) {
        await this.close()
        this.problem = ''
      }
      await this.save()
    })
    await this.refresh()
    this.o.onChange()
    return this.state()
  }

  /** Follows Tailscale coming and going, and stays closed without it. */
  refresh(): Promise<void> {
    return this.inTurn(async () => {
      const before = JSON.stringify(this.state())
      if (this.store.enabled) {
        const address = this.o.address()
        if (!address) {
          await this.close()
          this.problem = ''
        } else if (!this.server || this.here !== address) {
          await this.close()
          try {
            await this.listen(address)
            this.problem = ''
          } catch (error: any) {
            this.problem = error.message
          }
        }
      }
      if (JSON.stringify(this.state()) !== before) this.o.onChange()
    }).catch((error) => console.warn('Could not check Tailscale:', error.message))
  }

  /** A device trusts this one certificate, so a new one means pairing again. */
  private async identity(address: string): Promise<{ key: string; cert: string; name: string }> {
    const name = await this.o.name()
    if (!name) throw new Error('Electron couldn’t read this Mac’s Tailscale name. Check that MagicDNS is on in Tailscale.')
    let key = ''
    try {
      key = this.store.sealedKey ? this.o.unseal(this.store.sealedKey) : ''
    } catch {
      key = ''
    }
    if (key && this.store.cert && this.store.certName === name && this.store.expires - this.o.now() > RENEW_BEFORE) {
      return { key, cert: this.store.cert, name }
    }
    const made = await this.o.certificate(name, address)
    const replacing = Boolean(this.store.cert)
    Object.assign(this.store, { sealedKey: this.o.seal(made.key), cert: made.cert, certName: name, expires: made.expires })
    if (replacing) this.store.devices = []
    await this.save()
    return { key: made.key, cert: made.cert, name }
  }

  private async listen(address: string): Promise<void> {
    const { key, cert, name } = await this.identity(address)
    await new Promise<void>((resolve, reject) => {
      const server = createServer({ key, cert, maxHeaderSize: 8 * 1024 }, (req, res) => void this.receive(req, res))
      Object.assign(server, { headersTimeout: 5000, requestTimeout: 10000, keepAliveTimeout: 5000, maxConnections: 32 })
      server.once('error', (error: any) =>
        reject(new Error(error.code === 'EADDRINUSE' ? `Another app is using port ${this.o.port}, which the device link needs.` : `The device link couldn’t start: ${error.message}`)),
      )
      server.listen(this.o.port, address, () => {
        server.removeAllListeners('error')
        server.on('error', (error) => console.warn('Device link:', error.message))
        this.server = server
        this.here = address
        this.hostName = name
        resolve()
      })
    })
  }

  private async close(): Promise<void> {
    const server = this.server
    this.server = null
    this.here = ''
    this.hostName = ''
    this.pairing = null
    for (const res of this.streams) res.destroy()
    this.streams.clear()
    if (!server) return
    await new Promise<void>((resolve) => {
      server.close(() => resolve())
      server.closeAllConnections()
    })
  }

  /** A one-time code, as the `onyx://pair` link the QR code holds. The fingerprint in it is how the device knows this Mac. */
  pair(): { url: string; minutes: number } {
    if (!this.server) throw new Error('Turn on the device link first.')
    const code = randomBytes(16).toString('base64url')
    this.pairing = { code, expires: this.o.now() + PAIR_LIFETIME, tries: 0 }
    const port = (this.server.address() as { port: number }).port
    const query = new URLSearchParams({ host: this.hostName, port: String(port), code, pin: pinOf(this.store.cert) })
    this.o.onChange()
    return { url: `onyx://pair?${query}`, minutes: PAIR_LIFETIME / 60000 }
  }

  async forget(id: string): Promise<LinkState> {
    await this.inTurn(async () => {
      this.store.devices = this.store.devices.filter((d) => d.id !== id)
      await this.save()
    })
    this.o.onChange()
    return this.state()
  }

  private device(req: IncomingMessage): Device | null {
    const key = /^Bearer (.+)$/.exec(String(req.headers.authorization ?? ''))?.[1]
    if (!key) return null
    const hash = hashed(key).toString('hex')
    return this.store.devices.find((d) => d.keyHash === hash) ?? null
  }

  private send(res: ServerResponse, status: number, value: unknown): void {
    const body = JSON.stringify(value)
    res.writeHead(status, { ...HEADERS, 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) })
    res.end(body)
  }

  private body(req: IncomingMessage, limit = MAX_BODY): Promise<any> {
    return new Promise((resolve, reject) => {
      const parts: Buffer[] = []
      let size = 0
      req.on('data', (part: Buffer) => {
        size += part.length
        if (size > limit) {
          reject(failure(413, 'Too long.'))
          req.destroy()
          return
        }
        parts.push(part)
      })
      req.on('error', reject)
      req.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(parts).toString('utf8')))
        } catch {
          reject(failure(400, 'Not understood.'))
        }
      })
    })
  }

  async receive(req: IncomingMessage, res: ServerResponse): Promise<void> {
    // Nothing at all for anything outside Tailscale.
    if (!this.here || !this.o.accepts(req.socket.remoteAddress)) {
      req.socket.destroy()
      return
    }
    try {
      const port = (this.server?.address() as { port: number } | null)?.port
      if (req.headers.host !== `${this.hostName}:${port}`) return this.send(res, 421, { error: 'Wrong address.' })
      // Only the app talks to this; a web page would send an Origin.
      if (req.headers.origin) return this.send(res, 403, { error: 'Refused.' })
      const { pathname, searchParams } = new URL(req.url ?? '/', 'https://electron.invalid')
      if (req.method === 'POST' && pathname === '/v1/pair') return await this.takeCode(req, res)
      if (!['/v1/about', '/v1/agent/run', '/v1/agent/events', '/v1/agent/stop', '/v1/leave'].includes(pathname)) {
        return this.send(res, 404, { error: 'Not found.' })
      }
      const device = this.device(req)
      if (!device) return this.send(res, 401, { error: 'This device isn’t paired.' })
      device.lastSeen = new Date(this.o.now()).toISOString()
      if (req.method === 'GET' && pathname === '/v1/about') return this.send(res, 200, await this.o.about())
      if (req.method === 'POST' && pathname === '/v1/agent/run') return await this.startRun(req, res, device)
      if (req.method === 'GET' && pathname === '/v1/agent/events') return this.follow(res, device, searchParams.get('run') ?? '', Number(searchParams.get('after') ?? 0))
      if (req.method === 'POST' && pathname === '/v1/agent/stop') {
        const { run } = await this.body(req)
        const known = this.runs.get(String(run))
        if (!known || known.device !== device.id) throw failure(404, 'That run isn’t here.')
        if (!known.finished) this.o.stopAgent(known.id)
        return this.send(res, 200, { ok: true })
      }
      if (req.method === 'POST' && pathname === '/v1/leave') {
        await this.forget(device.id)
        return this.send(res, 200, { ok: true })
      }
      return this.send(res, 405, { error: 'Not allowed.' })
    } catch (error: any) {
      if (!res.headersSent) this.send(res, error.status ?? 500, { error: error.status ? error.message : 'Something went wrong on the Mac.' })
      else res.destroy()
    }
  }

  private async takeCode(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const { code, name } = await this.body(req)
    const pairing = this.pairing
    if (!pairing || pairing.expires <= this.o.now()) throw failure(403, 'That code has run out. Make a new one in Electron on the Mac.')
    if (typeof code !== 'string' || !sameText(code, pairing.code)) {
      if (++pairing.tries >= PAIR_TRIES) this.pairing = null
      throw failure(403, 'That code isn’t right. Make a new one in Electron on the Mac.')
    }
    this.pairing = null
    const key = randomBytes(32).toString('base64url')
    const at = new Date(this.o.now()).toISOString()
    const device: Device = { id: randomUUID(), name: String(name || 'iPad').slice(0, 40), keyHash: hashed(key).toString('hex'), paired: at, lastSeen: at }
    this.store.devices.push(device)
    await this.save()
    this.o.onChange()
    this.send(res, 200, { key, device: device.id })
  }

  /** A run with the Mac's own Agent settings: the device chooses only the agent, the words and the conversation. */
  private async startRun(req: IncomingMessage, res: ServerResponse, device: Device): Promise<void> {
    const { agent, prompt, sessionId, notePath } = await this.body(req, MAX_PROMPT_BODY)
    if (!AGENTS.includes(agent)) throw failure(400, 'Unknown agent.')
    const text = typeof prompt === 'string' ? prompt.trim() : ''
    if (!text || text.length > 12000) throw failure(400, 'Say what to do, in up to 12,000 characters.')
    if ([...this.runs.values()].some((r) => r.device === device.id && !r.finished)) throw failure(409, 'The agent is still working on this device’s last request.')
    this.prune()
    const id = randomUUID()
    const run: Run = { id, device: device.id, events: [], finished: 0, listeners: new Set() }
    this.runs.set(id, run)
    const emit = (event: AgentEvent): void => {
      if (run.finished) return
      run.events.push(event)
      if (event.kind === 'done' || event.kind === 'error') run.finished = this.o.now()
      for (const listener of run.listeners) listener(event, run.events.length)
    }
    void this.o
      .runAgent(
        {
          runId: id,
          agent,
          prompt: text,
          sessionId: typeof sessionId === 'string' && sessionId ? sessionId.slice(0, 200) : null,
          model: '',
          notePath: typeof notePath === 'string' && notePath ? notePath.slice(0, 500) : null,
          allowEdits: true,
        },
        emit,
      )
      .catch((error) => emit({ kind: 'error', message: error?.message ?? String(error) }))
    this.send(res, 200, { run: id })
  }

  /** The run's events from `after` on, as server-sent events, until it ends. */
  private follow(res: ServerResponse, device: Device, id: string, after: number): void {
    const run = this.runs.get(id)
    if (!run || run.device !== device.id) throw failure(404, 'That run isn’t here.')
    if (this.streams.size >= MAX_STREAMS) throw failure(503, 'Too many connections.')
    res.socket?.setTimeout(0)
    res.writeHead(200, { ...HEADERS, 'Content-Type': 'text/event-stream; charset=utf-8' })
    this.streams.add(res)
    const write = (event: AgentEvent, index: number): void => {
      res.write(`data: ${JSON.stringify({ i: index, event })}\n\n`)
      if (event.kind === 'done' || event.kind === 'error') res.end()
    }
    const start = Math.max(0, Math.floor(after) || 0)
    run.events.slice(start).forEach((event, i) => write(event, start + i + 1))
    if (run.finished) return
    run.listeners.add(write)
    const ping = setInterval(() => res.write(': still here\n\n'), STREAM_PING)
    res.on('close', () => {
      clearInterval(ping)
      run.listeners.delete(write)
      this.streams.delete(res)
    })
  }

  private prune(): void {
    for (const [id, run] of this.runs) if (run.finished && this.o.now() - run.finished > KEEP_FINISHED) this.runs.delete(id)
  }
}
