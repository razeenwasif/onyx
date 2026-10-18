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
fn bookmarks_survive_saves_and_do_not_count_as_edits() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("Uni").unwrap();
    let sec = ws.create_section(&nb, "Lectures").unwrap();
    let file = ws.create_page(&sec, "Week 1").unwrap();
    let mut doc = ws.read_page(&file).unwrap();
    ws.write_page(&file, &mut doc).unwrap();
    let before = ws.read_page(&file).unwrap().modified;

    ws.set_bookmarked(&file, true).unwrap();
    let listed = &ws.list_pages(&sec)[0];
    assert!(listed.bookmarked);
    assert_eq!(listed.page_id, doc.id);
    assert_eq!(ws.read_page(&file).unwrap().modified, before);

    // An app that doesn't know the field saves the page: the star stays.
    let mut edited = ws.read_page(&file).unwrap();
    edited.extra.remove("bookmarked");
    ws.write_page(&file, &mut edited).unwrap();
    assert!(ws.list_pages(&sec)[0].bookmarked);

    ws.set_bookmarked(&file, false).unwrap();
    assert!(!ws.list_pages(&sec)[0].bookmarked);
    assert!(!fs::read_to_string(&file).unwrap().contains("bookmarked"));
}

#[test]
fn library_covers_recents_and_colours() {
    use std::time::{Duration, SystemTime};
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("Uni").unwrap();
    let sec = ws.create_section(&nb, "Lectures").unwrap();
    let first = ws.create_page(&sec, "Week 1").unwrap();
    let second = ws.create_page(&sec, "Week 2").unwrap();
    let other = ws.create_section(&nb, "Labs").unwrap();
    let lab = ws.create_page(&other, "Lab 1").unwrap();

    // Week 1 edited last, then Lab 1, then Week 2.
    let age = |f: &std::path::Path, secs: u64| {
        let t = SystemTime::now() - Duration::from_secs(secs);
        fs::File::options().write(true).open(f).unwrap().set_modified(t).unwrap();
    };
    age(&second, 300);
    age(&lab, 200);
    age(&first, 100);

    let tree = ws.tree();
    let lectures = tree[0].sections.iter().find(|s| s.name == "Lectures").unwrap();
    assert_eq!(lectures.cover.as_ref().unwrap().title, "Week 1");
    assert_eq!(lectures.cover_choice, "first");
    assert!(lectures.modified > 0.0);
    assert_eq!(tree[0].modified, lectures.modified);

    ws.set_section_cover(&sec, "latest").unwrap();
    age(&second, 10);
    let tree = ws.tree();
    let lectures = tree[0].sections.iter().find(|s| s.name == "Lectures").unwrap();
    assert_eq!(lectures.cover.as_ref().unwrap().title, "Week 2");
    assert_eq!(lectures.cover_choice, "latest");

    let recent: Vec<String> = ws.recent_pages(2).into_iter().map(|p| p.title).collect();
    assert_eq!(recent, ["Week 2", "Week 1"]);

    ws.set_notebook_color(&nb, "#C7B6F2").unwrap();
    ws.set_section_color(&other, "#A9D8C3").unwrap();
    let tree = ws.tree();
    assert_eq!(tree[0].color, "#C7B6F2");
    assert_eq!(tree[0].sections.iter().find(|s| s.name == "Labs").unwrap().color, "#A9D8C3");

    // An empty notebook has no cover.
    let empty = ws.create_section(&nb, "Empty").unwrap();
    let tree = ws.tree();
    let e = tree[0].sections.iter().find(|s| s.path == empty.to_string_lossy()).unwrap();
    assert!(e.cover.is_none());
    assert_eq!(e.modified, 0.0);
}

#[test]
fn page_layouts_report_extent_and_blankness() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("Uni").unwrap();
    let sec = ws.create_section(&nb, "Lectures").unwrap();
    let empty = ws.create_page(&sec, "Empty").unwrap();
    let inked = ws.create_page(&sec, "Inked").unwrap();
    let mut doc = ws.read_page(&inked).unwrap();
    doc.strokes = vec![Stroke { width: 4.0, height: 4.0, points: vec![10.0, 20.0, 0.5, 900.0, 1500.0, 0.5], ..Stroke::default() }];
    ws.write_page(&inked, &mut doc).unwrap();

    let layouts = ws.page_layouts(&sec);
    assert_eq!(layouts.len(), 2);
    assert_eq!(layouts[0].path, empty.to_string_lossy());
    assert!(layouts[0].blank);
    assert!(!layouts[1].blank);
    assert_eq!(layouts[1].page_id, doc.id);
    assert_eq!(layouts[1].content_width, 902.0);
    assert_eq!(layouts[1].content_height, 1502.0);
}

#[test]
fn new_pages_take_the_notebooks_paper() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("Uni").unwrap();
    let sec = ws.create_section(&nb, "Maths").unwrap();
    let before = ws.create_page(&sec, "Ruled").unwrap();
    ws.set_section_paper(&sec, "grid", 24.0).unwrap();
    let after = ws.create_page(&sec, "Grid").unwrap();
    assert_eq!(ws.read_page(&before).unwrap().background.kind, "ruled");
    let grid = ws.read_page(&after).unwrap().background;
    assert_eq!((grid.kind.as_str(), grid.spacing), ("grid", 24.0));
    // The setting doesn't disturb the page order.
    assert_eq!(ws.list_pages(&sec).len(), 2);
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

#[test]
fn a_notebook_moves_to_another_folder_with_its_pages() {
    let (_tmp, ws) = temp_ws();
    let maths = ws.create_notebook("Maths").unwrap();
    let physics = ws.create_notebook("Physics").unwrap();
    let calc = ws.create_section(&maths, "Calculus").unwrap();
    let page = ws.create_page(&calc, "Limits").unwrap();
    // The OneNote import's record points at the page.
    let rel = page.strip_prefix(&ws.root).unwrap().to_string_lossy().into_owned();
    fs::create_dir_all(ws.root.join(".scribe")).unwrap();
    fs::write(ws.root.join(".scribe/onenote-import.json"), format!(r#"{{"page-1": "{rel}"}}"#)).unwrap();

    let moved = ws.move_section(&calc, &physics).unwrap();
    assert_eq!(moved, physics.join("Calculus"));
    assert!(!calc.exists());
    assert_eq!(ws.list_page_files(&moved).len(), 1);
    assert!(ws.list_section_dirs(&maths).is_empty());
    assert_eq!(ws.list_section_dirs(&physics), vec![moved.clone()]);
    let record = fs::read_to_string(ws.root.join(".scribe/onenote-import.json")).unwrap();
    assert!(record.contains("Physics/Calculus/"), "{record}");

    // A folder that already has a notebook by that name gets "(2)".
    let other = ws.create_section(&maths, "Calculus").unwrap();
    assert_eq!(ws.move_section(&other, &physics).unwrap(), physics.join("Calculus (2)"));
    // Moving into its own folder changes nothing.
    assert_eq!(ws.move_section(&moved, &physics).unwrap(), moved);
}

#[test]
fn packed_ink_comes_back_exactly() {
    let (_tmp, ws) = temp_ws();
    let nb = ws.create_notebook("N").unwrap();
    let sec = ws.create_section(&nb, "S").unwrap();
    let file = ws.create_page(&sec, "P").unwrap();
    let mut doc = ws.read_page(&file).unwrap();
    doc.strokes.push(Stroke { points: vec![12345.67, 0.01, 0.512, 9.99, 20000.25, 1.0], ..Stroke::default() });
    doc.strokes[0].extra.insert("windowsOnly".into(), "kept".into());
    ws.write_page(&file, &mut doc).unwrap();

    // What the apps get, and send back.
    let mut packed = ws.read_page(&file).unwrap();
    scribe_core::model::pack_points(&mut packed);
    assert!(packed.strokes[0].points.is_empty());
    let wire = serde_json::to_string(&packed).unwrap();
    let mut back: PageDoc = serde_json::from_str(&wire).unwrap();
    scribe_core::model::unpack_points(&mut back);
    assert_eq!(back.strokes[0].points, vec![12345.67, 0.01, 0.512, 9.99, 20000.25, 1.0]);

    // The app drops fields it doesn't know; a save keeps them anyway.
    back.strokes[0].extra.clear();
    ws.write_page(&file, &mut back).unwrap();
    let on_disk = fs::read_to_string(&file).unwrap();
    assert!(on_disk.contains("windowsOnly"), "{on_disk}");
    assert!(!on_disk.contains("pointsPacked"));
    // Pages are saved on one line.
    assert_eq!(on_disk.trim_end().lines().count(), 1);
}

#[test]
fn imported_ink_is_thinned_once_and_keeps_its_place() {
    let (_tmp, ws) = temp_ws();
    let nb = ws.create_notebook("N").unwrap();
    let sec = ws.create_section(&nb, "S").unwrap();
    let file = ws.create_page(&sec, "From OneNote").unwrap();
    let mut doc = ws.read_page(&file).unwrap();
    doc.source = Some(Source { app: "onenote".into(), id: Some("x".into()), imported_at: now_stamp(), extra: Default::default() });
    // A straight line recorded every unit, with one corner: thinning keeps
    // the ends and the corner.
    let mut points = Vec::new();
    for i in 0..=100 { points.extend([i as f64, 0.0, 0.6]); }
    for i in 1..=100 { points.extend([100.0, i as f64, 0.6]); }
    doc.strokes.push(Stroke { width: 2.8, points, ..Stroke::default() });
    ws.write_page(&file, &mut doc).unwrap();
    let stamp = fs::read_to_string(&file).unwrap();
    let modified = ws.read_page(&file).unwrap().modified;
    let mtime = fs::metadata(&file).unwrap().modified().unwrap();

    assert_eq!(ws.thin_imported_pages(10, None), 1);
    let thinned = ws.read_page(&file).unwrap();
    assert_eq!(thinned.strokes[0].points, vec![0.0, 0.0, 0.6, 100.0, 0.0, 0.6, 100.0, 100.0, 0.6]);
    assert_eq!(thinned.modified, modified);
    assert_eq!(fs::metadata(&file).unwrap().modified().unwrap(), mtime);
    assert_ne!(fs::read_to_string(&file).unwrap(), stamp);
    // Done once.
    assert_eq!(ws.thin_imported_pages(10, None), 0);
}
