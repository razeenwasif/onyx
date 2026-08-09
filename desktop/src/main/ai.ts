/**
 * Local LLM assistant via the Ollama HTTP API (loopback, no auth), plus the
 * "ask my vault" RAG index.
 *
 * Port of `src/integrations/ollama.rs` and `src/rag.rs`. Streaming matters: a
 * local model's first request loads weights (seconds) and then emits tokens
 * incrementally, so deltas are forwarded to the renderer as they arrive.
 */

import { promises as fs } from 'node:fs'
import * as path from 'node:path'

import type { Vault } from './vault.js'
import { stripFrontmatter } from '../shared/parse.js'

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export interface ChatChunk {
  content: string
  thinking: string
  done: boolean
}

function base(host: string): string {
  return host.replace(/\/+$/, '')
}

/** Parse one NDJSON line from a streaming `/api/chat` response. */
export function parseChatChunk(line: string): ChatChunk | null {
  try {
    const r = JSON.parse(line) as { message?: { content?: string; thinking?: string }; done?: boolean }
    return {
      content: r.message?.content ?? '',
      thinking: r.message?.thinking ?? '',
      done: Boolean(r.done),
    }
  } catch {
    return null
  }
}

export async function listModels(host: string): Promise<string[]> {
  const res = await fetch(`${base(host)}/api/tags`)
  if (!res.ok) throw new Error(`Ollama returned ${res.status}`)
  const json = (await res.json()) as { models?: Array<{ name?: string }> }
  return (json.models ?? []).map((m) => m.name ?? '').filter(Boolean)
}

/** Stream a chat completion, invoking `onChunk` for each delta. */
export async function chatStream(
  host: string,
  model: string,
  messages: ChatMessage[],
  signal: AbortSignal,
  onChunk: (c: ChatChunk) => void,
): Promise<void> {
  let res: Response
  try {
    res = await fetch(`${base(host)}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, stream: true }),
      signal,
    })
  } catch (e) {
    throw new Error(`can't reach Ollama at ${host} — is it running? (${(e as Error).message})`)
  }
  if (!res.ok || !res.body) throw new Error(`Ollama returned ${res.status} from /api/chat`)

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buf = ''
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    buf += decoder.decode(value, { stream: true })
    let nl = buf.indexOf('\n')
    while (nl >= 0) {
      const line = buf.slice(0, nl).trim()
      buf = buf.slice(nl + 1)
      if (line) {
        const chunk = parseChatChunk(line)
        if (chunk) {
          onChunk(chunk)
          if (chunk.done) return
        }
      }
      nl = buf.indexOf('\n')
    }
  }
}

/** One-shot (non-streaming) generate — used for inline autocomplete. */
export async function generate(
  host: string,
  model: string,
  prompt: string,
  signal: AbortSignal,
  options: Record<string, unknown> = {},
): Promise<string> {
  const res = await fetch(`${base(host)}/api/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, prompt, stream: false, options }),
    signal,
  })
  if (!res.ok) throw new Error(`Ollama returned ${res.status}`)
  const json = (await res.json()) as { response?: string }
  return json.response ?? ''
}

export async function embed(host: string, model: string, input: string[]): Promise<number[][]> {
  if (!input.length) return []
  const res = await fetch(`${base(host)}/api/embed`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, input }),
  })
  if (!res.ok) {
    const txt = await res.text().catch(() => '')
    throw new Error(`Ollama embed ${res.status}: ${txt.slice(0, 160)}`)
  }
  const json = (await res.json()) as { embeddings?: number[][] }
  const v = json.embeddings ?? []
  if (!v.length) {
    throw new Error(
      `no embeddings from "${model}" — pull an embedding model (\`ollama pull nomic-embed-text\`)`,
    )
  }
  return v
}

// -------------------------------------------------------------------- RAG

export interface Chunk {
  text: string
  /** 0-based line where the chunk starts. */
  line: number
}

/**
 * Split a note into chunks of roughly `target` chars, merging paragraphs and
 * skipping frontmatter. Tiny chunks are dropped.
 */
export function chunkNote(content: string, target = 900): Chunk[] {
  const size = Math.max(200, target)
  const lines = content.split(/\r?\n/)
  let i = 0
  if (lines[0]?.trim() === '---') {
    i = 1
    while (i < lines.length && lines[i].trim() !== '---') i++
    if (i < lines.length) i++
  }
  const chunks: Chunk[] = []
  let cur = ''
  let curLine = i
  let started = false
  for (; i < lines.length; i++) {
    const line = lines[i]
    if (!line.trim()) {
      if (cur.length >= size) {
        chunks.push({ text: cur.trim(), line: curLine })
        cur = ''
        started = false
      } else if (started) {
        cur += '\n'
      }
    } else {
      if (!started) {
        curLine = i
        started = true
      } else {
        cur += '\n'
      }
      cur += line
      if (cur.length >= size) {
        chunks.push({ text: cur.trim(), line: curLine })
        cur = ''
        started = false
      }
    }
  }
  if (cur.trim().length >= 20) chunks.push({ text: cur.trim(), line: curLine })
  return chunks.filter((c) => c.text.replace(/\s/g, '').length >= 20)
}

export function cosine(a: Int8Array | number[], b: Int8Array | number[]): number {
  if (a.length !== b.length || !a.length) return 0
  let dot = 0
  let na = 0
  let nb = 0
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i]
    na += a[i] * a[i]
    nb += b[i] * b[i]
  }
  if (!na || !nb) return 0
  return dot / (Math.sqrt(na) * Math.sqrt(nb))
}

/** int8 quantization with a per-vector max-abs scale (cosine is scale-invariant). */
export function quantize(v: number[]): Int8Array {
  let max = 0
  for (const x of v) max = Math.max(max, Math.abs(x))
  const out = new Int8Array(v.length)
  if (!max) return out
  const scale = max / 127
  for (let i = 0; i < v.length; i++) {
    out[i] = Math.max(-127, Math.min(127, Math.round(v[i] / scale)))
  }
  return out
}

interface RagEntry {
  path: string
  mtime: number
  chunks: Array<{ line: number; text: string; vec: string }>
}

interface RagCache {
  version: number
  model: string
  entries: RagEntry[]
}

const RAG_VERSION = 2

function encodeVec(v: Int8Array): string {
  return Buffer.from(v.buffer, v.byteOffset, v.byteLength).toString('base64')
}

function decodeVec(s: string): Int8Array {
  const buf = Buffer.from(s, 'base64')
  return new Int8Array(buf.buffer, buf.byteOffset, buf.byteLength)
}

export interface RagHit {
  path: string
  title: string
  line: number
  text: string
  score: number
}

export class RagIndex {
  private entries = new Map<string, RagEntry>()
  private model = ''

  constructor(private vault: Vault) {}

  private cachePath(): string {
    return path.join(this.vault.root, '.onyx', 'rag-index.json')
  }

  async load(model: string): Promise<void> {
    this.model = model
    try {
      const raw = await fs.readFile(this.cachePath(), 'utf8')
      const cache = JSON.parse(raw) as RagCache
      if (cache.version === RAG_VERSION && cache.model === model) {
        for (const e of cache.entries) this.entries.set(e.path, e)
      }
    } catch {
      /* no cache yet */
    }
  }

  private async save(): Promise<void> {
    const cache: RagCache = {
      version: RAG_VERSION,
      model: this.model,
      entries: [...this.entries.values()],
    }
    try {
      await fs.mkdir(path.dirname(this.cachePath()), { recursive: true })
      await fs.writeFile(this.cachePath(), JSON.stringify(cache), 'utf8')
    } catch {
      /* cache is best-effort */
    }
  }

  /** Embed everything that changed since the last build. */
  async build(
    host: string,
    model: string,
    onProgress?: (done: number, total: number) => void,
  ): Promise<{ embedded: number; total: number }> {
    if (model !== this.model) {
      this.entries.clear()
      this.model = model
    }
    const stale: Array<{ rel: string; mtime: number; chunks: Chunk[] }> = []
    for (const [rel, meta] of this.vault.notes) {
      const have = this.entries.get(rel)
      if (have && have.mtime === meta.mtime) continue
      let content: string
      try {
        content = await this.vault.read(rel)
      } catch {
        continue
      }
      const chunks = chunkNote(content)
      if (chunks.length) stale.push({ rel, mtime: meta.mtime, chunks })
      else this.entries.delete(rel)
    }
    for (const rel of [...this.entries.keys()]) {
      if (!this.vault.notes.has(rel)) this.entries.delete(rel)
    }

    const total = stale.reduce((n, s) => n + s.chunks.length, 0)
    let done = 0
    const BATCH = 24
    for (const s of stale) {
      const out: RagEntry['chunks'] = []
      for (let i = 0; i < s.chunks.length; i += BATCH) {
        const slice = s.chunks.slice(i, i + BATCH)
        const vecs = await embed(host, model, slice.map((c) => c.text))
        slice.forEach((c, k) => {
          if (vecs[k]) out.push({ line: c.line, text: c.text, vec: encodeVec(quantize(vecs[k])) })
        })
        done += slice.length
        onProgress?.(done, total)
      }
      this.entries.set(s.rel, { path: s.rel, mtime: s.mtime, chunks: out })
    }
    await this.save()
    return { embedded: total, total: this.entries.size }
  }

  async query(host: string, model: string, question: string, k = 6): Promise<RagHit[]> {
    const [qv] = await embed(host, model, [question])
    if (!qv) return []
    const q = quantize(qv)
    const hits: RagHit[] = []
    for (const entry of this.entries.values()) {
      const meta = this.vault.notes.get(entry.path)
      for (const c of entry.chunks) {
        const score = cosine(q, decodeVec(c.vec))
        hits.push({
          path: entry.path,
          title: meta?.title ?? entry.path,
          line: c.line,
          text: c.text,
          score,
        })
      }
    }
    hits.sort((a, b) => b.score - a.score)
    return hits.slice(0, k)
  }

  get size(): number {
    return this.entries.size
  }
}

// ---------------------------------------------------------------- prompts

export const ONYX_SYSTEM_PROMPT = `You are Onyx's built-in assistant, running locally on the user's machine.
You help with the user's markdown vault: answering questions about their notes,
summarizing, rewriting, brainstorming and outlining. Be concise and concrete.
Use markdown. When you reference a note, use a [[wikilink]].`

export function contextMessage(notePath: string, content: string, limit = 12000): ChatMessage {
  const body = stripFrontmatter(content).slice(0, limit)
  return {
    role: 'system',
    content: `The note currently open is "${notePath}". Its content follows between the markers.\n<<<NOTE\n${body}\nNOTE>>>`,
  }
}

export function summarizePrompt(content: string): ChatMessage[] {
  return [
    { role: 'system', content: ONYX_SYSTEM_PROMPT },
    {
      role: 'user',
      content: `Summarize the following note in 3-6 bullet points, then one short "Next steps" line if any are implied.\n\n${stripFrontmatter(content).slice(0, 16000)}`,
    },
  ]
}

export function rewritePrompt(selection: string, instruction: string): ChatMessage[] {
  return [
    {
      role: 'system',
      content: `${ONYX_SYSTEM_PROMPT}\nRewrite the user's text. Reply with ONLY the rewritten markdown — no preamble, no code fence, no commentary.`,
    },
    { role: 'user', content: `Instruction: ${instruction || 'improve clarity and flow'}\n\nText:\n${selection}` },
  ]
}

export function askPrompt(question: string, hits: RagHit[]): ChatMessage[] {
  const sources = hits
    .map((h, i) => `[${i + 1}] ${h.path} (line ${h.line + 1})\n${h.text}`)
    .join('\n\n')
  return [
    {
      role: 'system',
      content: `${ONYX_SYSTEM_PROMPT}\nAnswer using ONLY the excerpts from the user's vault below. Cite sources as [1], [2]. If the excerpts don't contain the answer, say so plainly.`,
    },
    { role: 'user', content: `Excerpts:\n\n${sources}\n\nQuestion: ${question}` },
  ]
}

export function completionPrompt(before: string, after: string): string {
  return `Continue the user's markdown note. Output ONLY the continuation text (at most one sentence or list item). No preamble, no quotes, no markdown fences.

--- text before the cursor ---
${before.slice(-1500)}
--- text after the cursor ---
${after.slice(0, 400)}
--- continuation ---
`
}
