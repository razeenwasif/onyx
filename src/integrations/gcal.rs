//! Google Calendar API v3 — list events for a month, create/delete events.
//!
//! Parsing + body building are pure (serde_json/chrono) and unit-tested; the
//! fetch/create/delete are behind the `cloud` feature.

use chrono::{Datelike, NaiveDate};
use serde::Deserialize;

use super::oauth;
use super::IntResult;

const API: &str = "https://www.googleapis.com/calendar/v3";

/// A calendar in the user's list.
#[derive(Debug, Clone)]
pub struct Calendar {
    pub id: String,
    pub summary: String,
}

/// One event, reduced to what the month grid + agenda need.
#[derive(Debug, Clone)]
pub struct CalEvent {
    pub id: String,
    pub calendar_id: String,
    pub summary: String,
    /// The day the event starts on (used to mark the month grid).
    pub date: NaiveDate,
    pub all_day: bool,
    /// "all-day" or "HH:MM" for the agenda.
    pub time_label: String,
}

#[derive(Deserialize)]
struct CalListResponse {
    #[serde(default)]
    items: Vec<RawCal>,
}
#[derive(Deserialize)]
struct RawCal {
    id: String,
    #[serde(default)]
    summary: String,
}

#[derive(Deserialize)]
struct EventsResponse {
    #[serde(default)]
    items: Vec<RawEvent>,
}
#[derive(Deserialize)]
struct RawEvent {
    #[serde(default)]
    id: String,
    #[serde(default)]
    summary: Option<String>,
    #[serde(default)]
    start: Option<RawWhen>,
    #[serde(default)]
    status: Option<String>,
}
#[derive(Deserialize)]
struct RawWhen {
    #[serde(default)]
    date: Option<String>,
    #[serde(default)]
    #[serde(rename = "dateTime")]
    date_time: Option<String>,
}

pub fn parse_calendars(json: &str) -> Vec<Calendar> {
    serde_json::from_str::<CalListResponse>(json)
        .map(|r| {
            r.items
                .into_iter()
                .map(|c| Calendar {
                    id: c.id,
                    summary: c.summary,
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Parse an events list into `CalEvent`s, skipping cancelled/dateless ones.
pub fn parse_events(json: &str, calendar_id: &str) -> Vec<CalEvent> {
    let Ok(resp) = serde_json::from_str::<EventsResponse>(json) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for e in resp.items {
        if e.status.as_deref() == Some("cancelled") {
            continue;
        }
        let Some(when) = e.start else { continue };
        let (date, all_day, time_label) = if let Some(d) = when.date {
            // all-day: YYYY-MM-DD
            match NaiveDate::parse_from_str(&d, "%Y-%m-%d") {
                Ok(nd) => (nd, true, "all-day".to_string()),
                Err(_) => continue,
            }
        } else if let Some(dt) = when.date_time {
            // timed: RFC-3339; take the date + HH:MM.
            match chrono::DateTime::parse_from_rfc3339(&dt) {
                Ok(d) => {
                    let local = d.naive_local();
                    (
                        local.date(),
                        false,
                        local.format("%H:%M").to_string(),
                    )
                }
                Err(_) => continue,
            }
        } else {
            continue;
        };
        out.push(CalEvent {
            id: e.id,
            calendar_id: calendar_id.to_string(),
            summary: e.summary.unwrap_or_else(|| "(no title)".into()),
            date,
            all_day,
            time_label,
        });
    }
    out
}

/// First-of-month and first-of-next-month (the API's `timeMin`/`timeMax`).
pub fn month_bounds(year: i32, month: u32) -> (NaiveDate, NaiveDate) {
    let first = NaiveDate::from_ymd_opt(year, month, 1).unwrap_or_default();
    let next = if month == 12 {
        NaiveDate::from_ymd_opt(year + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(year, month + 1, 1)
    }
    .unwrap_or(first);
    (first, next)
}

/// JSON body for an all-day event on `date` (end is exclusive = next day).
pub fn all_day_event_body(date: NaiveDate, summary: &str) -> String {
    let end = date.succ_opt().unwrap_or(date);
    let mut obj = serde_json::Map::new();
    obj.insert("summary".into(), serde_json::Value::String(summary.to_string()));
    let mut start = serde_json::Map::new();
    start.insert("date".into(), serde_json::Value::String(date.format("%Y-%m-%d").to_string()));
    let mut endo = serde_json::Map::new();
    endo.insert("date".into(), serde_json::Value::String(end.format("%Y-%m-%d").to_string()));
    obj.insert("start".into(), serde_json::Value::Object(start));
    obj.insert("end".into(), serde_json::Value::Object(endo));
    serde_json::Value::Object(obj).to_string()
}

// -----------------------------------------------------------------------------
// Network (cloud)
// -----------------------------------------------------------------------------

/// Fetch every event in `[first-of-month, first-of-next-month)` across all the
/// user's calendars, sorted by date then time.
#[cfg(feature = "cloud")]
pub fn fetch_month(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    year: i32,
    month: u32,
) -> IntResult<Vec<CalEvent>> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let (first, next) = month_bounds(year, month);
    let time_min = format!("{}T00:00:00Z", first.format("%Y-%m-%d"));
    let time_max = format!("{}T00:00:00Z", next.format("%Y-%m-%d"));

    let cal_json = oauth::get_json(&format!("{API}/users/me/calendarList"), &at)?;
    let calendars = parse_calendars(&cal_json);
    let mut out = Vec::new();
    for cal in calendars {
        let url = format!(
            "{API}/calendars/{}/events?singleEvents=true&orderBy=startTime&timeMin={}&timeMax={}&maxResults=250",
            oauth::urlencode(&cal.id),
            oauth::urlencode(&time_min),
            oauth::urlencode(&time_max),
        );
        // A calendar we can't read shouldn't fail the whole fetch.
        if let Ok(ej) = oauth::get_json(&url, &at) {
            out.extend(parse_events(&ej, &cal.id));
        }
    }
    out.sort_by(|a, b| a.date.cmp(&b.date).then_with(|| a.time_label.cmp(&b.time_label)));
    Ok(out)
}

/// Create an all-day event on `date` in the primary calendar.
#[cfg(feature = "cloud")]
pub fn create_all_day(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    date: NaiveDate,
    summary: &str,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!("{API}/calendars/primary/events");
    oauth::send_json("POST", &url, &at, &all_day_event_body(date, summary)).map(|_| ())
}

/// Delete an event.
#[cfg(feature = "cloud")]
pub fn delete_event(
    client_id: &str,
    client_secret: &str,
    token_path: &std::path::Path,
    calendar_id: &str,
    event_id: &str,
) -> IntResult<()> {
    let at = oauth::valid_access_token(client_id, client_secret, token_path)?;
    let url = format!(
        "{API}/calendars/{}/events/{}",
        oauth::urlencode(calendar_id),
        oauth::urlencode(event_id)
    );
    oauth::delete(&url, &at)
}

#[cfg(not(feature = "cloud"))]
pub fn fetch_month(_: &str, _: &str, _: &std::path::Path, _: i32, _: u32) -> IntResult<Vec<CalEvent>> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn create_all_day(_: &str, _: &str, _: &std::path::Path, _: NaiveDate, _: &str) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}
#[cfg(not(feature = "cloud"))]
pub fn delete_event(_: &str, _: &str, _: &std::path::Path, _: &str, _: &str) -> IntResult<()> {
    Err("cloud features not built — reinstall with `cargo install --path . --features cloud`".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_calendars() {
        let json = r#"{"items":[{"id":"primary","summary":"Me"},{"id":"work@x","summary":"Work"}]}"#;
        let c = parse_calendars(json);
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].id, "primary");
    }

    #[test]
    fn parses_all_day_and_timed_events() {
        let json = r#"{"items":[
            {"id":"e1","summary":"Holiday","start":{"date":"2026-06-20"}},
            {"id":"e2","summary":"Standup","start":{"dateTime":"2026-06-15T09:30:00+10:00"}},
            {"id":"e3","summary":"Cancelled","status":"cancelled","start":{"date":"2026-06-21"}}
        ]}"#;
        let evs = parse_events(json, "primary");
        assert_eq!(evs.len(), 2, "cancelled skipped");
        assert_eq!(evs[0].summary, "Holiday");
        assert!(evs[0].all_day);
        assert_eq!(evs[0].date, NaiveDate::from_ymd_opt(2026, 6, 20).unwrap());
        assert!(!evs[1].all_day);
        assert_eq!(evs[1].date, NaiveDate::from_ymd_opt(2026, 6, 15).unwrap());
        assert_eq!(evs[1].time_label, "09:30");
    }

    #[test]
    fn month_bounds_and_event_body() {
        let (f, n) = month_bounds(2026, 12);
        assert_eq!(f, NaiveDate::from_ymd_opt(2026, 12, 1).unwrap());
        assert_eq!(n, NaiveDate::from_ymd_opt(2027, 1, 1).unwrap());

        let body = all_day_event_body(NaiveDate::from_ymd_opt(2026, 6, 20).unwrap(), "Trip");
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["summary"], "Trip");
        assert_eq!(v["start"]["date"], "2026-06-20");
        assert_eq!(v["end"]["date"], "2026-06-21"); // end exclusive
    }
}
