import { describe, expect, it } from 'vitest'

import {
  extractAllTags,
  extractFrontmatterAliases,
  extractFrontmatterProperties,
  extractFrontmatterTags,
  extractHeadings,
  extractInlineTags,
  extractLinks,
  extractMdLinks,
  extractTasks,
  frontmatterLength,
  hasUriScheme,
  headingSlug,
  linkAnchor,
  noteName,
  normalizeMdDest,
  percentDecode,
  stripFrontmatter,
  wordCount,
} from './parse'

const BOM = '\uFEFF'

describe('wikilinks', () => {
  it('reads targets, aliases and offsets', () => {
    const links = extractLinks('see [[Target]] and [[Other|Alias]] here')
    expect(links.map((l) => [l.target, l.alias])).toEqual([
      ['Target', null],
      ['Other', 'Alias'],
    ])
    expect('see [[Target]]'.slice(links[0].start, links[0].end)).toBe('[[Target]]')
  })

  it('marks embeds', () => {
    expect(extractLinks('![[Picture.png]]')[0].embed).toBe(true)
    expect(extractLinks('[[Picture.png]]')[0].embed).toBe(false)
  })

  it('skips links inside code spans and fences', () => {
    expect(extractLinks('`[[NotALink]]`')).toEqual([])
    expect(extractLinks('```\n[[NotALink]]\n```')).toEqual([])
    // An unterminated fence swallows the rest of the document.
    expect(extractLinks('```\n[[NotALink]]')).toEqual([])
  })

  it('splits the note name from its anchor', () => {
    expect(noteName('Note#Heading')).toBe('Note')
    expect(noteName('Note^block')).toBe('Note')
    expect(noteName('Note')).toBe('Note')
    expect(linkAnchor('Note#Heading')).toEqual({ kind: 'heading', value: 'Heading' })
    expect(linkAnchor('Note#^abc')).toEqual({ kind: 'block', value: 'abc' })
    expect(linkAnchor('Note')).toBeNull()
  })
})

describe('markdown links', () => {
  it('keeps local note links and drops everything else', () => {
    expect(extractMdLinks('[a](Note.md) [b](https://x.com) [c](#anchor) [d](img.png)')).toEqual([
      'Note',
    ])
  })

  it('percent-decodes and strips anchors', () => {
    expect(normalizeMdDest('My%20Note.md#Heading')).toBe('My Note')
    expect(percentDecode('a%20b')).toBe('a b')
  })

  it('treats a drive letter as a path, not a scheme', () => {
    expect(hasUriScheme('https://x')).toBe(true)
    expect(hasUriScheme('mailto:a@b')).toBe(true)
    expect(hasUriScheme('C:/notes')).toBe(false)
  })
})

describe('tags', () => {
  it('reads inline tags but not code or word-internal hashes', () => {
    expect(extractInlineTags('a #one and #nested/two')).toEqual(['one', 'nested/two'])
    expect(extractInlineTags('`#nope`')).toEqual([])
    expect(extractInlineTags('id#anchor')).toEqual([])
  })

  it('reads frontmatter tags inline and as a block list', () => {
    expect(extractFrontmatterTags('---\ntags: [a, b]\n---\n')).toEqual(['a', 'b'])
    expect(extractFrontmatterTags('---\ntags:\n  - a\n  - b/c\n---\n')).toEqual(['a', 'b/c'])
    expect(extractFrontmatterTags('---\ntag: solo\n---\n')).toEqual(['solo'])
  })

  it('merges frontmatter and body tags, deduped and sorted', () => {
    expect(extractAllTags('---\ntags: [b]\n---\n\n#a and #b\n')).toEqual(['a', 'b'])
  })
})

describe('frontmatter', () => {
  it('parses properties in document order, scalars uncomma-split', () => {
    const src = '---\ntitle: Hello, World\nlist: [x, y]\nblock:\n  - p\n  - q\n---\nbody\n'
    expect(extractFrontmatterProperties(src)).toEqual([
      ['title', ['Hello, World']],
      ['list', ['x', 'y']],
      ['block', ['p', 'q']],
    ])
  })

  it('reads aliases', () => {
    expect(extractFrontmatterAliases('---\naliases: [One, Two]\n---\n')).toEqual(['One', 'Two'])
  })

  it('ignores an unterminated block', () => {
    expect(extractFrontmatterProperties('---\na: 1\nno closing fence\n')).toEqual([])
    expect(frontmatterLength('---\na: 1\n')).toBe(0)
  })

  it('measures the block so the body starts after the closing fence', () => {
    const src = '---\na: 1\n---\n\nbody\n'
    expect(src.slice(frontmatterLength(src))).toBe('\nbody\n')
    expect(stripFrontmatter(src)).toBe('\nbody\n')
  })

  // Regression: the BOM was stripped before matching but the offset was
  // returned against the stripped string, so every BOM-prefixed note (Notion
  // writes them) was one character short — landing on the closing `---` and
  // making Live Preview show raw YAML instead of the properties table.
  it('returns an offset into the original string when there is a BOM', () => {
    const src = `${BOM}---\ntags:\n  - ML\n---\n\n#ML\n`
    expect(src.slice(frontmatterLength(src))).toBe('\n#ML\n')
    expect(extractFrontmatterTags(src)).toEqual(['ML'])
  })

  it('handles CRLF', () => {
    const src = '---\r\na: 1\r\n---\r\nbody\r\n'
    expect(src.slice(frontmatterLength(src))).toBe('body\r\n')
  })
})

describe('document structure', () => {
  it('lists headings outside fenced code', () => {
    expect(extractHeadings('# One\n```\n# Fake\n```\n## Two\n')).toEqual([
      { level: 1, text: 'One', line: 0 },
      { level: 2, text: 'Two', line: 4 },
    ])
  })

  it('lists task checkboxes with their state', () => {
    expect(extractTasks('- [ ] a\n  - [x] b\ntext\n')).toEqual([
      { line: 0, indent: 0, done: false, text: 'a' },
      { line: 1, indent: 2, done: true, text: 'b' },
    ])
  })

  it('counts words in the body only', () => {
    expect(wordCount('---\ntags: [a]\n---\n\none two three\n')).toBe(3)
  })

  it('slugs headings for link resolution', () => {
    expect(headingSlug('  Some   Heading ')).toBe('some heading')
  })
})
