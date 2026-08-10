import { describe, expect, it } from 'vitest'

import { DEFAULT_SETTINGS, merge } from './settings'

describe('settings merge', () => {
  it('fills in keys added since the file was written', () => {
    const merged = merge(DEFAULT_SETTINGS, { theme: 'nord' })
    expect(merged.theme).toBe('nord')
    expect(merged.graph.linkDistance).toBe(DEFAULT_SETTINGS.graph.linkDistance)
  })

  it('merges nested objects rather than replacing them', () => {
    const merged = merge(DEFAULT_SETTINGS, { graph: { nodeSize: 3 } })
    expect(merged.graph.nodeSize).toBe(3)
    expect(merged.graph.repelForce).toBe(DEFAULT_SETTINGS.graph.repelForce)
  })

  // Regression: `typeof null === 'object'`, so a null-defaulted key fell into
  // the object branch and every write to it was silently dropped — the app
  // ignored `lastVault` and always opened the default vault.
  it('writes over a null default instead of dropping the value', () => {
    expect(merge(DEFAULT_SETTINGS, { lastVault: '/vaults/notes' }).lastVault).toBe('/vaults/notes')
  })

  it('allows clearing a value back to null', () => {
    const set = merge(DEFAULT_SETTINGS, { lastVault: '/x' })
    expect(merge(set, { lastVault: null }).lastVault).toBeNull()
  })

  it('replaces arrays wholesale', () => {
    const merged = merge(DEFAULT_SETTINGS, { graph: { groups: [{ query: 'a', color: '#fff' }] } })
    expect(merged.graph.groups).toHaveLength(1)
  })

  it('ignores undefined', () => {
    expect(merge(DEFAULT_SETTINGS, undefined).theme).toBe(DEFAULT_SETTINGS.theme)
  })
})
