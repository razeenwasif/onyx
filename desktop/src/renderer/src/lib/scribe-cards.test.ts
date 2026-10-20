import { describe, expect, it } from 'vitest'

import { CARD_LINE } from './scribe-cards'

const ID = '91b2f6dd1a6e44458e615059f719f832'

describe('ink cards', () => {
  it('are Scribe links on a line of their own', () => {
    expect(CARD_LINE.exec(`  [[scribe:${ID}|Tutorials]] `)?.slice(1)).toEqual([`scribe:${ID}`, 'Tutorials'])
    expect(CARD_LINE.exec(`[[scribe:${ID}#1,2,3,4]]`)?.slice(1)).toEqual([`scribe:${ID}#1,2,3,4`, undefined])
  })

  it('leave links inside a sentence, and links to notes, alone', () => {
    expect(CARD_LINE.test(`See [[scribe:${ID}]] here`)).toBe(false)
    expect(CARD_LINE.test('[[Week 7]]')).toBe(false)
  })
})
