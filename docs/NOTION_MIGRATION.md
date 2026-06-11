# Notion → Onyx migration spec

Conventions for migrating the user's Notion workspace into the Onyx vault.
Written 2026-06-11; used by the migration agents. Keep this in sync if rules change.

## Destination & safety

- Everything lands under **`~/OnyxVault/Notion/<Domain>/…`**. Domains:
  `Finance/`, `Degree Planning/`, `Courses/`, `Entertainment/`, `Work/`.
- **Create files only.** Never modify or delete anything outside `~/OnyxVault/Notion/`,
  and never overwrite a file you didn't create in this run (if a name collides,
  append ` 2`).
- Skip Notion's starter/sample content ("Getting started with Projects & Tasks",
  sample projects, the sample Tasks DB) and database **page templates**
  (rows literally named "… Template").

## Structure mapping

| Notion | Onyx |
|---|---|
| Page (leaf) | `<Title>.md` |
| Page with sub-pages | folder `<Title>/` + the page's own content as `<Title>/<Title>.md` |
| Database | folder `<DB name>/` + `<DB name>/_schema.md` describing the schema/views |
| Database row | one `.md` note in the DB folder, properties as YAML frontmatter |
| Sub-page mention / link | `[[wikilink]]` to the migrated note |

## Frontmatter (every migrated note)

```yaml
---
source: notion
notion-url: https://app.notion.com/p/<id>
created: <createdTime ISO date if known>
# …then, for DB rows, one key per non-empty property, e.g.:
Type: Needs
Amount: 12.5
---
```

- Property names keep their Notion names (spaces fine). Skip empty properties.
- Multi-select / multi-value → inline array: `Tags: [a, b]`.
- Relation properties → wikilinks in the body (a `Related:` section), not frontmatter,
  unless the target name is short and unambiguous: then `Related: "[[Name]]"`.
- Skip auto-generated relation props that are empty or named like
  `Related to Summary (Property) 1`.

## Content conversion (Notion-flavored → plain markdown)

- `<callout icon="X">…</callout>` → blockquote: `> **X** …` (or `> [!note] …`).
- `<details><summary>S</summary>…` (toggles) → `**S**` line + indented content,
  flattened (no HTML in output).
- `<table>` HTML → a markdown pipe table (drop colgroup/colors; `<br>` → `, `).
- `<mention-page url=…>Text</mention-page>` → `[[Text]]`.
- Inline `<database …>Name</database>` refs → `[[Name/_schema|Name]]` if migrated,
  else plain bold text.
- `<column(s)>` layouts → flatten sequentially (columns top-to-bottom).
- Strip: `<empty-block/>`, `<synced_block>`, buttons/`<unknown …>`, colored
  `<span>` wrappers (keep inner text), page icons.
- `$\`…\`$` inline math → `$…$`; keep code blocks/fences as-is.
- Keep headings/lists/bold/links as plain markdown.

## Enumeration recipes (Notion MCP)

- Load tools: ToolSearch `select:mcp__notion__notion-fetch,mcp__notion__notion-search`.
- Page content: `notion-fetch {id: <page id/url>}` → Notion-flavored markdown.
- DB schema: fetch the database id; data sources appear as `collection://…`.
- DB rows: `notion-search {query: <broad term>, data_source_url: "collection://…", page_size: 25}`,
  then `notion-fetch` each row page for properties + body. Try 2–3 different broad
  queries if you suspect rows were missed (search is semantic, not exhaustive).
- Sub-pages of a page: `notion-search {query: …, page_url: <parent page id>}` plus
  the `<page url=…>` / `<mention-page>` links inside the parent's fetched content.

## Report format (what each agent returns)

A short summary: files written (count + tree sketch), pages/rows skipped and why,
anything that failed to fetch or didn't fit the conventions.

## Discovered inventory (IDs — saves rediscovery on relaunch)

**Finance** → `Notion/Finance/`
- Page "Income and Expenses": `17085dd7-eb09-4755-9ae4-325aef148df5`
- Expenses DB: `b57c61c2-d452-4d52-92fb-aea3cadc0133` / `collection://687330aa-56c7-4519-8c09-97fa61e3878d`
  (props: Item title, Type select Needs/Wants/Savings, Amount dollar, Notes; ~25 rows incl.
  Claude, Gasoline, Prime, Spotify, proton, Overleaf, Apple, medium, Latitude, Obsidian,
  AVG Antivirus + 2023 template-starter rows; skip "Needs/Wants/Savings Template")
- Monthly Income DB: `3f174319-fba8-48a1-8a14-136d26643ba0` / `collection://346bc2e2-45ee-4851-ad65-9f1797f81b97` (rows: Big W, Centrelink; skip "Income Template")
- Summary DB: `70a133de-ab81-4842-a3f9-2453b1654b6e` / `collection://e0dc054c-9723-477a-b412-93535ecea0d0` (row: Monthly Statistics; formulas → snapshot)

**Degree Planning** → `Notion/Degree Planning/`
- "ANU Bachelor of Advanced Computing (Honours) (196 units)" page: `ffe80021-8de8-467c-b6f8-e5513856f435`
  (semester HTML tables, HELP balance, program rules; inline Grades DB
  `d0f761ab-9bdf-4c1d-b2ee-69302fcb5ace` / `collection://42b59889-bb06-4456-b04c-ff0d9ab1775c`
  and GPA DB `19ade7cc-2b77-47bf-9b91-7dd1e47121d5` / `collection://d4f09710-ac5d-4c16-9f9d-75d762c09287`)
- "Bachelor of Science (144 units)" page: `13bd68fe-7472-8051-8eae-f124d9539b47`
- Study-plan DBs: Master of Computing `299d68fe-7472-80ff-aacb-d5cf047a40f8`;
  MSc Quantum Technology `299d68fe-7472-8061-8b07-d2de18df9f73`;
  Theoretical Physics MSc `299d68fe-7472-805f-8ff1-e225be77e1d1`;
  ANU Engineering `299d68fe-7472-80ab-88a3-e3fde7307d8e`

**Courses** (bulk) → `Notion/Courses/`
- Root "Data Science": `3607f61a-932e-49b6-8c0d-504b8472edff`. Known descendants:
  Machine Learning `23f21eae-4f67-4dc6-aea4-84bff17c80ca`, Data Wrangling `93f64d95-07f7-4006-8455-e85aee151952`,
  Data Mgmt & Relational DB `b91e5a10-09ac-4be8-81c9-cbde5b2423c3` + dup `a21b6b9c-4b60-4be4-8ede-f59472a6ff7b`,
  topic notes (9.0 `a9f15e7d…`, 9.1 `6c7af7c8…`, 1.0 `b63690d5…`, Evaluation `7a41b4cc…`,
  Naive Bayes `9ffa4b2b…`, model quality `ed6f96a9…`, Data Mining Intro `248403c8…`),
  Labs 1,3,4,5,7 (`2fb9e005…`, `d9a94f01…`, `cd42ce37…`, `9cec7388…`, `fa0a6cd7…`; find 2+6 by search),
  Quiz 1 `153f2aa5…`, DW Assignment 1 `4c38d5aa…`, nested "Databases" DB `f69ca4a5-cefc-4dcf-ad34-e7691d6a715d`
  (ancestors: cf9c1039…/266317a9… under Data Science — note-container pattern).
- Security/networks set (find parent via ancestor-path of Security Principles `978c08f4-166e-4eee-b109-c55a747e1708`):
  Internet Security `2d63aa71…`, Reference Monitors `14a00dd8…`, Security Mgmt `abe291e5…`,
  Classical ciphers `164a61e6…`, Networks `266f3754…`
- "Physics of Quantum Information": `299d68fe-7472-8067-bec8-c980e2a1fb39`

**Entertainment + Work** → `Notion/Entertainment/`, `Notion/Work/`
- "Entertainment" page `2178565a-7365-4c61-98d4-64c1a4a6a8f3` → DB `26ce1167-d53e-469c-89a0-ada44006639c` / `collection://c75dff93-6e07-48c6-91b4-658d2d60c1aa`
- "Anime Watchlist / Tracker" `216f36f1-dc9f-4a9e-9d34-c2eaf9162678` with inline DBs:
  Animes `fd1194fc…`/`collection://ab22c731-8e30-4b1a-b0f3-e8ebe325086b`,
  Spring `91cc5a2e…`/`collection://f75ef812-7641-46bb-aa2a-412fd4cce0f5`,
  Movies `734e1418…`/`collection://b5512bae-6e08-40dc-8135-b812c727f289`,
  Mangas/Manwhas `b2be75e9…`/`collection://5302f78b-c81c-4af3-adef-3b7247948f35`,
  K-dramas `ebef78ed…`/`collection://283ae9e3-120d-4e17-a3e1-e75c6b509918`
- "Work" page `3781b938-9b9d-40a3-b4eb-94db51ef90c5`; "interview questions" `769e25f6-db5c-44ba-906b-501eeb2337e7`

**Skip:** "Getting started with Projects & Tasks" `d1645b35…`, sample projects
(`d03d5602…`, `e4d79930…`, `f05653e6…`, `42911416…`), Projects DB `7a2eea17…`,
Tasks DB `c7f8a3ca…`, "Links to databases" `cc8d9bf2…` (verify it's trivial first).
