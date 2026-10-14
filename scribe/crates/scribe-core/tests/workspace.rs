use std::fs;

use scribe_core::model::*;
use scribe_core::workspace::{sanitize_name, Workspace};

fn temp_ws() -> (tempfile::TempDir, Workspace) {
    let dir = tempfile::tempdir().unwrap();
    let ws = Workspace::open(dir.path().join("Scribe Notebooks")).unwrap();
    (dir, ws)
}

#[test]
fn page_round_trips_every_object_kind() {
    let doc = PageDoc {
        title: "Math & Research Notes".into(),
        background: Background { kind: "grid".into(), spacing: 24.0, ..Background::default() },
        text_boxes: vec![TextBox {
            x: 50.0,
            y: 50.0,
            text: "Handwritten Header".into(),
            font_family: "Handwritten".into(),
            font_size: 24.0,
            bold: true,
            italic: true,
            underline: true,
            heading: Some("title".into()),
            spans: vec![TextSpan { start: 0, length: 11, bold: Some(false), ..TextSpan::default() }],
            ..TextBox::default()
        }],
        latex_blocks: vec![Latex {
            x: 60.0,
            y: 150.0,
            latex: r"\int_{0}^{\infty} e^{-x^2} \, dx = \frac{\sqrt{\pi}}{2}".into(),
            scale: 26.0,
            color: "#1D4ED8".into(),
            ..Latex::default()
        }],
        tables: vec![Table {
            x: 60.0,
            y: 300.0,
            rows: vec![
                vec!["Item".into(), "Quantity".into(), "Price".into()],
                vec!["Apples".into(), "10".into(), "$5.00".into()],
            ],
            column_widths: Some(vec![150.0, 100.0, 120.0]),
            ..Table::default()
        }],
        images: vec![Image {
            id: new_id(),
            x: 60.0,
            y: 500.0,
            width: 400.0,
            height: 300.0,
            file: "assets/diagram.png".into(),
            extra: Extra::new(),
        }],
        ..PageDoc::default()
    };

    let json = serde_json::to_string_pretty(&doc).unwrap();
    let back: PageDoc = serde_json::from_str(&json).unwrap();
    assert_eq!(back, doc);

    // Field names are the documented camelCase ones.
    for key in ["textBoxes", "latexBlocks", "columnWidths", "hasHeader", "fontFamily", "spans"] {
        assert!(json.contains(&format!("\"{key}\"")), "missing {key}");
    }
}

#[test]
fn legacy_page_from_the_windows_app_loads_with_defaults() {
    let legacy = r##"{
        "schema": "scribe.page/1",
        "id": "legacy-page-123",
        "title": "Old Page",
        "created": "2026-08-11T09:02:00.1234567+10:00",
        "strokes": [ { "color": "#1A1A1A", "width": 2.4, "height": 2.4, "points": [1, 2, 0.5, 3, 4, 0.6] } ],
        "textBoxes": [ { "id": "tb-1", "x": 10, "y": 20, "text": "Old Plain Text",
                         "fontFamily": "Segoe UI", "fontSize": 15, "bold": false, "italic": false } ],
        "images": []
    }"##;

    let doc: PageDoc = serde_json::from_str(legacy).unwrap();
    assert_eq!(doc.title, "Old Page");
    assert_eq!(doc.text_boxes[0].text, "Old Plain Text");
    assert!(!doc.text_boxes[0].underline);
    assert!(doc.text_boxes[0].heading.is_none());
    assert!(doc.text_boxes[0].xaml.is_none());
    assert!(doc.latex_blocks.is_empty() && doc.tables.is_empty());
    assert!(doc.strokes[0].fit && doc.strokes[0].pressure_sensitive);
    assert_eq!(doc.background.kind, "ruled");
}

#[test]
fn unknown_fields_survive_a_save_from_the_ui() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let sec = ws.create_section(&nb, "Sec").unwrap();
    let file = ws.create_page(&sec, "P").unwrap();

    // A newer tool added fields we do not know about.
    let mut raw: serde_json::Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    raw["futureTopLevel"] = serde_json::json!({ "keep": true });
    raw["textBoxes"] = serde_json::json!([{ "id": "t1", "text": "hi", "futureField": 42 }]);
    fs::write(&file, raw.to_string()).unwrap();

    // The UI only knows documented fields, so it sends them without extras.
    let mut edited = ws.read_page(&file).unwrap();
    edited.extra.clear();
    edited.text_boxes[0].extra.clear();
    edited.text_boxes[0].text = "hello".into();
    ws.write_page(&file, &mut edited).unwrap();

    let saved: serde_json::Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(saved["futureTopLevel"]["keep"], true);
    assert_eq!(saved["textBoxes"][0]["futureField"], 42);
    assert_eq!(saved["textBoxes"][0]["text"], "hello");
}

#[test]
fn saving_rounds_ink_and_drops_empty_text() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let sec = ws.create_section(&nb, "Sec").unwrap();
    let file = ws.create_page(&sec, "P").unwrap();

    let mut doc = ws.read_page(&file).unwrap();
    doc.strokes.push(Stroke { points: vec![1.23456, 2.34567, 0.123456, 4.0, 5.0, 7.0, 9.0], ..Stroke::default() });
    doc.strokes.push(Stroke { points: vec![1.0], ..Stroke::default() });
    doc.text_boxes.push(TextBox { text: "   ".into(), ..TextBox::default() });
    ws.write_page(&file, &mut doc).unwrap();

    let back = ws.read_page(&file).unwrap();
    assert_eq!(back.strokes.len(), 1);
    assert_eq!(back.strokes[0].points, vec![1.23, 2.35, 0.123, 4.0, 5.0, 1.0]);
    assert!(back.text_boxes.is_empty());
}

#[test]
fn manifests_order_and_append_unknown_entries() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let a = ws.create_section(&nb, "Zeta").unwrap();
    let _b = ws.create_section(&nb, "Alpha").unwrap();

    // Manifest order wins over alphabetical.
    let names: Vec<String> = ws.list_section_dirs(&nb).iter().map(|p| scribe_core::workspace::file_name(p)).collect();
    assert_eq!(names, vec!["Zeta", "Alpha"]);

    // A page dropped in by hand appears after the ordered ones.
    let p1 = ws.create_page(&a, "Second").unwrap();
    let p0 = ws.create_page(&a, "First").unwrap();
    fs::write(a.join("Dropped.json"), r#"{"title":"Dropped"}"#).unwrap();
    ws.set_page_order(&a, &[p0.clone(), p1.clone()]).unwrap();

    let titles: Vec<String> = ws.list_pages(&a).into_iter().map(|p| p.title).collect();
    assert_eq!(titles, vec!["First", "Second", "Dropped"]);
}

#[test]
fn rename_follows_title_and_deduplicates() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let sec = ws.create_section(&nb, "Sec").unwrap();
    let a = ws.create_page(&sec, "Untitled page").unwrap();
    let b = ws.create_page(&sec, "Untitled page").unwrap();
    assert!(b.ends_with("Untitled page (2).json"));

    let a2 = ws.rename_page_file(&sec, &a, "Meeting: 11/08").unwrap();
    assert!(a2.ends_with("Meeting 11 08.json"));
    assert!(!a.exists() && a2.exists());

    // A case-only rename must not grow a " (2)" suffix.
    let a3 = ws.rename_page_file(&sec, &a2, "meeting 11 08").unwrap();
    assert!(a3.ends_with("meeting 11 08.json"));

    let order = ws.read_section(&sec).page_order;
    assert_eq!(order, vec!["meeting 11 08.json", "Untitled page (2).json"]);
}

#[test]
fn moving_a_page_brings_its_images() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let from = ws.create_section(&nb, "From").unwrap();
    let to = ws.create_section(&nb, "To").unwrap();
    let page = ws.create_page(&from, "Pic").unwrap();

    let (abs, rel) = ws.new_asset_path(&from, "png").unwrap();
    fs::write(&abs, b"png").unwrap();
    let mut doc = ws.read_page(&page).unwrap();
    doc.images.push(Image { id: new_id(), x: 0.0, y: 0.0, width: 1.0, height: 1.0, file: rel.clone(), extra: Extra::new() });
    ws.write_page(&page, &mut doc).unwrap();

    let moved = ws.move_page(&page, &to).unwrap();
    assert!(moved.starts_with(&to) && !page.exists());
    assert!(to.join(&rel).is_file());
    assert!(ws.read_section(&from).page_order.is_empty());
    assert_eq!(ws.read_section(&to).page_order, vec!["Pic.json"]);
}

#[test]
fn search_finds_titles_text_and_table_cells() {
    let (_d, ws) = temp_ws();
    ws.ensure_starter().unwrap();
    let nb = ws.list_notebook_dirs()[0].clone();
    let sec = ws.list_section_dirs(&nb)[0].clone();

    let p = ws.create_page(&sec, "Groceries").unwrap();
    let mut doc = ws.read_page(&p).unwrap();
    doc.tables.push(Table { rows: vec![vec!["Kumquats".into()]], ..Table::default() });
    ws.write_page(&p, &mut doc).unwrap();

    assert_eq!(ws.search("grocer").len(), 1);
    assert_eq!(ws.search("KUMQUAT").len(), 1);
    assert_eq!(ws.search("finder").len(), 1, "welcome text is searchable");
    assert!(ws.search("   ").is_empty());
}

#[test]
fn page_listings_carry_a_text_snippet() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let sec = ws.create_section(&nb, "Sec").unwrap();
    let p = ws.create_page(&sec, "P").unwrap();
    let mut doc = ws.read_page(&p).unwrap();
    doc.text_boxes.push(TextBox { text: "Agenda\n\n  ship   the beta".into(), ..TextBox::default() });
    doc.text_boxes.push(TextBox { text: "x ".repeat(200), ..TextBox::default() });
    ws.write_page(&p, &mut doc).unwrap();

    let snippet = &ws.list_pages(&sec)[0].snippet;
    assert!(snippet.starts_with("Agenda ship the beta x x"));
    assert!(snippet.ends_with('…'));
    assert!(snippet.chars().count() <= 141);
}

#[test]
fn starter_is_created_once() {
    let (_d, ws) = temp_ws();
    assert!(ws.ensure_starter().unwrap().is_some());
    assert!(ws.ensure_starter().unwrap().is_none());
    let tree = ws.tree();
    assert_eq!(tree.len(), 1);
    assert_eq!(tree[0].name, "My Notebook");
    assert_eq!(tree[0].sections[0].name, "Quick Notes");
    assert_eq!(tree[0].sections[0].page_count, 1);
}

#[test]
fn newer_major_schema_is_refused() {
    let (d, ws) = temp_ws();
    let f = d.path().join("future.json");
    fs::write(&f, r#"{"schema":"scribe.page/2","title":"x"}"#).unwrap();
    assert!(ws.read_page(&f).unwrap_err().contains("newer Scribe"));
}

#[test]
fn names_are_safe_on_both_platforms() {
    assert_eq!(sanitize_name("a/b\\c:d"), "a b c d");
    assert_eq!(sanitize_name("  ...  "), "Untitled");
    assert_eq!(sanitize_name("CON"), "CON_");
    assert_eq!(sanitize_name(".hidden"), "hidden");
    assert_eq!(sanitize_name("trailing..."), "trailing");
    assert_eq!(sanitize_name(&"x".repeat(200)).len(), 80);
}

#[test]
fn writes_leave_no_temp_files() {
    let (_d, ws) = temp_ws();
    ws.ensure_starter().unwrap();
    let nb = &ws.list_notebook_dirs()[0];
    let leftovers = walk(nb).into_iter().filter(|p| p.to_string_lossy().ends_with(".tmp")).count();
    assert_eq!(leftovers, 0);
}

fn walk(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for e in fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(walk(&p));
        } else {
            out.push(p);
        }
    }
    out
}
