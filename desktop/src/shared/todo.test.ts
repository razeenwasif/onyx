import { describe, expect, it } from 'vitest'

import { parseTodos, serializeTodos, sweep } from './todo'

const TODAY = '2026-08-10'

describe('todo checklist', () => {
  it('round-trips the TUI file format', () => {
    const src = '- [ ] open one\n- [x] finished <!--done:2026-08-09-->\n'
    const items = parseTodos(src, TODAY)
    expect(items).toEqual([
      { text: 'open one', done: false, doneOn: null },
      { text: 'finished', done: true, doneOn: '2026-08-09' },
    ])
    expect(serializeTodos(items, TODAY)).toBe(src)
  })

  it('ignores lines that are not checklist items', () => {
    expect(parseTodos('# Heading\n\nsome prose\n', TODAY)).toEqual([])
  })

  it('dates an item ticked elsewhere, so its week starts now', () => {
    const [item] = parseTodos('- [x] ticked in Obsidian\n', TODAY)
    expect(item.doneOn).toBe(TODAY)
  })

  it('writes completed items last, whatever order they came in', () => {
    const out = serializeTodos(
      [
        { text: 'done', done: true, doneOn: TODAY },
        { text: 'open', done: false, doneOn: null },
      ],
      TODAY,
    )
    expect(out).toBe(`- [ ] open\n- [x] done <!--done:${TODAY}-->\n`)
  })

  it('sweeps completed items after a week but keeps open ones forever', () => {
    const items = parseTodos(
      [
        '- [ ] ancient but open',
        '- [x] six days ago <!--done:2026-08-04-->',
        '- [x] seven days ago <!--done:2026-08-03-->',
      ].join('\n'),
      TODAY,
    )
    expect(sweep(items, TODAY).map((i) => i.text)).toEqual(['ancient but open', 'six days ago'])
  })

  it('survives a round trip through sweep unchanged when nothing expired', () => {
    const src = '- [ ] a\n- [x] b <!--done:2026-08-09-->\n'
    expect(serializeTodos(sweep(parseTodos(src, TODAY), TODAY), TODAY)).toBe(src)
  })
})
