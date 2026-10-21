/**
 * Coding agents that work on the vault: Claude Code (`claude`) and Google's
 * Antigravity (`agy`), run headless in the vault folder.
 *
 * Each turn spawns the CLI in print mode with streaming JSON output, and the
 * lines it prints are turned into one small event stream the Agent pane
 * draws (text as it arrives, each tool step, the end of the turn). A
 * conversation continues by passing the session id back (`--resume` /
 * `--conversation`). The agents may read and edit notes; neither may run
 * shell commands: Claude Code is given only file and web tools, and agy
 * denies commands itself in headless mode.
 */

import { spawn, execFile, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'

import type { AgentEvent, AgentId, AgentRunRequest } from '../shared/types.js'

// ------------------------------------------------------------ finding them

const BIN: Record<AgentId, string> = { claude: 'claude', antigravity: 'agy' }

/**
 * Where an agent's CLI is. An app opened from Finder doesn't get the login
 * shell's PATH, so look in the usual install folders, then ask the shell.
 */
export async function findAgent(agent: AgentId): Promise<string | null> {
  const name = BIN[agent]
  const home = os.homedir()
  const dirs = [path.join(home, '.local', 'bin'), '/opt/homebrew/bin', '/usr/local/bin', path.join(home, '.claude', 'local')]
  for (const dir of dirs) {
    const file = path.join(dir, name)
    if (existsSync(file)) return file
  }
  if (process.platform === 'win32') return null
  const shell = process.env.SHELL || '/bin/zsh'
  return new Promise((resolve) => {
    execFile(shell, ['-lc', `command -v ${name}`], { timeout: 5000 }, (err, out) => {
      const hit = out?.trim().split('\n').pop()
      resolve(!err && hit && existsSync(hit) ? hit : null)
    })
  })
}

// ------------------------------------------------------------- arguments

/** What the agent is told about where it is, on top of its own prompt. */
export function contextPrompt(vaultRoot: string, notePath: string | null, notes: string[] = []): string {
  const listed = notes.slice(0, NOTE_LIST_LIMIT)
  const list = listed.length
    ? `\nThe vault's notes (${notes.length}${notes.length > listed.length ? `, the ${listed.length} edited last` : ''}):\n${listed.join('\n')}`
    : ''
  return [
    `You are working in the user's Markdown notes vault at ${vaultRoot}, from inside Electron, their notes app.`,
    'Notes are Markdown files with Obsidian-style [[wikilinks]], #tags and YAML frontmatter; keep that style when you write.',
    'Refer to notes by their vault-relative path.',
    'Use only your file tools (list, find, search, read, edit) on this folder: shell commands, MCP servers and the browser are not available here.',
    notePath ? `The note open in the editor now is ${notePath}.` : 'No note is open in the editor.',
  ].join(' ') + list
}

/** How many note paths the agent is told about up front. */
const NOTE_LIST_LIMIT = 400

/** Claude Code's file and web tools: everything but the shell. */
const CLAUDE_TOOLS = 'Read,Edit,Write,Glob,Grep,WebSearch,WebFetch'

export function claudeArgs(req: AgentRunRequest, vaultRoot: string, notes: string[] = []): string[] {
  const args = [
    '-p',
    '--output-format', 'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--permission-mode', req.allowEdits ? 'acceptEdits' : 'plan',
    '--tools', CLAUDE_TOOLS,
    // Only the vault: no MCP servers from the user's own setup.
    '--strict-mcp-config',
    '--append-system-prompt', contextPrompt(vaultRoot, req.notePath, notes),
  ]
  if (req.sessionId) args.push('--resume', req.sessionId)
  if (req.model) args.push('--model', req.model)
  return args
}

export function agyArgs(req: AgentRunRequest, vaultRoot: string, notes: string[] = []): string[] {
  const args = [
    '-p', `${contextPrompt(vaultRoot, req.notePath, notes)}\n\n${req.prompt}`,
    '--output-format', 'stream-json',
    '--mode', req.allowEdits ? 'accept-edits' : 'plan',
    '--sandbox',
  ]
  if (req.sessionId) args.push('--conversation', req.sessionId)
  if (req.model) args.push('--model', req.model)
  return args
}

// --------------------------------------------------------------- parsing

/** What a tool step was about, in a few words: a note's path, a pattern, a URL. */
export function toolSummary(input: Record<string, unknown> | undefined, vaultRoot: string): string {
  if (!input) return ''
  const keys = [
    'file_path', 'path', 'Path', 'TargetFile', 'AbsolutePath', 'DirectoryPath', 'notebook_path',
    'pattern', 'Pattern', 'Query', 'query', 'url', 'Url', 'CommandLine', 'command', 'description',
  ]
  for (const key of keys) {
    const v = input[key]
    if (typeof v === 'string' && v.trim()) return relative(v.trim(), vaultRoot)
  }
  return ''
}

function relative(value: string, vaultRoot: string): string {
  const root = vaultRoot.replace(/\/+$/, '')
  if (value === root) return '(vault)'
  return value.startsWith(root + '/') ? value.slice(root.length + 1) : value
}

/** Tools that change notes, so the pane can list the files touched. */
const WRITES = new Set([
  'Edit', 'Write', 'MultiEdit', 'NotebookEdit',
  'edit_file', 'create_file', 'write_to_file', 'replace_file_content', 'multi_replace_file_content', 'sed_file', 'notebook_edit',
])

export interface ParseState {
  vaultRoot: string
  /** Tool steps already reported, by id, with their name and summary. */
  tools: Map<string, { name: string; summary: string }>
}

export function newParseState(vaultRoot: string): ParseState {
  return { vaultRoot, tools: new Map() }
}

/** One line of `claude -p --output-format stream-json --verbose --include-partial-messages`. */
export function parseClaudeLine(line: string, state: ParseState): AgentEvent[] {
  let j: Record<string, any>
  try {
    j = JSON.parse(line)
  } catch {
    return []
  }
  const out: AgentEvent[] = []
  switch (j.type) {
    case 'system':
      if (j.subtype === 'init' && j.session_id) out.push({ kind: 'session', id: j.session_id, model: j.model })
      break
    case 'stream_event': {
      const e = j.event
      if (e?.type === 'content_block_delta' && e.delta?.type === 'text_delta' && e.delta.text) {
        out.push({ kind: 'text', delta: e.delta.text })
      } else if (e?.type === 'content_block_start' && e.content_block?.type === 'thinking') {
        out.push({ kind: 'thinking' })
      }
      break
    }
    case 'assistant':
      for (const block of j.message?.content ?? []) {
        if (block.type !== 'tool_use' || state.tools.has(block.id)) continue
        const summary = toolSummary(block.input, state.vaultRoot)
        state.tools.set(block.id, { name: block.name, summary })
        out.push({ kind: 'tool', id: block.id, name: block.name, summary, state: 'running', writes: WRITES.has(block.name) })
      }
      break
    case 'user':
      for (const block of j.message?.content ?? []) {
        if (block.type !== 'tool_result') continue
        const tool = state.tools.get(block.tool_use_id)
        if (!tool) continue
        const text = typeof block.content === 'string' ? block.content : (block.content ?? []).map((c: any) => c.text ?? '').join('')
        out.push({
          kind: 'tool',
          id: block.tool_use_id,
          name: tool.name,
          summary: tool.summary,
          state: block.is_error ? 'error' : 'done',
          detail: block.is_error ? String(text).slice(0, 300) : undefined,
          writes: WRITES.has(tool.name),
        })
      }
      break
    case 'result':
      out.push({
        kind: 'done',
        sessionId: j.session_id,
        costUsd: typeof j.total_cost_usd === 'number' ? j.total_cost_usd : undefined,
        error: j.is_error ? String(j.result ?? j.subtype ?? 'The agent stopped with an error') : undefined,
      })
      break
  }
  return out
}

/** One line of `agy -p --output-format stream-json`. */
export function parseAgyLine(line: string, state: ParseState): AgentEvent[] {
  let j: Record<string, any>
  try {
    j = JSON.parse(line)
  } catch {
    return []
  }
  if (j.event === 'init') return j.conversation_id ? [{ kind: 'session', id: j.conversation_id }] : []
  if (j.event === 'result') {
    const r = j.result ?? {}
    const denied = (r.denied_actions ?? []).map((d: any) => d.display_name ?? d.action).filter(Boolean)
    return [{
      kind: 'done',
      sessionId: r.conversation_id,
      error: r.status && r.status !== 'SUCCESS' ? `The agent stopped: ${String(r.status).toLowerCase()}` : undefined,
      denied: denied.length ? denied : undefined,
    }]
  }
  const step = j.step_update
  if (j.event !== 'step_update' || !step) return []
  if (step.step_type === 'agent_response' && step.text_delta) return [{ kind: 'text', delta: step.text_delta }]
  if (step.step_type === 'tool' && step.tool_name) {
    const id = `${step.conversation_id}:${step.step_index}`
    const info = step.tool_info ?? {}
    const summary = toolSummary(info.parameters, state.vaultRoot)
    state.tools.set(id, { name: step.tool_name, summary })
    const s = step.state === 'DONE' ? 'done' : step.state === 'ERROR' ? 'error' : 'running'
    return [{
      kind: 'tool',
      id,
      name: step.tool_name,
      summary,
      state: s,
      detail: s === 'error' ? String(info.error?.message ?? '').split('\n')[0].slice(0, 300) : undefined,
      writes: WRITES.has(step.tool_name),
    }]
  }
  return []
}

// ------------------------------------------------------------------ runs

const runs = new Map<string, ChildProcess>()

/**
 * Starts one turn and reports its events through `emit`, ending with a
 * `done` (or `error`) event. Returns once the process has started.
 */
export async function runAgent(
  req: AgentRunRequest,
  vaultRoot: string,
  /** Vault-relative note paths, most recently edited first. */
  notes: string[],
  emit: (event: AgentEvent) => void,
): Promise<void> {
  const bin = await findAgent(req.agent)
  if (!bin) {
    emit({ kind: 'error', message: req.agent === 'claude' ? 'Claude Code (claude) isn’t installed.' : 'Antigravity’s CLI (agy) isn’t installed.' })
    return
  }
  const args = req.agent === 'claude' ? claudeArgs(req, vaultRoot, notes) : agyArgs(req, vaultRoot, notes)
  const parse = req.agent === 'claude' ? parseClaudeLine : parseAgyLine
  const state = newParseState(vaultRoot)

  const child = spawn(bin, args, {
    cwd: vaultRoot,
    env: { ...process.env, PATH: `${path.dirname(bin)}:${process.env.PATH ?? ''}` },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  runs.set(req.runId, child)
  // Claude Code reads the prompt from stdin; agy has it as an argument.
  if (req.agent === 'claude') child.stdin.end(req.prompt)
  else child.stdin.end()

  let buffer = ''
  let finished = false
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk: string) => {
    buffer += chunk
    let nl: number
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim()
      buffer = buffer.slice(nl + 1)
      if (!line) continue
      for (const event of parse(line, state)) {
        if (event.kind === 'done') finished = true
        emit(event)
      }
    }
  })
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk: string) => {
    stderr = (stderr + chunk).slice(-4000)
  })
  child.on('error', (err) => {
    runs.delete(req.runId)
    emit({ kind: 'error', message: err.message })
  })
  child.on('close', (code, signal) => {
    runs.delete(req.runId)
    if (finished) return
    if (signal) emit({ kind: 'done', error: 'Stopped' })
    else emit({ kind: 'error', message: lastLines(stderr) || `The agent exited with code ${code}` })
  })
}

export function stopAgent(runId: string): void {
  runs.get(runId)?.kill('SIGTERM')
}

export function stopAllAgents(): void {
  for (const child of runs.values()) child.kill('SIGTERM')
  runs.clear()
}

function lastLines(text: string): string {
  return text
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(-3)
    .join('\n')
}
