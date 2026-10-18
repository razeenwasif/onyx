import { promises as fs } from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import type { ScribePage } from '../shared/types'
import { graphWithScribe, scribeBacklinks } from './scribe-links'
import { Vault } from './vault'

const PAGE = '26fe650fab4f4f798f717eeed5190a7b'
const OTHER = '0123456789abcdef0123456789abcdef'

let root: string
let vault: Vault

const page = (id: string, title: string, links: string[]): ScribePage => ({
  id,
  title,
  path: `/lib/Uni/Logic/${title}.json`,
  notebook: 'Uni',
  section: 'Logic',
  modified: 0,
  links,
})

beforeEach(async () => {
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'onyx-scribe-links-'))
  await fs.writeFile(
    path.join(root, 'Week 3.md'),
    `# Week 3\n\nWorked example: [[scribe:${PAGE}#10,20,300,140|Tutorials]] and [[scribe:gone|Lost]].\n`,
  )
  await fs.writeFile(path.join(root, 'Natural deduction.md'), '# Natural deduction\n')
  vault = new Vault(root)
  await vault.load()
})

afterEach(async () => {
  await vault.close()
  await fs.rm(root, { recursive: true, force: true })
})

describe('Scribe pages in the graph and backlinks', () => {
  it('keeps Scribe links out of unresolved notes', () => {
    expect(vault.notes.get('Week 3.md')?.unresolved).toEqual([])
    expect(vault.graph().nodes.some((n) => n.kind === 'unresolved')).toBe(false)
  })

  it('adds linked pages as nodes, joined both ways', () => {
    const pages = [
      page(PAGE, 'Tutorials', ['Natural deduction', `scribe:${OTHER}`, 'Nowhere']),
      page(OTHER, 'Truth tables', []),
      page('ffffffffffffffffffffffffffffffff', 'Unlinked', []),
    ]
    const g = graphWithScribe(vault.graph(), vault.notes, (t, f) => vault.resolve(t, f), pages)
    const scribe = g.nodes.filter((n) => n.kind === 'scribe')
    expect(scribe.map((n) => n.title).sort()).toEqual(['Truth tables', 'Tutorials'])
    expect(scribe.find((n) => n.title === 'Tutorials')).toMatchObject({
      id: `scribe:${PAGE}`,
      folder: 'Scribe/Uni/Logic',
      degree: 3,
    })
    const named = g.links.map((l) => `${g.nodes[l.source].title} → ${g.nodes[l.target].title}`).sort()
    expect(named).toEqual(['Tutorials → Natural deduction', 'Tutorials → Truth tables', 'Week 3 → Tutorials'])
  })

  it('lists pages that link to a note among its backlinks', () => {
    const pages = [page(PAGE, 'Tutorials', ['natural deduction']), page(OTHER, 'Other', ['Week 3'])]
    const refs = scribeBacklinks('Natural deduction.md', (t, f) => vault.resolve(t, f), pages)
    expect(refs).toEqual([
      {
        path: '/lib/Uni/Logic/Tutorials.json',
        title: 'Tutorials',
        scribe: { id: PAGE, notebook: 'Uni', section: 'Logic' },
      },
    ])
  })

  it('leaves the graph alone without Scribe', () => {
    const g = vault.graph()
    expect(graphWithScribe(g, vault.notes, (t) => vault.resolve(t), [])).toBe(g)
  })
})
