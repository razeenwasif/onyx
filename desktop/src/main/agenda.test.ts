import { describe, expect, it } from 'vitest'

import { agendaRange } from './agenda'

describe('the agenda shared with the iPad', () => {
  it('runs from a week back to three weeks ahead, across the months that covers', () => {
    const r = agendaRange(new Date(2026, 9, 22))
    expect(r.from).toBe('2026-10-15')
    expect(r.to).toBe('2026-11-12')
    expect(r.months).toEqual([[2026, 10], [2026, 11]])
  })

  it('crosses a year end', () => {
    const r = agendaRange(new Date(2026, 11, 20))
    expect(r.months).toEqual([[2026, 12], [2027, 1]])
  })
})
