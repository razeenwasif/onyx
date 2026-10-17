use scribe_core::model::*;
use scribe_core::workspace::{parse_stamp, path_str, Workspace};

fn temp_ws() -> (tempfile::TempDir, Workspace) {
    let dir = tempfile::tempdir().unwrap();
    let ws = Workspace::open(dir.path().join("Scribe Notebooks")).unwrap();
    (dir, ws)
}

/// A page with one stroke, written; returns its path, id and modified stamp.
fn inked_page(ws: &Workspace, title: &str) -> (std::path::PathBuf, String, f64) {
    let nb = ws.list_notebook_dirs().first().cloned().unwrap_or_else(|| ws.create_notebook("NB").unwrap());
    let sec = ws.list_section_dirs(&nb).first().cloned().unwrap_or_else(|| ws.create_section(&nb, "Sec").unwrap());
    let file = ws.create_page(&sec, title).unwrap();
    let mut doc = ws.read_page(&file).unwrap();
    doc.strokes.push(Stroke { points: vec![1.0, 2.0, 0.5, 30.0, 40.0, 0.5], ..Stroke::default() });
    ws.write_page(&file, &mut doc).unwrap();
    (file, doc.id.clone(), parse_stamp(Some(&doc.modified)))
}

#[test]
fn inked_pages_are_pending_until_read() {
    let (_d, ws) = temp_ws();
    let (file, id, modified) = inked_page(&ws, "Lecture");

    let pending = ws.ink_pending();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].path, path_str(&file));
    assert_eq!(pending[0].id, id);
    assert_eq!(pending[0].modified, modified);

    ws.set_ink_text(&id, "Fourier series", modified).unwrap();
    assert!(ws.ink_pending().is_empty());
}

#[test]
fn pages_without_ink_are_never_pending() {
    let (_d, ws) = temp_ws();
    let nb = ws.create_notebook("NB").unwrap();
    let sec = ws.create_section(&nb, "Sec").unwrap();
    ws.create_page(&sec, "Typed only").unwrap();
    assert!(ws.ink_pending().is_empty());
}

#[test]
fn editing_a_page_makes_its_ink_pending_again() {
    let (_d, ws) = temp_ws();
    let (file, id, modified) = inked_page(&ws, "Lecture");
    ws.set_ink_text(&id, "first draft", modified).unwrap();

    // Re-saving moves the stamp on.
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let mut doc = ws.read_page(&file).unwrap();
    ws.write_page(&file, &mut doc).unwrap();
    assert_eq!(ws.ink_pending().len(), 1);
}

#[test]
fn search_finds_handwriting_and_previews_it() {
    let (_d, ws) = temp_ws();
    let (file, id, modified) = inked_page(&ws, "Lecture 3");
    ws.set_ink_text(&id, "Laplace transform\nworked example", modified).unwrap();

    let hits = ws.search("laplace");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].path, path_str(&file));
    assert!(hits[0].snippet.contains("Laplace"), "snippet shows the handwriting: {}", hits[0].snippet);
    assert!(ws.search("eigenvalue").is_empty());
}

#[test]
fn empty_text_clears_the_entry() {
    let (_d, ws) = temp_ws();
    let (_, id, modified) = inked_page(&ws, "Sketch");
    ws.set_ink_text(&id, "arrow", modified).unwrap();
    ws.set_ink_text(&id, "   ", modified).unwrap();
    assert!(ws.ink_index().pages.is_empty());
    assert!(ws.search("arrow").is_empty());
}

#[test]
fn the_index_lives_outside_the_notebooks() {
    let (_d, ws) = temp_ws();
    let (_, id, modified) = inked_page(&ws, "Lecture");
    ws.set_ink_text(&id, "notes", modified).unwrap();
    assert!(ws.ink_index_path().exists());
    // It doesn't turn up as a notebook, section or page.
    assert_eq!(ws.list_notebook_dirs().len(), 1);
}

/// A page whose background is a PDF in the section's assets/ folder.
fn pdf_page(ws: &Workspace) -> (std::path::PathBuf, std::path::PathBuf) {
    let nb = ws.create_notebook("Imported").unwrap();
    let sec = ws.create_section(&nb, "Lecture slides").unwrap();
    std::fs::create_dir_all(sec.join("assets")).unwrap();
    std::fs::write(sec.join("assets/slides.pdf"), b"%PDF-1.4 stand-in").unwrap();
    let file = ws.create_page(&sec, "Page 1").unwrap();
    let mut doc = ws.read_page(&file).unwrap();
    doc.background.kind = "pdf".into();
    doc.background.extra.insert("asset".into(), "assets/slides.pdf".into());
    doc.background.extra.insert("pdfPage".into(), 0.into());
    ws.write_page(&file, &mut doc).unwrap();
    (file, sec)
}

#[test]
fn pdf_pages_are_read_even_without_ink() {
    let (_d, ws) = temp_ws();
    let (file, _) = pdf_page(&ws);
    let pending = ws.ink_pending();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].path, path_str(&file));
}

#[test]
fn moving_a_pdf_page_brings_its_pdf() {
    let (_d, ws) = temp_ws();
    let (file, from) = pdf_page(&ws);
    let nb = from.parent().unwrap().to_path_buf();
    let to = ws.create_section(&nb, "Elsewhere").unwrap();
    let moved = ws.move_page(&file, &to).unwrap();
    assert!(to.join("assets/slides.pdf").is_file(), "the PDF travels with the page");
    let doc = ws.read_page(&moved).unwrap();
    assert_eq!(doc.background.kind, "pdf");
    assert_eq!(doc.background.extra.get("asset").and_then(|v| v.as_str()), Some("assets/slides.pdf"));
}
