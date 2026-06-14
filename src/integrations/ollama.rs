//! Local LLM assistant via the Ollama HTTP API (loopback, no auth).
//!
//! Request/response shaping is pure (serde) and unit-tested; the streaming HTTP
//! calls are behind the `ai` feature. Streaming matters: a local model's first
//! request loads weights (seconds) and then emits tokens incrementally, so we
//! surface them as they arrive rather than blocking on the full response.

use serde::{Deserialize, Serialize};

use super::IntResult;

/// One chat turn.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

impl ChatMessage {
    pub fn user(content: impl Into<String>) -> Self {
        Self { role: "user".into(), content: content.into() }
    }
    pub fn assistant(content: impl Into<String>) -> Self {
        Self { role: "assistant".into(), content: content.into() }
    }
    pub fn system(content: impl Into<String>) -> Self {
        Self { role: "system".into(), content: content.into() }
    }
}

/// One streamed delta from `/api/chat`. These Gemma builds emit a separate
/// `thinking` trace before the visible `content`; both arrive incrementally.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChatChunk {
    pub content: String,
    pub thinking: String,
    pub done: bool,
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: &'a [ChatMessage],
    stream: bool,
}

/// JSON body for an `/api/chat` request.
pub fn chat_body(model: &str, messages: &[ChatMessage], stream: bool) -> String {
    serde_json::to_string(&ChatRequest { model, messages, stream }).unwrap_or_default()
}

#[derive(Deserialize)]
struct ChunkResponse {
    #[serde(default)]
    message: Option<ChunkMessage>,
    #[serde(default)]
    done: bool,
}
#[derive(Deserialize, Default)]
struct ChunkMessage {
    #[serde(default)]
    content: String,
    #[serde(default)]
    thinking: String,
}

/// Parse one NDJSON line from a streaming `/api/chat` response.
pub fn parse_chat_chunk(line: &str) -> Option<ChatChunk> {
    let r: ChunkResponse = serde_json::from_str(line).ok()?;
    let m = r.message.unwrap_or_default();
    Some(ChatChunk { content: m.content, thinking: m.thinking, done: r.done })
}

#[derive(Deserialize)]
struct TagsResponse {
    #[serde(default)]
    models: Vec<TagModel>,
}
#[derive(Deserialize)]
struct TagModel {
    #[serde(default)]
    name: String,
}

/// Parse the model list from `/api/tags`.
pub fn parse_models(json: &str) -> Vec<String> {
    serde_json::from_str::<TagsResponse>(json)
        .map(|r| r.models.into_iter().map(|m| m.name).filter(|n| !n.is_empty()).collect())
        .unwrap_or_default()
}

// -----------------------------------------------------------------------------
// Network (ai feature)
// -----------------------------------------------------------------------------

/// Stream a chat completion, invoking `on_chunk` for each delta as it arrives.
/// Stops early if `cancel` is set (the user closed/superseded the request).
#[cfg(feature = "ai")]
pub fn chat_stream(
    host: &str,
    model: &str,
    messages: &[ChatMessage],
    cancel: &std::sync::atomic::AtomicBool,
    mut on_chunk: impl FnMut(ChatChunk),
) -> IntResult<()> {
    use std::io::BufRead;
    use std::sync::atomic::Ordering;

    let url = format!("{}/api/chat", host.trim_end_matches('/'));
    let body = chat_body(model, messages, true);
    let resp = reqwest::blocking::Client::new()
        .post(&url)
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .map_err(|e| format!("can't reach Ollama at {host} — is it running? ({e})"))?;
    if !resp.status().is_success() {
        return Err(format!("Ollama returned {} from {url}", resp.status()));
    }
    let reader = std::io::BufReader::new(resp);
    for line in reader.lines() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        if let Some(chunk) = parse_chat_chunk(&line) {
            let done = chunk.done;
            on_chunk(chunk);
            if done {
                break;
            }
        }
    }
    Ok(())
}

/// List installed Ollama models (`/api/tags`).
#[cfg(feature = "ai")]
pub fn list_models(host: &str) -> IntResult<Vec<String>> {
    let url = format!("{}/api/tags", host.trim_end_matches('/'));
    let resp = reqwest::blocking::Client::new()
        .get(&url)
        .send()
        .map_err(|e| format!("can't reach Ollama at {host} — is it running? ({e})"))?;
    if !resp.status().is_success() {
        return Err(format!("Ollama returned {}", resp.status()));
    }
    let text = resp.text().map_err(|e| e.to_string())?;
    Ok(parse_models(&text))
}

#[cfg(not(feature = "ai"))]
pub fn chat_stream(
    _: &str,
    _: &str,
    _: &[ChatMessage],
    _: &std::sync::atomic::AtomicBool,
    _: impl FnMut(ChatChunk),
) -> IntResult<()> {
    Err("AI features not built — reinstall with `cargo install --path . --features ai` (or `full`)".into())
}

#[cfg(not(feature = "ai"))]
pub fn list_models(_: &str) -> IntResult<Vec<String>> {
    Err("AI features not built — reinstall with `cargo install --path . --features ai` (or `full`)".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_chat_body() {
        let msgs = vec![ChatMessage::system("be terse"), ChatMessage::user("hi")];
        let body = chat_body("gemma4:e4b-it-qat", &msgs, true);
        assert!(body.contains("\"model\":\"gemma4:e4b-it-qat\""));
        assert!(body.contains("\"stream\":true"));
        assert!(body.contains("\"role\":\"system\"") && body.contains("\"role\":\"user\""));
        assert!(body.contains("\"content\":\"hi\""));
    }

    #[test]
    fn parses_chat_chunk_content_and_thinking() {
        let c = parse_chat_chunk(
            r#"{"message":{"role":"assistant","content":"Red","thinking":""},"done":false}"#,
        )
        .unwrap();
        assert_eq!(c.content, "Red");
        assert!(c.thinking.is_empty() && !c.done);

        let t = parse_chat_chunk(
            r#"{"message":{"role":"assistant","content":"","thinking":"The user"},"done":false}"#,
        )
        .unwrap();
        assert_eq!(t.thinking, "The user");

        let d = parse_chat_chunk(r#"{"message":{"content":""},"done":true}"#).unwrap();
        assert!(d.done);

        assert!(parse_chat_chunk("not json").is_none());
    }

    #[test]
    fn parses_model_tags() {
        let json = r#"{"models":[{"name":"gemma4:e4b-it-qat"},{"name":"gemma4:e2b-it-qat"},{"name":""}]}"#;
        let models = parse_models(json);
        assert_eq!(models, vec!["gemma4:e4b-it-qat", "gemma4:e2b-it-qat"]); // empty dropped
        assert!(parse_models("nope").is_empty());
    }
}
