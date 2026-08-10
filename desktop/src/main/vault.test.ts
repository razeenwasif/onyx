import { promises as fs } from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { Vault, isNetworkPath, parseNote, rewriteLinks } from './vault'

let root: string
let vault: Vault

async function write(rel: string, content: string): Promise<void> {
  const target = path.join(root, rel)
  await fs.mkdir(path.dirname(target), { recursive: true })
  await fs.writeFile(target, content, 'utf8')
}

beforeEach(async () => {
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'onyx-vault-test-'))
  await write('Home.md', '---\ntags: [index]\n---\n\n# Home\n\n[[Onyx]] and [[Projects/Roadmap]].\n')
  await write('Onyx.md', '# Onyx\n\nBack to [[Home]]. Missing: [[Nowhere]].\n\n#tools/editor\n')
  await write('Projects/Roadmap.md', '# Roadmap\n\nSee [[Onyx]].\n\n#project\n')
  await write('Projects/Onyx.md', '# Duplicate name\n\nIn a subfolder.\n')
  await write('attachments/diagram.png', 'not-really-a-png')
  vault = new Vault(root)
  await vault.load()
})

afterEach(async () => {
  await vault.close()
  await fs.rm(root, { recursive: true, force: true })
})

describe('scanning', () => {
  it('indexes markdown and keeps other files as attachments', () => {
    expect([...vault.notes.keys()].sort()).toEqual([
      'Home.md',
      'Onyx.md',
      'Projects/Onyx.md',
      'Projects/Roadmap.md',
    ])
    expect([...vault.files]).toEqual(['attachments/diagram.png'])
  })

  it('builds a sorted tree with folders first', () => {
    const tree = vault.tree()
    // Folders first, then case-insensitive alphabetical, as Obsidian sorts.
    expect(tree.children?.map((c) => c.name)).toEqual([
      'attachments',
      'Projects',
      'Home.md',
      'Onyx.md',
    ])
  })

  it('extracts titles, tags and word counts', () => {
    const home = vault.notes.get('Home.md')!
    expect(home.title).toBe('Home')
    expect(home.tags).toEqual(['index'])
    expect(vault.notes.get('Onyx.md')!.tags).toEqual(['tools/editor'])
  })
})

describe('link resolution', () => {
  it('resolves an exact relative path', () => {
    expect(vault.resolve('Projects/Roadmap')).toBe('Projects/Roadmap.md')
  })

  it('prefers a note in the linking note‘s own folder when names collide', () => {
    expect(vault.resolve('Onyx', 'Projects/Roadmap.md')).toBe('Projects/Onyx.md')
    expect(vault.resolve('Onyx', 'Home.md')).toBe('Onyx.md')
  })

  it('ignores a heading or block anchor', () => {
    expect(vault.resolve('Onyx#Some heading', 'Home.md')).toBe('Onyx.md')
  })

  it('falls back to an alias', async () => {
    await write('Aliased.md', '---\naliases: [Nickname]\n---\n\n# Aliased\n')
    await vault.load()
    expect(vault.resolve('Nickname')).toBe('Aliased.md')
  })

  it('returns null for a target that does not exist', () => {
    expect(vault.resolve('Nowhere')).toBeNull()
  })
})

describe('backlinks and tags', () => {
  it('records who links to a note', () => {
    // `Projects/Roadmap.md` says [[Onyx]], which resolves to its own folder's
    // copy — so the root note's only backlink is Home.
    expect(vault.backlinks('Onyx.md')).toEqual(['Home.md'])
    expect(vault.backlinks('Projects/Onyx.md')).toEqual(['Projects/Roadmap.md'])
  })

  it('leaves an unresolvable target as unresolved rather than a backlink', () => {
    expect(vault.notes.get('Onyx.md')!.unresolved).toContain('Nowhere')
  })

  it('indexes tags', () => {
    expect(vault.notesWithTag('project')).toEqual(['Projects/Roadmap.md'])
    expect(vault.tags().map((t) => t.tag).sort()).toEqual(['index', 'project', 'tools/editor'])
  })
})

describe('graph', () => {
  it('includes notes, tag nodes and phantom targets', () => {
    const g = vault.graph()
    const byId = new Map(g.nodes.map((n) => [n.id, n]))
    expect(byId.get('Home.md')?.kind).toBe('note')
    expect(byId.get('tag:project')?.kind).toBe('tag')
    expect(byId.get('unresolved:nowhere')?.kind).toBe('unresolved')
  })

  it('labels notes with their filename, as Obsidian does', () => {
    const g = vault.graph()
    expect(g.nodes.find((n) => n.id === 'Projects/Roadmap.md')?.title).toBe('Roadmap')
  })

  it('emits a parent edge for each level of a nested tag', () => {
    const g = vault.graph()
    const ids = g.nodes.map((n) => n.id)
    expect(ids).toContain('tag:tools/editor')
    expect(ids).toContain('tag:tools')
    const hierarchy = g.links.filter((l) => l.kind === 'tagParent')
    expect(hierarchy).toHaveLength(1)
    expect(g.nodes[hierarchy[0].source].id).toBe('tag:tools')
    expect(g.nodes[hierarchy[0].target].id).toBe('tag:tools/editor')
  })

  it('counts degree from the edges it emitted', () => {
    const g = vault.graph()
    const onyx = g.nodes.find((n) => n.id === 'Onyx.md')!
    expect(onyx.degree).toBeGreaterThan(0)
  })
})

describe('writing', () => {
  it('saves atomically and re-indexes', async () => {
    await vault.write('Home.md', '# Home\n\nNow links [[Projects/Roadmap]] only.\n')
    expect(vault.notes.get('Home.md')!.outgoing).toEqual(['Projects/Roadmap.md'])
    // Home was the only thing pointing at the root Onyx note.
    expect(vault.backlinks('Onyx.md')).toEqual([])
    // No temp file left behind.
    const entries = await fs.readdir(root)
    expect(entries.some((e) => e.includes('onyx-tmp'))).toBe(false)
  })

  it('keeps the content cache in step with writes', async () => {
    await vault.write('Onyx.md', '# Onyx\n\nrewritten body\n')
    expect(await vault.cachedContent('Onyx.md')).toContain('rewritten body')
  })

  it('drops a deleted note from the cache and index', async () => {
    await vault.remove('Onyx.md', async (abs) => fs.rm(abs))
    expect(vault.notes.has('Onyx.md')).toBe(false)
    expect(vault.backlinks('Onyx.md')).toEqual([])
  })
})

describe('rename', () => {
  it('moves the file and rewrites links that pointed at it', async () => {
    const touched = await vault.rename('Onyx.md', 'Onyx Desktop.md')
    expect(touched).toContain('Home.md')
    expect(await vault.read('Home.md')).toContain('[[Onyx Desktop]]')
    expect(vault.notes.has('Onyx Desktop.md')).toBe(true)
    expect(vault.notes.has('Onyx.md')).toBe(false)
  })

  it('leaves an alias-style link display text alone', async () => {
    await write('Alias.md', 'link [[Onyx|the app]] here\n')
    await vault.load()
    await vault.rename('Onyx.md', 'Renamed.md')
    expect(await vault.read('Alias.md')).toBe('link [[Renamed|the app]] here\n')
  })

  it('renames a folder and remaps the notes inside it', async () => {
    await vault.rename('Projects', 'Work')
    expect(vault.notes.has('Work/Roadmap.md')).toBe(true)
    expect(vault.notes.has('Projects/Roadmap.md')).toBe(false)
  })
})

describe('helpers', () => {
  it('rewrites only the targets the mapper claims', () => {
    const out = rewriteLinks('[[a]] [[b]] ![[a|alias]]', (t) => (t === 'a' ? 'z' : null))
    expect(out).toBe('[[z]] [[b]] ![[z|alias]]')
  })

  it('parses a note without touching the disk', () => {
    const meta = parseNote('N.md', '# Title\n\n[[Other]] #tag\n')
    expect(meta.title).toBe('Title')
    expect(meta.targets).toEqual(['Other'])
    expect(meta.tags).toEqual(['tag'])
  })

  it('does not call a normal temp directory a network path', () => {
    expect(isNetworkPath(root)).toBe(false)
  })
})
