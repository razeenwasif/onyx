import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import * as path from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { shell } from 'electron'

vi.mock('electron', () => ({ shell: { openExternal: vi.fn() } }))

const realFetch = globalThis.fetch

import { monthRange, parseGoogleTable, runConsentFlow } from './google'

describe('reading [google] out of the TUI config', () => {
  const config = [
    'last_vault = "/home/me/Vault"',
    '',
    '[google]',
    'client_id = "1234-abc.apps.googleusercontent.com"',
    'client_secret = "GOCSPX-notARealSecret"',
    'sync_tasks = true',
    '',
    '[ai]',
    'model = "gemma"',
  ].join('\n')

  it('reads both keys', () => {
    expect(parseGoogleTable(config)).toEqual({
      clientId: '1234-abc.apps.googleusercontent.com',
      clientSecret: 'GOCSPX-notARealSecret',
    })
  })

  // Regression: the section was matched with `\Z` for end-of-input, which is
  // Perl/Python. JavaScript reads it as a literal "Z", so the table was cut at
  // the first capital Z inside the secret and the app reported that no OAuth
  // client was configured.
  it('does not truncate a secret containing a capital Z', () => {
    const withZ = config.replace('GOCSPX-notARealSecret', 'GOCSPX-haZardousSecretZ')
    expect(parseGoogleTable(withZ).clientSecret).toBe('GOCSPX-haZardousSecretZ')
  })

  it('reads a table that runs to the end of the file', () => {
    const trailing = '[google]\nclient_id = "id"\nclient_secret = "secret"\n'
    expect(parseGoogleTable(trailing)).toEqual({ clientId: 'id', clientSecret: 'secret' })
  })

  it('returns blanks when the table is absent or empty', () => {
    expect(parseGoogleTable('[ai]\nmodel = "x"\n')).toEqual({ clientId: '', clientSecret: '' })
    expect(parseGoogleTable('[google]\n')).toEqual({ clientId: '', clientSecret: '' })
  })

  it('does not read keys out of a different table', () => {
    const other = '[other]\nclient_id = "wrong"\n\n[google]\nclient_secret = "right"\n'
    expect(parseGoogleTable(other)).toEqual({ clientId: '', clientSecret: 'right' })
  })
})

describe('signing in to Google', () => {
  it('exchanges the code with the same redirect address Google was given', async () => {
    const dir = await mkdtemp(path.join(tmpdir(), 'onyx-google-'))
    process.env.ONYX_CONFIG_DIR = dir
    let authUrl = ''
    vi.mocked(shell.openExternal).mockImplementation(async (url: string) => {
      authUrl = url
      // The browser: Google sends it back to the loopback address, after it
      // has asked for a favicon.
      const u = new URL(url)
      const back = u.searchParams.get('redirect_uri')!
      await realFetch(`${back}/favicon.ico`)
      await realFetch(`${back}/?code=abc&state=${u.searchParams.get('state')}`)
    })
    let exchanged: URLSearchParams | null = null
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      exchanged = new URLSearchParams(String(init.body))
      return new Response(JSON.stringify({ access_token: 'at', refresh_token: 'rt', expires_in: 3600 }), { status: 200 })
    })
    vi.stubGlobal('fetch', fetchMock)
    try {
      const token = await runConsentFlow({ clientId: 'id', clientSecret: 'secret', source: 'desktop' })
      expect(token.refresh_token).toBe('rt')
      const given = new URL(authUrl).searchParams.get('redirect_uri')
      expect(given).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/)
      expect(given).not.toBe('http://127.0.0.1:0')
      expect(exchanged!.get('redirect_uri')).toBe(given)
      expect(exchanged!.get('code')).toBe('abc')
    } finally {
      vi.unstubAllGlobals()
      delete process.env.ONYX_CONFIG_DIR
      await rm(dir, { recursive: true, force: true })
    }
  })
})

describe('the month asked of Google Calendar', () => {
  it('runs from local midnight on the 1st to local midnight on the next 1st', () => {
    expect(monthRange(2026, 10)).toEqual([new Date(2026, 9, 1).toISOString(), new Date(2026, 10, 1).toISOString()])
    expect(monthRange(2026, 12)[1]).toBe(new Date(2027, 0, 1).toISOString())
  })
})
