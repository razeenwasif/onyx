import { describe, expect, it } from 'vitest'

import type { NoteMeta, ScribeHit, SearchHit } from '@shared/types'
import { commandResults, flatten, type CommandInputs } from './command-results'

const note = (path: string, mtime = 0, aliases: string[] = []): NoteMeta => ({
  path,
  title: path,
  targets: [],
  outgoing: [],
  unresolved: [],
  tags: [],
  aliases,
  properties: [],
  mtime,
  size: 0,
  wordCount: 0,
})

const notes = new Map(
  [
    note('MATH1013/Lectures/Week 7 — Eigenvalues.md', 300),
    note('MATH1013/Lectures/Week 6 — Determinants.md', 200),
    note('Exam prep.md', 100, ['revision']),
  ].map((n) => [n.path, n]),
)

const base: CommandInputs = {
  query: '',
  filter: 'all',
  notes,
  commands: [
    { id: 'graph:open', name: 'Open graph view', hotkey: 'Cmd+G' },
    { id: 'file:new', name: 'Create new note', hotkey: 'Cmd+N' },
  ],
  tags: [
    { tag: 'exam', count: 4 },
    { tag: 'linear-algebra', count: 9 },
  ],
  contentHits: [],
  inkHits: [],
}

const titles = (input: Partial<CommandInputs>): string[] =>
  commandResults({ ...base, ...input }).map((g) => g.title)

describe('the command bar', () => {
  it('shows recent notes and commands before anything is typed', () => {
    const groups = commandResults(base)
    expect(groups.map((g) => g.title)).toEqual(['Recent', 'Commands'])
    expect(groups[0].items.map((i) => (i.kind === 'note' ? i.title : ''))).toEqual([
      'Week 7 — Eigenvalues',
      'Week 6 — Determinants',
      'Exam prep',
    ])
  })

  it('offers to ask, then notes, handwriting and commands for a query', () => {
    const ink: ScribeHit = { title: 'Lecture 14', path: '/lib/L14.json', notebook: 'Maths', section: 'LA', modified: 0, snippet: 'eigenvectors span' }
    const groups = commandResults({ ...base, query: 'eigen', inkHits: [ink] })
    expect(groups.map((g) => g.title)).toEqual(['', 'Notes', 'Handwriting'])
    expect(groups[0].items[0]).toMatchObject({ kind: 'ask', question: 'eigen' })
    const first = groups[1].items[0]
    expect(first).toMatchObject({ kind: 'note', title: 'Week 7 — Eigenvalues', folder: 'MATH1013/Lectures' })
    // The run of letters is marked, not the first "e" in "Week".
    expect(first.kind === 'note' && first.positions).toEqual([9, 10, 11, 12, 13])
  })

  it('adds notes that only match in their text, with the matching line', () => {
    const hit: SearchHit = {
      path: 'Exam prep.md',
      title: 'Exam prep',
      matches: [{ line: 3, text: '  revise [[Week 7|eigenvalues]] before [the mock](Mock.md) ', from: 9, to: 14 }],
      score: 10,
    }
    const items = flatten(commandResults({ ...base, query: 'eigenval', contentHits: [hit] }))
    const prep = items.find((i) => i.kind === 'note' && i.path === 'Exam prep.md')
    expect(prep).toMatchObject({ snippet: 'revise eigenvalues before the mock' })
  })

  it('finds a note by its alias and offers to create one that is missing', () => {
    const items = flatten(commandResults({ ...base, query: 'revision' }))
    expect(items.some((i) => i.kind === 'note' && i.path === 'Exam prep.md')).toBe(true)
    expect(items.some((i) => i.kind === 'create' && i.title === 'revision')).toBe(true)
    // An exact title doesn't get a "create".
    expect(flatten(commandResults({ ...base, query: 'Exam prep' })).some((i) => i.kind === 'create')).toBe(false)
  })

  it('lists only commands after >, and only tags after #', () => {
    expect(titles({ query: '>graph' })).toEqual(['Commands'])
    expect(titles({ query: '#lin' })).toEqual(['Tags'])
    const tag = flatten(commandResults({ ...base, query: '#lin' }))[0]
    expect(tag).toMatchObject({ kind: 'tag', tag: 'linear-algebra' })
  })

  it('narrows to one kind with a filter', () => {
    expect(titles({ query: 'e', filter: 'notes' })).toEqual(['Notes'])
    expect(titles({ query: 'open', filter: 'commands' })).toEqual(['Commands'])
  })
})
