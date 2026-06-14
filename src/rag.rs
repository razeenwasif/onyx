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

/// Cosine similarity of two equal-length f32 vectors (0 on mismatch/empty).
/// Retained as a reference/helper; ranking uses the int8 `cosine_i8`.
#[allow(dead_code)]
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

// --- Vector quantization ----------------------------------------------------
//
// Embeddings are stored int8-quantized and base64-packed to keep the cache small
// (~4× smaller than full f32 JSON). Cosine similarity is scale-invariant, so the
// per-vector scale cancels and ranking on the quantized ints matches the floats.

/// Quantize a float vector to int8 (per-vector max-abs scale).
pub fn quantize(v: &[f32]) -> Vec<i8> {
    let max = v.iter().fold(0.0f32, |m, &x| m.max(x.abs()));
    if max == 0.0 {
        return vec![0; v.len()];
    }
    let scale = max / 127.0;
    v.iter()
        .map(|&x| (x / scale).round().clamp(-127.0, 127.0) as i8)
        .collect()
}

/// Pack a float vector into a compact base64 string of its int8 quantization.
pub fn pack(v: &[f32]) -> String {
    let q = quantize(v);
    let bytes: Vec<u8> = q.iter().map(|&b| b as u8).collect();
    b64_encode(&bytes)
}

/// Unpack a base64-packed quantized vector back to int8.
pub fn unpack(s: &str) -> Vec<i8> {
    b64_decode(s).into_iter().map(|b| b as i8).collect()
}

/// Cosine similarity over int8 vectors (computed in f32). Equal-length only.
pub fn cosine_i8(a: &[i8], b: &[i8]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for i in 0..a.len() {
        let (x, y) = (a[i] as f32, b[i] as f32);
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32);
        out.push(B64[((n >> 18) & 63) as usize] as char);
        out.push(B64[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { B64[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn b64_decode(s: &str) -> Vec<u8> {
    let val = |c: u8| -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let bytes: Vec<u8> = s.bytes().filter(|&c| c != b'=' && !c.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let mut n = 0u32;
        let mut count = 0;
        for (i, &c) in chunk.iter().enumerate() {
            if let Some(v) = val(c) {
                n |= v << (18 - 6 * i);
                count += 1;
            }
        }
        if count >= 2 {
            out.push((n >> 16) as u8);
        }
        if count >= 3 {
            out.push((n >> 8) as u8);
        }
        if count >= 4 {
            out.push(n as u8);
        }
    }
    out
}

// --- On-disk cache ----------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddedChunk {
    pub text: String,
    pub line: usize,
    /// int8-quantized embedding, base64-packed (see `pack`/`unpack`).
    pub q: String,
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

/// Rank every cached chunk against `query` and return the top `k`. The query is
/// quantized the same way as the stored chunks; cosine is scale-invariant.
pub fn top_k(index: &RagIndex, query: &[f32], k: usize) -> Vec<Retrieved> {
    let qq = quantize(query);
    let mut scored: Vec<Retrieved> = Vec::new();
    for (path, ne) in &index.notes {
        for ch in &ne.chunks {
            scored.push(Retrieved {
                path: path.clone(),
                text: ch.text.clone(),
                line: ch.line,
                score: cosine_i8(&qq, &unpack(&ch.q)),
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
                    EmbeddedChunk { text: "near".into(), line: 0, q: pack(&[1.0, 0.0]) },
                    EmbeddedChunk { text: "far".into(), line: 1, q: pack(&[0.0, 1.0]) },
                ],
            },
        );
        let index = RagIndex { model: "m".into(), notes };
        let hits = top_k(&index, &[1.0, 0.0], 2);
        assert_eq!(hits[0].text, "near");
        assert!(hits[0].score > hits[1].score);
    }

    #[test]
    fn quantize_pack_roundtrip_preserves_cosine() {
        let a = vec![0.10, -0.20, 0.30, 0.05, -0.40];
        let b = vec![0.12, -0.18, 0.28, 0.06, -0.39];
        // base64 pack → unpack is lossless for the int8 values.
        assert_eq!(unpack(&pack(&a)), quantize(&a));
        // Quantized cosine tracks the float cosine closely.
        let cf = cosine(&a, &b);
        let cq = cosine_i8(&quantize(&a), &quantize(&b));
        assert!((cf - cq).abs() < 0.02, "float {cf} vs quantized {cq}");
        // base64 alphabet round-trips arbitrary bytes.
        assert_eq!(super::b64_decode(&super::b64_encode(&[0u8, 1, 200, 255, 42])), vec![0u8, 1, 200, 255, 42]);
    }
}
