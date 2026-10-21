import { describe, expect, it } from 'vitest'

import { agyArgs, claudeArgs, newParseState, parseAgyLine, parseClaudeLine, toolSummary } from './agents'
import type { AgentRunRequest } from '../shared/types'

const ROOT = '/Users/me/Vault'

const req = (over: Partial<AgentRunRequest> = {}): AgentRunRequest => ({
  runId: 'r1',
  agent: 'claude',
  prompt: 'Tidy this note',
  sessionId: null,
  model: '',
  notePath: 'Exam prep.md',
  allowEdits: true,
  ...over,
})

describe('Claude Code', () => {
  it('runs with file and web tools only, in the vault, continuing a session', () => {
    const args = claudeArgs(req({ sessionId: 'abc', model: 'sonnet' }), ROOT)
    expect(args).toContain('--include-partial-messages')
    expect(args[args.indexOf('--tools') + 1]).not.toMatch(/Bash/)
    expect(args[args.indexOf('--permission-mode') + 1]).toBe('acceptEdits')
    expect(args[args.indexOf('--resume') + 1]).toBe('abc')
    expect(args[args.indexOf('--model') + 1]).toBe('sonnet')
    expect(args[args.indexOf('--append-system-prompt') + 1]).toContain('Exam prep.md')
    // Told which notes there are, so it can find one by name.
    const listed = claudeArgs(req(), ROOT, ['A.md', 'Folder/B.md'])
    expect(listed[listed.indexOf('--append-system-prompt') + 1]).toMatch(/notes \(2\):\nA\.md\nFolder\/B\.md$/)
    // Read-only when edits are off.
    const ro = claudeArgs(req({ allowEdits: false }), ROOT)
    expect(ro[ro.indexOf('--permission-mode') + 1]).toBe('plan')
  })

  it('turns its stream into session, text, tool and done events', () => {
    const s = newParseState(ROOT)
    const lines = [
      { type: 'system', subtype: 'init', session_id: 'S1', model: 'claude-haiku-5-5' },
      { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Look' } } },
      { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'input_json_delta', partial_json: '{' } } },
      { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'T1', name: 'Edit', input: { file_path: `${ROOT}/Exam prep.md` } }] } },
      { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'T1', content: 'ok' }] } },
      { type: 'result', session_id: 'S1', total_cost_usd: 0.0084, is_error: false, result: 'Done' },
    ]
    const events = lines.flatMap((l) => parseClaudeLine(JSON.stringify(l), s))
    expect(events).toEqual([
      { kind: 'session', id: 'S1', model: 'claude-haiku-5-5' },
      { kind: 'text', delta: 'Look' },
      { kind: 'tool', id: 'T1', name: 'Edit', summary: 'Exam prep.md', state: 'running', writes: true },
      { kind: 'tool', id: 'T1', name: 'Edit', summary: 'Exam prep.md', state: 'done', detail: undefined, writes: true },
      { kind: 'done', sessionId: 'S1', costUsd: 0.0084, error: undefined },
    ])
  })

  it('ignores lines it can’t read', () => {
    expect(parseClaudeLine('not json', newParseState(ROOT))).toEqual([])
  })
})

describe('Antigravity', () => {
  it('runs sandboxed with the context in the prompt, continuing a conversation', () => {
    const args = agyArgs(req({ agent: 'antigravity', sessionId: 'C1' }), ROOT)
    expect(args[args.indexOf('-p') + 1]).toMatch(/Exam prep\.md[\s\S]*Tidy this note$/)
    expect(args).toContain('--sandbox')
    expect(args[args.indexOf('--mode') + 1]).toBe('accept-edits')
    expect(args[args.indexOf('--conversation') + 1]).toBe('C1')
  })

  it('turns its step updates into events, with denied commands at the end', () => {
    const s = newParseState(ROOT)
    const lines = [
      { event: 'init', conversation_id: 'C1', init: {} },
      { event: 'step_update', step_update: { conversation_id: 'C1', step_index: 3, state: 'ACTIVE', step_type: 'tool', tool_name: 'read_file', tool_info: { parameters: { Path: `${ROOT}/Exam prep.md` } } } },
      { event: 'step_update', step_update: { conversation_id: 'C1', step_index: 3, state: 'DONE', step_type: 'tool', tool_name: 'read_file', tool_info: { parameters: { Path: `${ROOT}/Exam prep.md` } } } },
      { event: 'step_update', step_update: { conversation_id: 'C1', step_index: 4, state: 'ACTIVE', step_type: 'agent_response', text_delta: 'A study note' } },
      { event: 'result', result: { conversation_id: 'C1', status: 'SUCCESS', denied_actions: [{ action: 'command', display_name: 'RunCommand' }] } },
    ]
    const events = lines.flatMap((l) => parseAgyLine(JSON.stringify(l), s))
    expect(events).toEqual([
      { kind: 'session', id: 'C1' },
      { kind: 'tool', id: 'C1:3', name: 'read_file', summary: 'Exam prep.md', state: 'running', detail: undefined, writes: false },
      { kind: 'tool', id: 'C1:3', name: 'read_file', summary: 'Exam prep.md', state: 'done', detail: undefined, writes: false },
      { kind: 'text', delta: 'A study note' },
      { kind: 'done', sessionId: 'C1', error: undefined, denied: ['RunCommand'] },
    ])
  })
})

describe('tool summaries', () => {
  it('show paths relative to the vault, or the pattern or URL', () => {
    expect(toolSummary({ pattern: '**/*.md' }, ROOT)).toBe('**/*.md')
    expect(toolSummary({ pattern: 'Exam prep', path: ROOT }, ROOT)).toBe('Exam prep')
    expect(toolSummary({ DirectoryPath: ROOT }, ROOT)).toBe('(vault)')
    expect(toolSummary({ url: 'https://example.com' }, ROOT)).toBe('https://example.com')
    expect(toolSummary(undefined, ROOT)).toBe('')
  })
})
