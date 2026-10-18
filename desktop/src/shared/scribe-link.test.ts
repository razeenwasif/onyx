import { describe, expect, it } from 'vitest'

import { extractLinks } from './parse'
import { isScribeTarget, parseScribeTarget, scribeLink } from './scribe-link'

describe('Scribe links', () => {
  const id = '26fe650fab4f4f798f717eeed5190a7b'

  it('parses a page and an area of one', () => {
    expect(parseScribeTarget(`scribe:${id}`)).toEqual({ pageId: id, area: null })
    expect(parseScribeTarget(`scribe:${id}#10,20,300,140`)).toEqual({
      pageId: id,
      area: { x: 10, y: 20, width: 300, height: 140 },
    })
  })

  it('ignores a malformed area and non-Scribe targets', () => {
    expect(parseScribeTarget(`scribe:${id}#10,20`)?.area).toBeNull()
    expect(parseScribeTarget(`scribe:${id}#1,2,0,5`)?.area).toBeNull()
    expect(parseScribeTarget('scribe:')).toBeNull()
    expect(parseScribeTarget('Eigenvalues')).toBeNull()
    expect(isScribeTarget('Scribe: notes')).toBe(true)
    expect(isScribeTarget('Scribe notes')).toBe(false)
  })

  it('round-trips through the wikilink parser with its title', () => {
    const link = scribeLink(id, 'Tutorials | week [3]')
    expect(link).toBe(`[[scribe:${id}|Tutorials - week (3)]]`)
    const [m] = extractLinks(`See ${link}.`)
    expect(m.target).toBe(`scribe:${id}`)
    expect(m.alias).toBe('Tutorials - week (3)')
  })
})
