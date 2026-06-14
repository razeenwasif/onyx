//! Retrieval-augmented "ask my vault": chunk notes, embed the chunks (cached to
//! `.onyx/rag-index.json`), and cosine-rank them against a query embedding.
//!
//! Everything here is pure (chunking, cosine, ranking, cache (de)serialization);
//! the embedding calls live in `integrations::ollama` behind the `ai` feature.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// A piece of a note to embed/retrieve.
#[derive(Debug, Clone, PartialEq)]
pub struct Chunk {
    pub text: String,
    /// 0-based line where the chunk starts (for display).
    pub line: usize,
}

/// Split a note into chunks of roughly `target` chars, merging paragraphs and
/// skipping YAML frontmatter. Tiny chunks are dropped.
pub fn chunk_note(content: &str, target: usize) -> Vec<Chunk> {
    let target = target.max(200);
    let lines: Vec<&str> = content.lines().collect();

    // Skip a leading `--- … ---` frontmatter block.
    let mut i = 0;
    if lines.first().map(|l| l.trim() == "---").unwrap_or(false) {
        i = 1;
        while i < lines.len() && lines[i].trim() != "---" {
            i += 1;
        }
        if i < lines.len() {
            i += 1; // closing ---
        }
    }

    let mut chunks = Vec::new();
    let mut cur = String::new();
    let mut cur_line = i;
    let mut started = false;
    while i < lines.len() {
        let line = lines[i];
        if line.trim().is_empty() {
            if cur.len() >= target {
                chunks.push(Chunk { text: cur.trim().to_string(), line: cur_line });
                cur.clear();
                started = false;
            } else if started {
                cur.push('\n');
            }
        } else {
            if !started {
                cur_line = i;
                started = true;
            } else {
                cur.push('\n');
            }
            cur.push_str(line);
            if cur.len() >= target {
                chunks.push(Chunk { text: cur.trim().to_string(), line: cur_line });
                cur.clear();
                started = false;
            }
        }
        i += 1;
    }
    if cur.trim().len() >= 20 {
        chunks.push(Chunk { text: cur.trim().to_string(), line: cur_line });
    }
    // Drop chunks with too little actual content to be worth a vector.
    chunks.retain(|c| c.text.chars().filter(|ch| !ch.is_whitespace()).count() >= 20);
    chunks
}

/// Cosine similarity of two equal-length vectors (0 on mismatch/empty).
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

// --- On-disk cache ----------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddedChunk {
    pub text: String,
    pub line: usize,
    pub vec: Vec<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoteEmbeds {
    /// File mtime (unix secs) the embeddings were computed for.
    pub mtime: u64,
    pub chunks: Vec<EmbeddedChunk>,
}

/// The whole vault embedding index (keyed by absolute path string).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RagIndex {
    /// Embedding model these vectors came from (invalidate on change).
    pub model: String,
    pub notes: HashMap<String, NoteEmbeds>,
}

pub fn cache_path(root: &Path) -> PathBuf {
    root.join(".onyx").join("rag-index.json")
}

pub fn load_index(root: &Path) -> RagIndex {
    std::fs::read_to_string(cache_path(root))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save_index(root: &Path, index: &RagIndex) -> std::io::Result<()> {
    let path = cache_path(root);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string(index).map_err(std::io::Error::other)?;
    std::fs::write(path, json)
}

/// A retrieved chunk with its source and score.
#[derive(Debug, Clone)]
pub struct Retrieved {
    pub path: String,
    pub text: String,
    pub line: usize,
    pub score: f32,
}

/// Rank every cached chunk against `query` and return the top `k`.
pub fn top_k(index: &RagIndex, query: &[f32], k: usize) -> Vec<Retrieved> {
    let mut scored: Vec<Retrieved> = Vec::new();
    for (path, ne) in &index.notes {
        for ch in &ne.chunks {
            scored.push(Retrieved {
                path: path.clone(),
                text: ch.text.clone(),
                line: ch.line,
                score: cosine(query, &ch.vec),
            });
        }
    }
    scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(k);
    scored
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunks_skip_frontmatter_and_merge_paragraphs() {
        let note = "---\ntitle: X\ntags: [a]\n---\n\nFirst paragraph about quantum entanglement and qubits.\n\nSecond paragraph here.\n";
        let chunks = chunk_note(note, 1000);
        assert_eq!(chunks.len(), 1); // merged under target, frontmatter dropped
        assert!(chunks[0].text.contains("First paragraph"));
        assert!(chunks[0].text.contains("Second paragraph"));
        assert!(!chunks[0].text.contains("title:"));
    }

    #[test]
    fn long_note_splits_into_multiple() {
        // `chunk_note` floors the target at 200 chars, so use paragraphs that
        // each exceed it to force multiple chunks.
        let para = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod \
                    tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam \
                    quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo.";
        let note = format!("{para}\n\n{para}\n\n{para}");
        let chunks = chunk_note(&note, 200);
        assert!(chunks.len() >= 2, "expected multiple chunks, got {}", chunks.len());
    }

    #[test]
    fn cosine_basic() {
        assert!((cosine(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 1e-6);
        assert!(cosine(&[1.0, 0.0], &[0.0, 1.0]).abs() < 1e-6);
        assert_eq!(cosine(&[1.0], &[1.0, 2.0]), 0.0); // length mismatch
    }

    #[test]
    fn top_k_orders_by_similarity() {
        let mut notes = HashMap::new();
        notes.insert(
            "a.md".to_string(),
            NoteEmbeds {
                mtime: 0,
                chunks: vec![
                    EmbeddedChunk { text: "near".into(), line: 0, vec: vec![1.0, 0.0] },
                    EmbeddedChunk { text: "far".into(), line: 1, vec: vec![0.0, 1.0] },
                ],
            },
        );
        let index = RagIndex { model: "m".into(), notes };
        let hits = top_k(&index, &[1.0, 0.0], 2);
        assert_eq!(hits[0].text, "near");
        assert!(hits[0].score > hits[1].score);
    }
}
