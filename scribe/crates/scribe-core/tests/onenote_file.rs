use scribe_core::onenote_file::{find_sections, visible_text};
use std::fs;

#[test]
fn sections_are_found_with_their_notebook_and_groups() {
    let dir = tempfile::tempdir().unwrap();
    let nb = dir.path().join("Documents").join("Razeen's Notebook");
    fs::create_dir_all(nb.join("Year 2").join("Physics")).unwrap();
    fs::create_dir_all(nb.join("OneNote_RecycleBin")).unwrap();
    fs::write(nb.join("OneNote_RecycleBin").join("Open Notebook.onetoc2"), b"").unwrap();
    fs::write(nb.join("OneNote_RecycleBin").join("Algorithms.one"), b"").unwrap();
    fs::write(nb.join("Open Notebook.onetoc2"), b"").unwrap();
    fs::write(nb.join("Calculus.one"), b"").unwrap();
    fs::write(nb.join("Year 2").join("Physics").join("Waves.one"), b"").unwrap();
    fs::write(nb.join("OneNote_RecycleBin").join("OneNote_DeletedPages.one"), b"").unwrap();
    fs::write(nb.join("notes.txt"), b"").unwrap();

    let found = find_sections(dir.path());
    let names: Vec<(String, String, bool)> = found.iter().map(|s| (s.notebook.clone(), s.scribe_name(), s.deleted)).collect();
    assert_eq!(
        names,
        vec![
            ("Razeen's Notebook".to_string(), "Calculus".to_string(), false),
            ("Razeen's Notebook".to_string(), "Year 2 – Physics – Waves".to_string(), false),
            // Deleted in OneNote: still the notebook's, after the rest; the
            // record of deleted pages isn't a section.
            ("Razeen's Notebook".to_string(), "Algorithms".to_string(), true),
        ]
    );
}

#[test]
fn a_single_section_file_is_its_own_list() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("Lectures.one");
    fs::write(&file, b"").unwrap();
    let found = find_sections(&file);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].name, "Lectures");
}

#[test]
fn hidden_link_addresses_are_dropped_from_text() {
    let raw = "See \u{fddf}HYPERLINK \"https://example.com/a b\"the docs\u{b}next line";
    assert_eq!(visible_text(raw), "See the docs\nnext line");
    assert_eq!(visible_text("plain"), "plain");
}
