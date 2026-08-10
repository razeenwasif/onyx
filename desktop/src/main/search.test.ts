import { promises as fs } from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { fuzzyScore, matchesMeta, parseQuery, search, unlinkedMentions } from './search'
import { Vault, parseNote } from './vault'

describe('query parsing', () => {
  it('splits bare terms, quoted phrases and exclusions', () => {
    const q = parseQuery('alpha "two words" -beta')
    expect(new Set(q.terms)).toEqual(new Set(['alpha', 'two words']))
    expect(q.excluded).toEqual(['beta'])
  })

  it('reads the operators', () => {
    const q = parseQuery('tag:project path:Notes/ file:readme line:12 #inbox')
    expect(q.tags).toEqual(['project', 'inbox'])
    expect(q.paths).toEqual(['notes/'])
    expect(q.files).toEqual(['readme'])
    expect(q.line).toBe(12)
  })

  it('uses smart case', () => {
    expect(parseQuery('lower').smartCase).toBe(false)
    expect(parseQuery('Upper').smartCase).toBe(true)
  })
})

describe('metadata matching', () => {
  const meta = parseNote('Notes/Readme.md', '# Readme\n\n#project/web\n')

  it('matches a tag and its children', () => {
    expect(matchesMeta(meta, parseQuery('tag:project'))).toBe(true)
    expect(matchesMeta(meta, parseQuery('tag:project/web'))).toBe(true)
    expect(matchesMeta(meta, parseQuery('tag:other'))).toBe(false)
  })

  it('matches path and filename fragments', () => {
    expect(matchesMeta(meta, parseQuery('path:notes'))).toBe(true)
    expect(matchesMeta(meta, parseQuery('file:read'))).toBe(true)
    expect(matchesMeta(meta, parseQuery('path:archive'))).toBe(false)
  })
})

describe('fuzzy scoring', () => {
  it('rejects a needle that is not a subsequence', () => {
    expect(fuzzyScore('xyz', 'alphabet')).toBeNull()
  })

  it('prefers word-boundary and consecutive matches', () => {
    const boundary = fuzzyScore('mn', 'my notes')!.score
    const scattered = fuzzyScore('mn', 'maximum nonsense here')!.score
    expect(boundary).toBeGreaterThan(scattered)
  })

  it('reports where it matched, for highlighting', () => {
    expect(fuzzyScore('ac', 'abc')!.positions).toEqual([0, 2])
  })

  it('treats an empty needle as a trivial match', () => {
    expect(fuzzyScore('', 'anything')).toEqual({ score: 0, positions: [] })
  })
})

describe('full-vault search', () => {
  let root: string
  let vault: Vault

  beforeEach(async () => {
    root = await fs.mkdtemp(path.join(os.tmpdir(), 'onyx-search-test-'))
    const write = async (rel: string, body: string): Promise<void> => {
      await fs.mkdir(path.dirname(path.join(root, rel)), { recursive: true })
      await fs.writeFile(path.join(root, rel), body, 'utf8')
    }
    await write('Alpha.md', '# Alpha\n\nthe quick brown fox\n\n#animals\n')
    await write('Beta.md', '# Beta\n\nthe lazy dog sleeps\n\n#animals\n')
    await write('Notes/Gamma.md', '# Gamma\n\nno creatures here\n')
    vault = new Vault(root)
    await vault.load()
  })

  afterEach(async () => {
    await vault.close()
    await fs.rm(root, { recursive: true, force: true })
  })

  it('finds a term and reports the matching line', async () => {
    const hits = await search(vault, 'brown')
    expect(hits.map((h) => h.path)).toEqual(['Alpha.md'])
    expect(hits[0].matches[0].text).toContain('quick brown fox')
  })

  it('requires every term', async () => {
    expect(await search(vault, 'quick lazy')).toEqual([])
  })

  it('honours exclusions', async () => {
    const hits = await search(vault, 'the -lazy')
    expect(hits.map((h) => h.path)).toEqual(['Alpha.md'])
  })

  it('filters by tag without needing a text term', async () => {
    const hits = await search(vault, 'tag:animals')
    expect(hits.map((h) => h.path).sort()).toEqual(['Alpha.md', 'Beta.md'])
  })

  it('combines an operator with a term', async () => {
    const hits = await search(vault, 'tag:animals dog')
    expect(hits.map((h) => h.path)).toEqual(['Beta.md'])
  })

  it('is case-insensitive until the query has a capital', async () => {
    expect((await search(vault, 'ALPHA')).length).toBe(0)
    expect((await search(vault, 'alpha')).length).toBeGreaterThan(0)
  })

  it('reads through the content cache, so results survive a cold index', async () => {
    // Warm the cache, then delete the file: a cached scan still finds it,
    // which is the behaviour that keeps search fast on a slow filesystem.
    await search(vault, 'brown')
    await fs.rm(path.join(root, 'Alpha.md'))
    expect((await search(vault, 'brown')).map((h) => h.path)).toEqual(['Alpha.md'])
  })

  it('finds notes that name another without linking it', async () => {
    await fs.writeFile(path.join(root, 'Delta.md'), '# Delta\n\nI mention Alpha in passing.\n')
    await vault.load()
    const mentions = await unlinkedMentions(vault, 'Alpha.md')
    expect(mentions.map((m) => m.path)).toEqual(['Delta.md'])
    expect(mentions[0].contexts[0].text).toContain('mention Alpha')
  })

  it('does not report a note that already links the target', async () => {
    await fs.writeFile(path.join(root, 'Delta.md'), '# Delta\n\nSee [[Alpha]].\n')
    await vault.load()
    expect(await unlinkedMentions(vault, 'Alpha.md')).toEqual([])
  })
})
