/**
 * Canonical graph defaults, shared by the persisted settings (main) and the
 * "Restore default settings" button (renderer) so the two can't drift.
 *
 * Slider ranges mirror Obsidian's: center force 0–1, repel force 0–20,
 * link force 0–1, link distance 30–500, node size and link thickness 0.1–5,
 * text fade threshold 0–3, local-graph depth 1–5.
 */

import type { GraphSettings, LocalGraphSettings } from './types.js'

export const DEFAULT_GRAPH: GraphSettings = {
  searchQuery: '',
  showTags: false,
  showAttachments: false,
  existingOnly: false,
  showOrphans: true,
  groups: [],
  colorByTag: true,
  arrows: false,
  textFadeThreshold: 1.1,
  nodeSize: 1,
  linkThickness: 1,
  animate: false,
  centerForce: 0.3,
  repelForce: 10,
  linkForce: 1,
  linkDistance: 250,
}

export const DEFAULT_LOCAL_GRAPH: LocalGraphSettings = {
  ...DEFAULT_GRAPH,
  textFadeThreshold: 0.4,
  centerForce: 0.45,
  linkDistance: 180,
  depth: 1,
  incoming: true,
  outgoing: true,
  neighborLinks: true,
}
