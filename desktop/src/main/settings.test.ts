import { describe, expect, it } from 'vitest'

import { DEFAULT_SETTINGS, SETTINGS_VERSION, merge, migrate } from './settings'

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

describe('settings migration', () => {
  it('moves an install on the old default theme to Electron Velvet', () => {
    const out = migrate({ theme: 'onyx-dark' }) as Record<string, unknown>
    expect(out.theme).toBe('electron-velvet')
    expect(out.settingsVersion).toBe(SETTINGS_VERSION)
  })

  it('keeps a theme the user picked themselves', () => {
    expect((migrate({ theme: 'nord' }) as Record<string, unknown>).theme).toBe('nord')
  })

  it('runs once: choosing Onyx Dark again after the upgrade sticks', () => {
    const out = migrate({ settingsVersion: SETTINGS_VERSION, theme: 'onyx-dark' })
    expect((out as Record<string, unknown>).theme).toBe('onyx-dark')
  })

  it('defaults new installs to Electron Velvet', () => {
    expect(DEFAULT_SETTINGS.theme).toBe('electron-velvet')
    expect(merge(DEFAULT_SETTINGS, migrate({})).theme).toBe('electron-velvet')
  })

  it('passes non-object files through for merge to reject', () => {
    expect(migrate(null)).toBeNull()
    expect(migrate([1])).toEqual([1])
  })
})
