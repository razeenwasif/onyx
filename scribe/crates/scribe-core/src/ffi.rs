//! The C ABI the macOS app calls. See `include/scribe_core.h`.
//!
//! Two kinds of entry point:
//!
//! * `scribe_call` takes a JSON request and returns a JSON response. It covers
//!   everything that is not on a per-frame path: storage, search, tables,
//!   settings. JSON keeps the boundary narrow and the Swift side `Codable`.
//! * Ink geometry takes and returns raw `f64` buffers, because it runs on
//!   every pen sample while writing and must not allocate strings.
//!
//! No panic may cross the boundary; every entry point catches unwinds.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde_json::{json, Value};

use crate::color::{self, Rgba};
use crate::geometry::{self, OutlineOptions};
use crate::model::PageDoc;
use crate::settings::Settings;
use crate::table;
use crate::workspace::{path_str, sanitize_name, Workspace};

// ------------------------------------------------------------------ strings

/// Handles a JSON request `{"op": "...", ...}`. Returns `{"ok": ...}` or
/// `{"error": "..."}`. The result must be released with `scribe_string_free`.
///
/// # Safety
/// `request` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn scribe_call(request: *const c_char) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return json!({ "error": "null request" });
        }
        let text = match CStr::from_ptr(request).to_str() {
            Ok(t) => t,
            Err(_) => return json!({ "error": "request is not UTF-8" }),
        };
        let req: Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => return json!({ "error": format!("bad request: {e}") }),
        };
        match dispatch(&req) {
            Ok(v) => json!({ "ok": v }),
            Err(e) => json!({ "error": e }),
        }
    }))
    .unwrap_or_else(|_| json!({ "error": "internal error in scribe-core" }));

    // serde_json never emits interior NULs for valid strings.
    CString::new(response.to_string()).unwrap_or_default().into_raw()
}

/// # Safety
/// `s` must come from `scribe_call` and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn scribe_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

type R = Result<Value, String>;

fn arg<T: DeserializeOwned>(req: &Value, key: &str) -> Result<T, String> {
    let v = req.get(key).cloned().unwrap_or(Value::Null);
    serde_json::from_value(v).map_err(|e| format!("argument \"{key}\": {e}"))
}

fn path_arg(req: &Value, key: &str) -> Result<PathBuf, String> {
    let s: String = arg(req, key)?;
    if s.is_empty() {
        return Err(format!("argument \"{key}\" is empty"));
    }
    Ok(PathBuf::from(s))
}

fn ws(req: &Value) -> Result<Workspace, String> {
    Workspace::open(path_arg(req, "root")?)
}

/// Operations on existing files need no root: a workspace rooted at the
/// filesystem root gives access to the path helpers without creating anything.
fn ws_any() -> Workspace {
    Workspace { root: PathBuf::from("/") }
}

fn to_value<T: serde::Serialize>(v: T) -> R {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

fn dispatch(req: &Value) -> R {
    let op: String = arg(req, "op")?;
    match op.as_str() {
        "default_root" => Ok(json!(path_str(&Workspace::default_root()))),

        "ensure_starter" => Ok(json!(ws(req)?.ensure_starter()?.map(|p| path_str(&p)))),

        "tree" => to_value(ws(req)?.tree()),

        "pages" => to_value(ws_any().list_pages(&path_arg(req, "section")?)),

        "read_page" => to_value(ws_any().read_page(&path_arg(req, "path")?)?),

        "write_page" => {
            let path = path_arg(req, "path")?;
            let mut page: PageDoc = arg(req, "page")?;
            ws_any().write_page(&path, &mut page)?;
            Ok(json!({ "modified": page.modified, "modifiedUnix": crate::workspace::parse_stamp(Some(&page.modified)) }))
        }

        "create_notebook" => {
            let w = ws(req)?;
            let name: String = arg(req, "name")?;
            let dir = w.create_notebook(&name)?;
            let first: Option<String> = arg(req, "firstSection")?;
            if let Some(section) = first {
                w.create_section(&dir, &section)?;
            }
            Ok(json!(path_str(&dir)))
        }

        "rename_notebook" => {
            ws_any().rename_notebook(&path_arg(req, "path")?, &arg::<String>(req, "name")?)?;
            Ok(Value::Null)
        }

        "create_section" => {
            let dir = ws_any().create_section(&path_arg(req, "notebook")?, &arg::<String>(req, "name")?)?;
            Ok(json!(path_str(&dir)))
        }

        "rename_section" => {
            ws_any().rename_section(&path_arg(req, "path")?, &arg::<String>(req, "name")?)?;
            Ok(Value::Null)
        }

        "forget_section" => {
            ws_any().forget_section(&path_arg(req, "notebook")?, &path_arg(req, "section")?)?;
            Ok(Value::Null)
        }

        "create_page" => {
            let file = ws_any().create_page(&path_arg(req, "section")?, &arg::<String>(req, "title")?)?;
            Ok(json!(path_str(&file)))
        }

        "rename_page" => {
            let file = ws_any().rename_page_file(
                &path_arg(req, "section")?,
                &path_arg(req, "path")?,
                &arg::<String>(req, "title")?,
            )?;
            Ok(json!(path_str(&file)))
        }

        "forget_page" => {
            ws_any().forget_page(&path_arg(req, "section")?, &path_arg(req, "path")?)?;
            Ok(Value::Null)
        }

        "set_page_order" => {
            let paths: Vec<PathBuf> = arg::<Vec<String>>(req, "paths")?.into_iter().map(PathBuf::from).collect();
            ws_any().set_page_order(&path_arg(req, "section")?, &paths)?;
            Ok(Value::Null)
        }

        "move_page" => {
            let file = ws_any().move_page(&path_arg(req, "path")?, &path_arg(req, "section")?)?;
            Ok(json!(path_str(&file)))
        }

        "new_asset" => {
            let ext: String = arg(req, "ext")?;
            let (abs, rel) = ws_any().new_asset_path(&path_arg(req, "section")?, &ext)?;
            Ok(json!({ "path": path_str(&abs), "rel": rel }))
        }

        "search" => to_value(ws(req)?.search(&arg::<String>(req, "query")?)),

        "parse_table" => {
            let html: Option<String> = arg(req, "html")?;
            let text: Option<String> = arg(req, "text")?;
            let parsed = html.as_deref().and_then(table::parse_html).or_else(|| text.as_deref().and_then(table::parse_text));
            to_value(parsed)
        }

        "export_table" => {
            let rows: Vec<Vec<String>> = arg(req, "rows")?;
            let header: Option<bool> = arg(req, "hasHeader")?;
            Ok(json!({
                "tsv": table::to_tsv(&rows),
                "html": table::to_html(&rows, header.unwrap_or(true)),
                "markdown": table::to_markdown(&rows),
            }))
        }

        "load_settings" => to_value(Settings::load()),

        "save_settings" => {
            let s: Settings = arg(req, "settings")?;
            s.save()?;
            Ok(Value::Null)
        }

        "sanitize_name" => Ok(json!(sanitize_name(&arg::<String>(req, "name")?))),

        other => Err(format!("unknown op \"{other}\"")),
    }
}

// ------------------------------------------------------------------ buffers

/// A heap buffer of `f64` owned by Rust. Release with `scribe_floats_free`.
#[repr(C)]
pub struct ScribeFloats {
    pub ptr: *mut f64,
    pub len: usize,
}

impl ScribeFloats {
    fn empty() -> Self {
        Self { ptr: std::ptr::null_mut(), len: 0 }
    }

    fn from_vec(v: Vec<f64>) -> Self {
        let boxed = v.into_boxed_slice();
        let len = boxed.len();
        let ptr = Box::into_raw(boxed) as *mut f64;
        Self { ptr, len }
    }
}

/// # Safety
/// `f` must come from this library and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn scribe_floats_free(f: ScribeFloats) {
    if !f.ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(f.ptr, f.len)));
    }
}

unsafe fn slice<'a>(ptr: *const f64, len: usize) -> &'a [f64] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

/// Outline polygon for a stroke, as `[x0, y0, x1, y1, ...]`.
///
/// # Safety
/// `points` must point to `len` readable doubles (stride 3: x, y, pressure).
#[no_mangle]
pub unsafe extern "C" fn scribe_stroke_outline(
    points: *const f64,
    len: usize,
    width: f64,
    pressure_sensitive: bool,
    fit: bool,
    taper: bool,
) -> ScribeFloats {
    catch_unwind(|| {
        let pts = slice(points, len);
        ScribeFloats::from_vec(geometry::outline(pts, OutlineOptions { width, pressure_sensitive, fit, taper }))
    })
    .unwrap_or_else(|_| ScribeFloats::empty())
}

/// # Safety
/// `points` must point to `len` readable doubles; `out` to 4 writable doubles.
#[no_mangle]
pub unsafe extern "C" fn scribe_stroke_bounds(points: *const f64, len: usize, width: f64, out: *mut f64) {
    if out.is_null() {
        return;
    }
    let b = catch_unwind(|| geometry::bounds(slice(points, len), width)).unwrap_or([0.0; 4]);
    std::ptr::copy_nonoverlapping(b.as_ptr(), out, 4);
}

/// # Safety
/// `points` must point to `len` readable doubles.
#[no_mangle]
pub unsafe extern "C" fn scribe_stroke_hit(points: *const f64, len: usize, width: f64, x: f64, y: f64, radius: f64) -> bool {
    catch_unwind(|| geometry::hit(slice(points, len), width, x, y, radius)).unwrap_or(false)
}

/// Rubs out part of a stroke. An empty buffer (`len == 0`) means the eraser
/// missed and the stroke is unchanged. Otherwise the buffer is
/// `[pieceCount, len0, ...piece0, len1, ...piece1, ...]`, where each piece is
/// a flat point array and `pieceCount` may be 0 (the stroke is gone).
///
/// # Safety
/// `points` must point to `len` readable doubles.
#[no_mangle]
pub unsafe extern "C" fn scribe_stroke_erase(
    points: *const f64,
    len: usize,
    width: f64,
    fit: bool,
    x: f64,
    y: f64,
    radius: f64,
) -> ScribeFloats {
    catch_unwind(|| match geometry::erase(slice(points, len), width, fit, x, y, radius) {
        None => ScribeFloats::empty(),
        Some(pieces) => {
            let mut out = vec![pieces.len() as f64];
            for p in pieces {
                out.push(p.len() as f64);
                out.extend(p);
            }
            ScribeFloats::from_vec(out)
        }
    })
    .unwrap_or_else(|_| ScribeFloats::empty())
}

/// Fraction (0..1) of a stroke's points inside a lasso polygon.
///
/// # Safety
/// Both pointers must point to the given number of readable doubles.
#[no_mangle]
pub unsafe extern "C" fn scribe_lasso_fraction(lasso: *const f64, lasso_len: usize, points: *const f64, len: usize) -> f64 {
    catch_unwind(|| geometry::lasso_fraction(slice(lasso, lasso_len), slice(points, len))).unwrap_or(0.0)
}

/// # Safety
/// `polygon` must point to `len` readable doubles.
#[no_mangle]
pub unsafe extern "C" fn scribe_point_in_polygon(polygon: *const f64, len: usize, x: f64, y: f64) -> bool {
    catch_unwind(|| geometry::point_in_polygon(slice(polygon, len), x, y)).unwrap_or(false)
}

// ------------------------------------------------------------------- colour

/// Parses `#RRGGBB` / `#AARRGGBB` into `0xRRGGBBAA`, or returns `fallback`.
///
/// # Safety
/// `hex` must be null or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn scribe_parse_color(hex: *const c_char, fallback: u32) -> u32 {
    if hex.is_null() {
        return fallback;
    }
    CStr::from_ptr(hex).to_str().ok().and_then(color::parse_hex).map(Rgba::to_u32).unwrap_or(fallback)
}

/// Ink colour to paint with, `0xRRGGBBAA` in and out.
#[no_mangle]
pub extern "C" fn scribe_adapt_color(rgba: u32, dark: bool) -> u32 {
    color::adapt(Rgba::from_u32(rgba), dark).to_u32()
}

#[no_mangle]
pub extern "C" fn scribe_highlighter_alpha(dark: bool) -> u8 {
    color::highlighter_alpha(dark)
}

#[cfg(test)]
fn call_json(request: &Value) -> Value {
    let s = CString::new(request.to_string()).unwrap();
    unsafe {
        let out = scribe_call(s.as_ptr());
        let v = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        scribe_string_free(out);
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_op_is_an_error_not_a_crash() {
        let v = call_json(&json!({ "op": "nope" }));
        assert!(v["error"].as_str().unwrap().contains("unknown op"));
    }

    #[test]
    fn garbage_is_an_error() {
        let s = CString::new("{not json").unwrap();
        unsafe {
            let out = scribe_call(s.as_ptr());
            let text = CStr::from_ptr(out).to_str().unwrap().to_string();
            scribe_string_free(out);
            assert!(text.contains("bad request"));
        }
    }

    #[test]
    fn outline_buffer_round_trip() {
        let pts = [0.0, 0.0, 0.5, 10.0, 0.0, 0.5, 20.0, 5.0, 0.5];
        unsafe {
            let f = scribe_stroke_outline(pts.as_ptr(), pts.len(), 2.0, true, true, true);
            assert!(f.len > 10 && f.len.is_multiple_of(2));
            scribe_floats_free(f);
        }
    }

    #[test]
    fn erase_buffer_encoding() {
        let pts = [0.0, 0.0, 0.5, 100.0, 0.0, 0.5];
        unsafe {
            let miss = scribe_stroke_erase(pts.as_ptr(), pts.len(), 2.0, true, 50.0, 50.0, 4.0);
            assert_eq!(miss.len, 0);
            scribe_floats_free(miss);

            let hit = scribe_stroke_erase(pts.as_ptr(), pts.len(), 2.0, true, 50.0, 0.0, 4.0);
            let buf = std::slice::from_raw_parts(hit.ptr, hit.len);
            assert_eq!(buf[0], 2.0);
            scribe_floats_free(hit);
        }
    }

    #[test]
    fn colours_through_the_abi() {
        let black = CString::new("#1A1A1A").unwrap();
        unsafe {
            let c = scribe_parse_color(black.as_ptr(), 0);
            assert_eq!(c, 0x1A1A1AFF);
            assert_eq!(scribe_adapt_color(c, true), 0xEFE6D8FF);
            assert_eq!(scribe_adapt_color(c, false), c);
        }
    }

    #[test]
    fn table_ops() {
        let v = call_json(&json!({ "op": "parse_table", "text": "a\tb\n1\t2" }));
        assert_eq!(v["ok"]["rows"][1][1], "2");
        let v = call_json(&json!({ "op": "parse_table", "text": "hello" }));
        assert!(v["ok"].is_null());
    }
}
