import { describe, expect, it } from 'vitest'

import { scribeQuery } from './scribe-query'

describe('what search sends to Scribe', () => {
  it('passes plain text through, trimmed', () => {
    expect(scribeQuery('  laplace transform ')).toBe('laplace transform')
  })

  it('unwraps a quoted phrase', () => {
    expect(scribeQuery('"fourier series"')).toBe('fourier series')
  })

  it('skips queries that use search operators', () => {
    expect(scribeQuery('tag:physics')).toBeNull()
    expect(scribeQuery('notes path:lectures')).toBeNull()
    expect(scribeQuery('FILE:week3')).toBeNull()
    expect(scribeQuery('energy -draft')).toBeNull()
  })

  it('keeps colons and hyphens that are just text', () => {
    expect(scribeQuery('meeting 10:30')).toBe('meeting 10:30')
    expect(scribeQuery('well-known result')).toBe('well-known result')
  })

  it('ignores empty input', () => {
    expect(scribeQuery('   ')).toBeNull()
    expect(scribeQuery('""')).toBeNull()
  })
})
