//! Google OAuth 2.0 for an installed/"Desktop app" client: loopback-redirect
//! authorization-code flow + token refresh + an on-disk token cache.
//!
//! Pure helpers (URL building, query parsing, token (de)serialization) are
//! always compiled and unit-tested. The networked steps (code→token exchange,
//! refresh, the interactive consent flow) are behind the `cloud` feature.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::IntResult;

const AUTH_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";

/// OAuth scopes Onyx requests (full Tasks + Calendar for read + two-way).
pub const SCOPE_TASKS: &str = "https://www.googleapis.com/auth/tasks";
pub const SCOPE_CALENDAR: &str = "https://www.googleapis.com/auth/calendar";
/// All scopes Onyx asks for in one consent (space-separated, per OAuth spec).
pub const SCOPES: &str = "https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/calendar";

/// A cached OAuth token (persisted to `google.json`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OAuthToken {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: String,
    /// Unix seconds at which `access_token` expires.
    #[serde(default)]
    pub expires_at: u64,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub token_type: String,
}

impl OAuthToken {
    /// True when the access token is missing or within 60s of expiry.
    pub fn needs_refresh(&self, now: u64) -> bool {
        self.access_token.is_empty() || (self.expires_at != 0 && now + 60 >= self.expires_at)
    }
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Percent-encode a string for use in a URL query value (RFC 3986 unreserved
/// set kept; everything else `%XX`).
pub fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Build the Google consent URL for the authorization-code flow.
pub fn consent_url(client_id: &str, redirect_uri: &str, scope: &str, state: &str) -> String {
    format!(
        "{AUTH_ENDPOINT}?client_id={}&redirect_uri={}&response_type=code&scope={}&access_type=offline&prompt=consent&state={}",
        urlencode(client_id),
        urlencode(redirect_uri),
        urlencode(scope),
        urlencode(state),
    )
}

/// Extract `code` and `state` from a redirect request's first line, e.g.
/// `GET /?code=abc&state=xyz HTTP/1.1`.
pub fn parse_redirect_query(request_line: &str) -> Option<(String, String)> {
    let path = request_line.split_whitespace().nth(1)?;
    let query = path.split_once('?').map(|(_, q)| q).unwrap_or("");
    let mut code = None;
    let mut state = None;
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            let val = percent_decode(v);
            match k {
                "code" => code = Some(val),
                "state" => state = Some(val),
                _ => {}
            }
        }
    }
    Some((code?, state.unwrap_or_default()))
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (
                (b[i + 1] as char).to_digit(16),
                (b[i + 2] as char).to_digit(16),
            ) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Google's token-endpoint response shape.
#[derive(Debug, Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub expires_in: Option<u64>,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub token_type: Option<String>,
}

/// Fold a token response into an `OAuthToken`, carrying `prev_refresh` forward
/// when Google omits the refresh token (it only returns it on first consent).
pub fn token_from_response(r: TokenResponse, now: u64, prev_refresh: &str) -> OAuthToken {
    OAuthToken {
        access_token: r.access_token,
        refresh_token: r.refresh_token.filter(|s| !s.is_empty()).unwrap_or_else(|| prev_refresh.to_string()),
        expires_at: now + r.expires_in.unwrap_or(3600),
        scope: r.scope.unwrap_or_default(),
        token_type: r.token_type.unwrap_or_else(|| "Bearer".into()),
    }
}

// -----------------------------------------------------------------------------
// Token store
// -----------------------------------------------------------------------------

pub fn load_token(path: &std::path::Path) -> Option<OAuthToken> {
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn save_token(path: &std::path::Path, token: &OAuthToken) -> IntResult<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(token).map_err(|e| e.to_string())?;
    std::fs::write(path, json).map_err(|e| e.to_string())?;
    set_mode_600(path);
    Ok(())
}

#[cfg(unix)]
fn set_mode_600(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}
#[cfg(not(unix))]
fn set_mode_600(_path: &std::path::Path) {}

// -----------------------------------------------------------------------------
// Networked steps (cloud feature)
// -----------------------------------------------------------------------------

/// Run the interactive consent flow: spin a loopback listener, open the browser
/// to the consent URL, catch the redirect, and exchange the code for a token.
/// Blocks until the user authorizes (or times out). Returns the saved token.
#[cfg(feature = "cloud")]
pub fn run_consent_flow(client_id: &str, client_secret: &str, scope: &str) -> IntResult<OAuthToken> {
    use std::io::{Read, Write};
    use std::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}");
    let state = format!("onyx{}", now_unix());
    let url = consent_url(client_id, &redirect_uri, scope, &state);

    println!("\nOpening your browser to authorize Onyx with Google…");
    println!("If it doesn't open, visit:\n  {url}\n");
    let _ = super::open_url(&url);

    listener
        .set_nonblocking(false)
        .map_err(|e| e.to_string())?;
    let (mut stream, _) = listener.accept().map_err(|e| e.to_string())?;
    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).map_err(|e| e.to_string())?;
    let request = String::from_utf8_lossy(&buf[..n]);
    let first_line = request.lines().next().unwrap_or("");
    let (code, got_state) =
        parse_redirect_query(first_line).ok_or("no authorization code in redirect")?;
    let body = "<html><body style='font-family:sans-serif'>Onyx is authorized — you can close this tab.</body></html>";
    let _ = write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        body
    );
    if got_state != state {
        return Err("OAuth state mismatch (possible CSRF)".into());
    }
    exchange_code(client_id, client_secret, &code, &redirect_uri)
}

#[cfg(feature = "cloud")]
pub fn exchange_code(
    client_id: &str,
    client_secret: &str,
    code: &str,
    redirect_uri: &str,
) -> IntResult<OAuthToken> {
    let params = [
        ("code", code),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("redirect_uri", redirect_uri),
        ("grant_type", "authorization_code"),
    ];
    let resp = reqwest::blocking::Client::new()
        .post(TOKEN_ENDPOINT)
        .form(&params)
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("token exchange failed: {}", resp.status()));
    }
    let tr: TokenResponse = resp.json().map_err(|e| e.to_string())?;
    Ok(token_from_response(tr, now_unix(), ""))
}

#[cfg(feature = "cloud")]
pub fn refresh(client_id: &str, client_secret: &str, refresh_token: &str) -> IntResult<OAuthToken> {
    let params = [
        ("refresh_token", refresh_token),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("grant_type", "refresh_token"),
    ];
    let resp = reqwest::blocking::Client::new()
        .post(TOKEN_ENDPOINT)
        .form(&params)
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("token refresh failed: {}", resp.status()));
    }
    let tr: TokenResponse = resp.json().map_err(|e| e.to_string())?;
    Ok(token_from_response(tr, now_unix(), refresh_token))
}

/// Return a valid access token, refreshing + re-saving if the cached one is
/// stale. Errors if no token is cached (run consent first).
#[cfg(feature = "cloud")]
pub fn valid_access_token(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
) -> IntResult<String> {
    let mut token = load_token(token_path).ok_or("not authorized — run :google auth")?;
    if token.needs_refresh(now_unix()) {
        if token.refresh_token.is_empty() {
            return Err("session expired — run :google auth again".into());
        }
        token = refresh(client_id, client_secret, &token.refresh_token)?;
        save_token(token_path, &token)?;
    }
    Ok(token.access_token)
}

/// HTTP GET a JSON API endpoint with the bearer token.
#[cfg(feature = "cloud")]
pub fn get_json(url: &str, access_token: &str) -> IntResult<String> {
    let resp = reqwest::blocking::Client::new()
        .get(url)
        .bearer_auth(access_token)
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("GET {url} → {}", resp.status()));
    }
    resp.text().map_err(|e| e.to_string())
}

/// PATCH/POST a JSON body to an API endpoint with the bearer token, returning
/// the response text. `method` is "PATCH" or "POST" (the shared write path that
/// Tasks/Calendar/Drive all use).
#[cfg(feature = "cloud")]
pub fn send_json(method: &str, url: &str, access_token: &str, body: &str) -> IntResult<String> {
    let client = reqwest::blocking::Client::new();
    let req = match method {
        "POST" => client.post(url),
        "PATCH" => client.patch(url),
        "PUT" => client.put(url),
        other => return Err(format!("unsupported method {other}")),
    };
    let resp = req
        .bearer_auth(access_token)
        .header("Content-Type", "application/json")
        .body(body.to_string())
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("{method} {url} → {}", resp.status()));
    }
    resp.text().map_err(|e| e.to_string())
}

/// DELETE an API resource with the bearer token.
#[cfg(feature = "cloud")]
pub fn delete(url: &str, access_token: &str) -> IntResult<()> {
    let resp = reqwest::blocking::Client::new()
        .delete(url)
        .bearer_auth(access_token)
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("DELETE {url} → {}", resp.status()));
    }
    Ok(())
}

// Non-cloud stubs so call sites compile without the feature.
#[cfg(not(feature = "cloud"))]
pub fn run_consent_flow(_: &str, _: &str, _: &str) -> IntResult<OAuthToken> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn valid_access_token(_: &str, _: &str, _: &std::path::Path) -> IntResult<String> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn get_json(_: &str, _: &str) -> IntResult<String> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn send_json(_: &str, _: &str, _: &str, _: &str) -> IntResult<String> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn delete(_: &str, _: &str) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consent_url_encodes_params() {
        let u = consent_url("cid.apps", "http://127.0.0.1:8080", SCOPE_TASKS, "st8");
        assert!(u.starts_with(AUTH_ENDPOINT));
        assert!(u.contains("client_id=cid.apps"));
        assert!(u.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A8080"));
        assert!(u.contains("scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Ftasks"));
        assert!(u.contains("access_type=offline") && u.contains("state=st8"));
    }

    #[test]
    fn parses_redirect_code_and_state() {
        let (code, state) =
            parse_redirect_query("GET /?code=4%2F0Abc_def&state=onyx123 HTTP/1.1").unwrap();
        assert_eq!(code, "4/0Abc_def");
        assert_eq!(state, "onyx123");
        assert!(parse_redirect_query("GET /favicon.ico HTTP/1.1").map(|(c, _)| c).is_none());
    }

    #[test]
    fn token_response_carries_refresh_forward() {
        let r = TokenResponse {
            access_token: "at".into(),
            refresh_token: None,
            expires_in: Some(3600),
            scope: Some(SCOPE_TASKS.into()),
            token_type: Some("Bearer".into()),
        };
        let t = token_from_response(r, 1000, "old_refresh");
        assert_eq!(t.access_token, "at");
        assert_eq!(t.refresh_token, "old_refresh"); // carried forward
        assert_eq!(t.expires_at, 4600);
        assert!(!t.needs_refresh(1000));
        assert!(t.needs_refresh(4600));
    }

    #[test]
    fn token_roundtrips_through_disk() {
        let dir = std::env::temp_dir().join(format!("onyx-oauth-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("google.json");
        let t = OAuthToken {
            access_token: "a".into(),
            refresh_token: "r".into(),
            expires_at: 123,
            scope: SCOPE_TASKS.into(),
            token_type: "Bearer".into(),
        };
        save_token(&path, &t).unwrap();
        let back = load_token(&path).unwrap();
        assert_eq!(back.access_token, "a");
        assert_eq!(back.refresh_token, "r");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
