import { describe, expect, it } from 'vitest'

import { parseGoogleTable } from './google'

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
