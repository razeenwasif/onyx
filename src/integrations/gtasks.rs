//! Google Tasks API v1 — list task lists and their tasks.
//!
//! Parsing is pure (serde_json) and unit-tested; the fetch is behind `cloud`.

use serde::Deserialize;

use super::oauth;
use super::IntResult;

const API: &str = "https://tasks.googleapis.com/tasks/v1";

/// A task list (e.g. "My Tasks").
#[derive(Debug, Clone)]
pub struct TaskList {
    pub id: String,
    pub title: String,
}

/// A single task, flattened with its list's id+title (id needed to write back).
#[derive(Debug, Clone)]
pub struct GTask {
    pub id: String,
    pub list_id: String,
    pub list_title: String,
    pub title: String,
    pub notes: String,
    /// RFC-3339 due date, if any (date-only in practice).
    pub due: Option<String>,
    pub completed: bool,
}

#[derive(Deserialize)]
struct ListsResponse {
    #[serde(default)]
    items: Vec<RawList>,
}
#[derive(Deserialize)]
struct RawList {
    id: String,
    #[serde(default)]
    title: String,
}

#[derive(Deserialize)]
struct TasksResponse {
    #[serde(default)]
    items: Vec<RawTask>,
}
#[derive(Deserialize)]
struct RawTask {
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    notes: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    due: Option<String>,
}

pub fn parse_tasklists(json: &str) -> Vec<TaskList> {
    serde_json::from_str::<ListsResponse>(json)
        .map(|r| {
            r.items
                .into_iter()
                .map(|l| TaskList {
                    id: l.id,
                    title: l.title,
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_tasks(json: &str, list_id: &str, list_title: &str) -> Vec<GTask> {
    serde_json::from_str::<TasksResponse>(json)
        .map(|r| {
            r.items
                .into_iter()
                .filter(|t| !t.title.trim().is_empty())
                .map(|t| GTask {
                    id: t.id,
                    list_id: list_id.to_string(),
                    list_title: list_title.to_string(),
                    title: t.title,
                    notes: t.notes,
                    due: t.due.filter(|d| !d.is_empty()),
                    completed: t.status == "completed",
                })
                .collect()
        })
        .unwrap_or_default()
}

/// JSON body to flip a task's completion: Google clears/sets the `completed`
/// timestamp from the `status`.
pub fn status_body(completed: bool) -> String {
    if completed {
        "{\"status\":\"completed\"}".to_string()
    } else {
        "{\"status\":\"needsAction\",\"completed\":null}".to_string()
    }
}

/// JSON body to create a task with a title (and optional notes).
pub fn new_task_body(title: &str, notes: &str) -> String {
    let mut obj = serde_json::Map::new();
    obj.insert("title".into(), serde_json::Value::String(title.to_string()));
    if !notes.is_empty() {
        obj.insert("notes".into(), serde_json::Value::String(notes.to_string()));
    }
    serde_json::Value::Object(obj).to_string()
}

/// Fetch every task across every list (open first, then completed).
#[cfg(feature = "cloud")]
pub fn fetch_all(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
) -> IntResult<Vec<GTask>> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let lists_json = oauth::get_json(&format!("{API}/users/@me/lists"), &at)?;
    let lists = parse_tasklists(&lists_json);
    let mut out = Vec::new();
    for list in lists {
        let url = format!(
            "{API}/lists/{}/tasks?showCompleted=true&showHidden=true&maxResults=100",
            oauth::urlencode(&list.id)
        );
        match oauth::get_json(&url, &at) {
            Ok(tj) => out.extend(parse_tasks(&tj, &list.id, &list.title)),
            Err(e) => return Err(e),
        }
    }
    out.sort_by(|a, b| {
        a.completed
            .cmp(&b.completed)
            .then_with(|| a.list_title.cmp(&b.list_title))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    Ok(out)
}

/// Set a task complete/incomplete (PATCH), writing back to Google.
#[cfg(feature = "cloud")]
pub fn set_completed(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    list_id: &str,
    task_id: &str,
    completed: bool,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!(
        "{API}/lists/{}/tasks/{}",
        oauth::urlencode(list_id),
        oauth::urlencode(task_id)
    );
    oauth::send_json("PATCH", &url, &at, &status_body(completed)).map(|_| ())
}

/// Create a task in a list (POST). Returns Ok on success.
#[cfg(feature = "cloud")]
pub fn create_task(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    list_id: &str,
    title: &str,
    notes: &str,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!("{API}/lists/{}/tasks", oauth::urlencode(list_id));
    oauth::send_json("POST", &url, &at, &new_task_body(title, notes)).map(|_| ())
}

/// Delete a task (DELETE).
#[cfg(feature = "cloud")]
pub fn delete_task(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    list_id: &str,
    task_id: &str,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!(
        "{API}/lists/{}/tasks/{}",
        oauth::urlencode(list_id),
        oauth::urlencode(task_id)
    );
    oauth::delete(&url, &at)
}

/// The id of the default ("@default") task list, for pushing new tasks.
pub const DEFAULT_LIST: &str = "@default";

#[cfg(not(feature = "cloud"))]
pub fn fetch_all(_: &str, _: &str, _: &std::path::Path) -> IntResult<Vec<GTask>> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn set_completed(_: &str, _: &str, _: &std::path::Path, _: &str, _: &str, _: bool) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn create_task(_: &str, _: &str, _: &std::path::Path, _: &str, _: &str, _: &str) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn delete_task(_: &str, _: &str, _: &std::path::Path, _: &str, _: &str) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_task_lists() {
        let json = r#"{"items":[{"id":"L1","title":"My Tasks"},{"id":"L2","title":"Work"}]}"#;
        let lists = parse_tasklists(json);
        assert_eq!(lists.len(), 2);
        assert_eq!(lists[0].id, "L1");
        assert_eq!(lists[1].title, "Work");
    }

    #[test]
    fn parses_tasks_with_status_and_due() {
        let json = r#"{"items":[
            {"id":"t1","title":"Buy milk","status":"needsAction","due":"2026-06-20T00:00:00.000Z"},
            {"id":"t2","title":"Old thing","status":"completed","notes":"done note"},
            {"id":"t3","title":"   ","status":"needsAction"}
        ]}"#;
        let tasks = parse_tasks(json, "L1", "My Tasks");
        assert_eq!(tasks.len(), 2, "blank-title task filtered out");
        assert_eq!(tasks[0].title, "Buy milk");
        assert!(!tasks[0].completed);
        assert_eq!(tasks[0].due.as_deref(), Some("2026-06-20T00:00:00.000Z"));
        assert_eq!(tasks[0].list_id, "L1");
        assert_eq!(tasks[0].list_title, "My Tasks");
        assert!(tasks[1].completed);
        assert_eq!(tasks[1].notes, "done note");
    }

    #[test]
    fn write_bodies_are_well_formed() {
        assert_eq!(status_body(true), "{\"status\":\"completed\"}");
        assert!(status_body(false).contains("needsAction"));
        let b = new_task_body("Buy milk", "from the shop");
        let v: serde_json::Value = serde_json::from_str(&b).unwrap();
        assert_eq!(v["title"], "Buy milk");
        assert_eq!(v["notes"], "from the shop");
        // No notes → no notes key.
        let b = new_task_body("Just a title", "");
        assert!(!b.contains("notes"));
    }

    #[test]
    fn tolerates_empty_or_garbage() {
        assert!(parse_tasklists("{}").is_empty());
        assert!(parse_tasks("not json", "L", "x").is_empty());
    }
}
