//! Google Drive API v3 — browse folders, download a text file, upload edits.
//!
//! File-list parsing + classification are pure (serde_json) and unit-tested;
//! the fetch/download/upload are behind the `cloud` feature.

use serde::Deserialize;

use super::oauth;
use super::IntResult;

const API: &str = "https://www.googleapis.com/drive/v3";
const UPLOAD: &str = "https://www.googleapis.com/upload/drive/v3";

pub const FOLDER_MIME: &str = "application/vnd.google-apps.folder";

#[derive(Debug, Clone)]
pub struct DriveFile {
    pub id: String,
    pub name: String,
    pub mime_type: String,
}

impl DriveFile {
    pub fn is_folder(&self) -> bool {
        self.mime_type == FOLDER_MIME
    }
    /// Whether Onyx can open this file as editable text.
    pub fn is_text(&self) -> bool {
        self.mime_type.starts_with("text/")
            || matches!(
                self.mime_type.as_str(),
                "application/json" | "application/xml" | "application/x-yaml"
            )
            || {
                let n = self.name.to_ascii_lowercase();
                [".md", ".markdown", ".txt", ".org", ".csv", ".log", ".rs", ".py", ".js", ".ts", ".toml", ".yaml", ".yml"]
                    .iter()
                    .any(|e| n.ends_with(e))
            }
    }
    /// A Google-native doc (needs export, not download) — unsupported for now.
    pub fn is_google_doc(&self) -> bool {
        self.mime_type.starts_with("application/vnd.google-apps.") && !self.is_folder()
    }
}

#[derive(Deserialize)]
struct FilesResponse {
    #[serde(default)]
    files: Vec<RawFile>,
}
#[derive(Deserialize)]
struct RawFile {
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default, rename = "mimeType")]
    mime_type: String,
}

pub fn parse_files(json: &str) -> Vec<DriveFile> {
    serde_json::from_str::<FilesResponse>(json)
        .map(|r| {
            let mut files: Vec<DriveFile> = r
                .files
                .into_iter()
                .map(|f| DriveFile {
                    id: f.id,
                    name: f.name,
                    mime_type: f.mime_type,
                })
                .collect();
            // Folders first, then by name (case-insensitive).
            files.sort_by(|a, b| {
                b.is_folder()
                    .cmp(&a.is_folder())
                    .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            });
            files
        })
        .unwrap_or_default()
}

/// JSON metadata for a new Drive file (`serde_json` escapes the name safely).
fn file_metadata(name: &str, parent_id: &str) -> String {
    serde_json::json!({ "name": name, "parents": [parent_id] }).to_string()
}

/// Build a Drive `multipart/related` upload body: a JSON metadata part followed
/// by the media (content) part, separated by `boundary`.
fn multipart_body(boundary: &str, metadata_json: &str, mime: &str, content: &str) -> String {
    format!(
        "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata_json}\r\n--{boundary}\r\nContent-Type: {mime}\r\n\r\n{content}\r\n--{boundary}--\r\n"
    )
}

/// Pull the `id` out of a Drive file-create response.
fn parse_created_id(json: &str) -> Option<String> {
    #[derive(Deserialize)]
    struct R {
        id: String,
    }
    serde_json::from_str::<R>(json).ok().map(|r| r.id)
}

// -----------------------------------------------------------------------------
// Network (cloud)
// -----------------------------------------------------------------------------

/// List the children of `parent` (use "root" for My Drive's top level).
#[cfg(feature = "cloud")]
pub fn list_folder(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    parent: &str,
) -> IntResult<Vec<DriveFile>> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let q = oauth::urlencode(&format!("'{parent}' in parents and trashed=false"));
    let url = format!(
        "{API}/files?q={q}&fields=files(id,name,mimeType)&pageSize=200&orderBy=folder,name",
    );
    let json = oauth::get_json(&url, &at)?;
    Ok(parse_files(&json))
}

/// Download a file's content as text.
#[cfg(feature = "cloud")]
pub fn download_text(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    file_id: &str,
) -> IntResult<String> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    oauth::get_json(&format!("{API}/files/{}?alt=media", oauth::urlencode(file_id)), &at)
}

/// Download any file (binary-safe) to a local path — for PDFs/images/etc. handed
/// to an external viewer. `alt=media` returns the raw bytes for a normal uploaded
/// file (a Google-native doc would need export instead; guard with `is_google_doc`).
#[cfg(feature = "cloud")]
pub fn download_file(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    file_id: &str,
    dest: &std::path::Path,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!("{API}/files/{}?alt=media", oauth::urlencode(file_id));
    oauth::download_to_file(&url, &at, dest)
}

/// Create a NEW file with text content inside `parent_id` (a multipart upload
/// that sets name + parent + body in one request). Returns the new file id.
#[cfg(feature = "cloud")]
pub fn create_file(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    parent_id: &str,
    name: &str,
    content: &str,
    mime: &str,
) -> IntResult<String> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!("{UPLOAD}/files?uploadType=multipart&fields=id,name,mimeType");
    let boundary = "onyx-drive-boundary-9d1f7a2c4e";
    let meta = file_metadata(name, parent_id);
    let body = multipart_body(boundary, &meta, mime, content);
    let ctype = format!("multipart/related; boundary={boundary}");
    let resp = oauth::send_media("POST", &url, &at, &ctype, &body)?;
    parse_created_id(&resp).ok_or_else(|| "upload succeeded but no file id returned".to_string())
}

/// Upload new text content for an existing file (media update = two-way save).
#[cfg(feature = "cloud")]
pub fn upload_text(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    file_id: &str,
    content: &str,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!("{UPLOAD}/files/{}?uploadType=media", oauth::urlencode(file_id));
    oauth::send_media("PATCH", &url, &at, "text/plain; charset=UTF-8", content).map(|_| ())
}

#[cfg(not(feature = "cloud"))]
pub fn list_folder(_: &str, _: &str, _: &std::path::Path, _: &str) -> IntResult<Vec<DriveFile>> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn download_text(_: &str, _: &str, _: &std::path::Path, _: &str) -> IntResult<String> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn download_file(_: &str, _: &str, _: &std::path::Path, _: &str, _: &std::path::Path) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn create_file(_: &str, _: &str, _: &std::path::Path, _: &str, _: &str, _: &str, _: &str) -> IntResult<String> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn upload_text(_: &str, _: &str, _: &std::path::Path, _: &str, _: &str) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_sorts_files() {
        let json = r#"{"files":[
            {"id":"f1","name":"zebra.md","mimeType":"text/markdown"},
            {"id":"d1","name":"Projects","mimeType":"application/vnd.google-apps.folder"},
            {"id":"f2","name":"apple.txt","mimeType":"text/plain"}
        ]}"#;
        let files = parse_files(json);
        // Folder first, then files alphabetically.
        assert!(files[0].is_folder() && files[0].name == "Projects");
        assert_eq!(files[1].name, "apple.txt");
        assert_eq!(files[2].name, "zebra.md");
    }

    #[test]
    fn classifies_text_vs_folder_vs_gdoc() {
        let md = DriveFile { id: "1".into(), name: "n.md".into(), mime_type: "text/markdown".into() };
        assert!(md.is_text() && !md.is_folder() && !md.is_google_doc());
        let folder = DriveFile { id: "2".into(), name: "F".into(), mime_type: FOLDER_MIME.into() };
        assert!(folder.is_folder() && !folder.is_text());
        let gdoc = DriveFile { id: "3".into(), name: "Doc".into(), mime_type: "application/vnd.google-apps.document".into() };
        assert!(gdoc.is_google_doc() && !gdoc.is_text());
        // Unknown mime but .md name → still text.
        let weird = DriveFile { id: "4".into(), name: "notes.md".into(), mime_type: "application/octet-stream".into() };
        assert!(weird.is_text());
        // A PDF: not text, not folder, not a google doc → routed to the external viewer.
        let pdf = DriveFile { id: "5".into(), name: "report.pdf".into(), mime_type: "application/pdf".into() };
        assert!(!pdf.is_text() && !pdf.is_folder() && !pdf.is_google_doc());
    }

    #[test]
    fn builds_multipart_upload_body() {
        // Names with spaces/quotes must be JSON-escaped by serde_json.
        let meta = file_metadata("my note.md", "FOLDER1");
        assert!(meta.contains("\"name\":\"my note.md\""));
        assert!(meta.contains("\"parents\":[\"FOLDER1\"]"));

        let body = multipart_body("BB", &meta, "text/markdown", "# Hi\n");
        assert!(body.starts_with("--BB\r\n"));
        assert!(body.contains("Content-Type: application/json"));
        assert!(body.contains("Content-Type: text/markdown"));
        assert!(body.contains("# Hi\n"));
        assert!(body.trim_end().ends_with("--BB--"));
    }

    #[test]
    fn parses_created_file_id() {
        assert_eq!(
            parse_created_id(r#"{"id":"abc123","name":"n.md"}"#),
            Some("abc123".to_string())
        );
        assert_eq!(parse_created_id("not json"), None);
    }
}
