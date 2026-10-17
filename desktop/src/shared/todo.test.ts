import { describe, expect, it } from 'vitest'

import { moveTodo, parseTodos, serializeTodos, sweep, type TodoItem } from './todo'

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

describe('reordering todos', () => {
  const open = (text: string): TodoItem => ({ text, done: false, doneOn: null })
  const done = (text: string): TodoItem => ({ text, done: true, doneOn: TODAY })
  const texts = (items: TodoItem[]): string[] => items.map((i) => i.text)
  const list = [open('a'), open('b'), open('c'), done('x'), done('y')]

  it('moves an item down and up', () => {
    expect(texts(moveTodo(list, 0, 2))).toEqual(['b', 'c', 'a', 'x', 'y'])
    expect(texts(moveTodo(list, 2, 0))).toEqual(['c', 'a', 'b', 'x', 'y'])
  })

  it('keeps open items above completed ones', () => {
    expect(texts(moveTodo(list, 1, 4))).toEqual(['a', 'c', 'b', 'x', 'y'])
    expect(texts(moveTodo(list, 4, 0))).toEqual(['a', 'b', 'c', 'y', 'x'])
  })

  it('leaves the list alone for a no-op or a bad index', () => {
    expect(moveTodo(list, 1, 1)).toBe(list)
    expect(moveTodo(list, 9, 0)).toBe(list)
  })

  it('writes the new order to the file', () => {
    const moved = moveTodo(list, 2, 0)
    expect(serializeTodos(moved, TODAY).split('\n')[0]).toBe('- [ ] c')
  })
})
