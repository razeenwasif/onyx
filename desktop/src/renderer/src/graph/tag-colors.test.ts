import { describe, expect, it } from 'vitest'

import { hslToHex, primaryTag, tagColor, tagFamily } from './tag-colors'

describe('tag colours', () => {
  it('collapses a nested tag to its family', () => {
    expect(tagFamily('project/web/api')).toBe('project')
    expect(tagFamily('Project')).toBe('project')
    expect(tagFamily('solo')).toBe('solo')
  })

  it('gives every tag in a family the same colour', () => {
    expect(tagColor('project/web', true)).toBe(tagColor('project/api', true))
    expect(tagColor('project', true)).toBe(tagColor('project/web', true))
  })

  it('gives different families different colours', () => {
    const colours = new Set(
      ['project', 'research', 'area', 'meeting', 'idea', 'archive'].map((t) => tagColor(t, true)),
    )
    expect(colours.size).toBe(6)
  })

  it('is stable across calls, so a colour never shifts between sessions', () => {
    expect(tagColor('physics', true)).toBe(tagColor('physics', true))
  })

  it('adapts to the theme', () => {
    expect(tagColor('physics', true)).not.toBe(tagColor('physics', false))
  })

  it('always produces a well-formed hex colour', () => {
    for (const tag of ['a', 'zz/yy', 'Électro', '123']) {
      expect(tagColor(tag, true)).toMatch(/^#[0-9a-f]{6}$/)
    }
  })

  it('picks a note colour deterministically, not by order', () => {
    expect(primaryTag(['zeta', 'alpha', 'mu'])).toBe('alpha')
    expect(primaryTag(['alpha', 'mu', 'zeta'])).toBe('alpha')
    expect(primaryTag([])).toBeNull()
  })

  it('converts HSL to hex at the extremes', () => {
    expect(hslToHex(0, 0, 0)).toBe('#000000')
    expect(hslToHex(0, 0, 100)).toBe('#ffffff')
    expect(hslToHex(0, 100, 50)).toBe('#ff0000')
  })
})
