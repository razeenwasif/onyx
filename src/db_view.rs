//! Database / table views over a folder (Notion-style).
//!
//! A "database" is just a folder: each note in it is a *row*, and the union of
//! the notes' YAML frontmatter properties are the *columns*. Two view modes:
//! a **table** (rows × property columns) and a **board** (kanban) that groups
//! the rows by a single select-like property.
//!
//! Everything here is pure data + logic (no TUI), driven entirely off the facts
//! the index already extracted (`NoteMeta.properties`). The renderer lives in
//! `ui::database` and the key handling in `dispatch`.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DbViewMode {
    Table,
    Board,
}

/// One row of the database — a single note.
#[derive(Debug, Clone)]
pub struct DbRow {
    pub path: PathBuf,
    pub name: String,
    /// property key → display value (multi-values joined with ", ").
    pub cells: Vec<(String, String)>,
}

/// Input triple for building a database view: (note path, display name, the
/// note's ordered `(property key, values)` list).
pub type RowInput = (PathBuf, String, Vec<(String, Vec<String>)>);

impl DbRow {
    pub fn cell(&self, key: &str) -> Option<&str> {
        self.cells
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}

/// Live database-view state: the folder, its computed rows/columns, plus the
/// UI state (mode, selection, sort, grouping, filter).
#[derive(Debug, Clone)]
pub struct DatabaseView {
    pub folder: PathBuf,
    pub title: String,
    pub mode: DbViewMode,
    /// Property columns, in display order (excludes the implicit Name column).
    pub columns: Vec<String>,
    pub rows: Vec<DbRow>,

    // --- table UI state ---
    /// Selected row, as an index into `visible_indices()`.
    pub selected: usize,
    /// Horizontal column-scroll offset (index into `columns`).
    pub col_offset: usize,
    /// Column to sort by; `None` sorts by Name.
    pub sort_by: Option<String>,
    pub sort_desc: bool,

    // --- board UI state ---
    /// Column the board groups by; `None` is a single "All" group.
    pub group_by: Option<String>,
    pub board_group: usize,
    pub board_card: usize,

    // --- filter (shared) ---
    pub filter: String,
    /// True while the user is typing into the filter box.
    pub filtering: bool,
}

/// Housekeeping keys we de-prioritise (push to the right / skip as group keys)
/// without hiding — keeps the feature general while keeping migration noise out
/// of the way.
fn is_housekeeping(key: &str) -> bool {
    matches!(
        key.to_ascii_lowercase().as_str(),
        "source" | "notion-url" | "notion-collection"
    )
}

/// Build the ordered column list and rows from `(path, name, properties)`
/// triples. `properties` is the note's ordered `(key, values)` list (already
/// tags-excluded by the index). Columns are ordered: real properties before
/// housekeeping, then by how many rows carry them (most common first), then by
/// first-seen order for stability.
pub fn build_rows(items: Vec<RowInput>) -> (Vec<String>, Vec<DbRow>) {
    let mut first_seen: Vec<String> = Vec::new();
    let mut freq: HashMap<String, usize> = HashMap::new();
    let mut rows: Vec<DbRow> = Vec::with_capacity(items.len());

    for (path, name, props) in items {
        let mut cells: Vec<(String, String)> = Vec::with_capacity(props.len());
        for (k, vals) in props {
            if !first_seen.iter().any(|c| c == &k) {
                first_seen.push(k.clone());
            }
            *freq.entry(k.clone()).or_insert(0) += 1;
            cells.push((k, vals.join(", ")));
        }
        rows.push(DbRow { path, name, cells });
    }

    let mut columns = first_seen.clone();
    let pos = |k: &str| first_seen.iter().position(|c| c == k).unwrap_or(usize::MAX);
    columns.sort_by(|a, b| {
        is_housekeeping(a)
            .cmp(&is_housekeeping(b))
            .then_with(|| freq.get(b).unwrap_or(&0).cmp(freq.get(a).unwrap_or(&0)))
            .then_with(|| pos(a).cmp(&pos(b)))
    });
    (columns, rows)
}

/// Pick a default board grouping column: a "select-like" property — single
/// value per row, a small set of distinct values, decent coverage. Returns
/// `None` when nothing is a good fit.
pub fn pick_group_by(columns: &[String], rows: &[DbRow]) -> Option<String> {
    let n = rows.len();
    if n == 0 {
        return None;
    }
    let mut best: Option<(String, f64)> = None;
    for col in columns {
        if is_housekeeping(col) {
            continue;
        }
        let mut distinct: HashSet<&str> = HashSet::new();
        let mut have = 0usize;
        let mut multi = false;
        let mut maxlen = 0usize;
        for r in rows {
            if let Some(v) = r.cell(col) {
                if v.is_empty() {
                    continue;
                }
                have += 1;
                if v.contains(", ") {
                    multi = true;
                }
                maxlen = maxlen.max(v.chars().count());
                distinct.insert(v);
            }
        }
        let d = distinct.len();
        if multi || maxlen > 24 || !(2..=12).contains(&d) {
            continue;
        }
        if (have as f64) < (n as f64) * 0.5 {
            continue;
        }
        // Prefer high coverage, then fewer distinct values.
        let score = have as f64 / n as f64 - d as f64 * 0.02;
        if best.as_ref().map(|(_, s)| score > *s).unwrap_or(true) {
            best = Some((col.clone(), score));
        }
    }
    best.map(|(c, _)| c)
}

/// Compare two cell strings: numeric when both parse as numbers, else
/// case-insensitive lexicographic. Empty values always sort last.
fn cmp_cells(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (a.is_empty(), b.is_empty()) {
        (true, true) => return Ordering::Equal,
        (true, false) => return Ordering::Greater,
        (false, true) => return Ordering::Less,
        _ => {}
    }
    match (a.parse::<f64>(), b.parse::<f64>()) {
        (Ok(x), Ok(y)) => x.partial_cmp(&y).unwrap_or(Ordering::Equal),
        _ => a.to_lowercase().cmp(&b.to_lowercase()),
    }
}

impl DatabaseView {
    /// Row indices (into `self.rows`) after applying the filter, in sort order.
    pub fn visible_indices(&self) -> Vec<usize> {
        let q = self.filter.to_lowercase();
        let mut idx: Vec<usize> = (0..self.rows.len())
            .filter(|&i| {
                if q.is_empty() {
                    return true;
                }
                let r = &self.rows[i];
                r.name.to_lowercase().contains(&q)
                    || r.cells.iter().any(|(_, v)| v.to_lowercase().contains(&q))
            })
            .collect();

        idx.sort_by(|&a, &b| {
            let (ra, rb) = (&self.rows[a], &self.rows[b]);
            let ord = match &self.sort_by {
                None => cmp_cells(&ra.name, &rb.name),
                Some(k) => cmp_cells(ra.cell(k).unwrap_or(""), rb.cell(k).unwrap_or("")),
            };
            // Empty-last semantics are encoded in cmp_cells and must not flip on
            // reverse; only flip when both sides are present.
            let both_present = match &self.sort_by {
                None => !ra.name.is_empty() && !rb.name.is_empty(),
                Some(k) => {
                    !ra.cell(k).unwrap_or("").is_empty() && !rb.cell(k).unwrap_or("").is_empty()
                }
            };
            if self.sort_desc && both_present {
                ord.reverse()
            } else {
                ord
            }
        });
        idx
    }

    /// Board groups: `(label, row indices)` for the current `group_by`, applying
    /// the filter. Rows with no value land in a trailing "—" group. With no
    /// `group_by`, a single "All" group holds every visible row.
    pub fn groups(&self) -> Vec<(String, Vec<usize>)> {
        let Some(key) = self.group_by.clone() else {
            return vec![("All".to_string(), self.visible_indices())];
        };
        let mut order: Vec<String> = Vec::new();
        let mut map: HashMap<String, Vec<usize>> = HashMap::new();
        for i in self.visible_indices() {
            let v = self.rows[i]
                .cell(&key)
                .filter(|s| !s.is_empty())
                .unwrap_or("—")
                .to_string();
            if !map.contains_key(&v) {
                order.push(v.clone());
            }
            map.entry(v).or_default().push(i);
        }
        order.sort_by(|a, b| {
            (a == "—")
                .cmp(&(b == "—"))
                .then_with(|| cmp_cells(a, b))
        });
        order
            .into_iter()
            .map(|g| {
                let v = map.remove(&g).unwrap_or_default();
                (g, v)
            })
            .collect()
    }

    /// Path of the currently-selected row/card, if any.
    pub fn selected_path(&self) -> Option<PathBuf> {
        match self.mode {
            DbViewMode::Table => {
                let vis = self.visible_indices();
                vis.get(self.selected).map(|&i| self.rows[i].path.clone())
            }
            DbViewMode::Board => {
                let groups = self.groups();
                groups
                    .get(self.board_group)
                    .and_then(|(_, idxs)| idxs.get(self.board_card))
                    .map(|&i| self.rows[i].path.clone())
            }
        }
    }

    /// Keep all selection indices within bounds (after filter/sort/group change).
    pub fn clamp(&mut self) {
        let vis = self.visible_indices().len();
        if self.selected >= vis {
            self.selected = vis.saturating_sub(1);
        }
        let groups = self.groups();
        if self.board_group >= groups.len() {
            self.board_group = groups.len().saturating_sub(1);
        }
        let cards = groups.get(self.board_group).map(|(_, i)| i.len()).unwrap_or(0);
        if self.board_card >= cards {
            self.board_card = cards.saturating_sub(1);
        }
        if self.col_offset >= self.columns.len() {
            self.col_offset = self.columns.len().saturating_sub(1);
        }
    }

    /// Move the row/card selection (no wrap).
    pub fn move_sel(&mut self, delta: i64) {
        match self.mode {
            DbViewMode::Table => {
                let n = self.visible_indices().len();
                self.selected = step(self.selected, delta, n);
            }
            DbViewMode::Board => {
                let groups = self.groups();
                let n = groups.get(self.board_group).map(|(_, i)| i.len()).unwrap_or(0);
                self.board_card = step(self.board_card, delta, n);
            }
        }
    }

    /// Move horizontally: scroll columns (table) or switch group (board).
    pub fn move_horiz(&mut self, delta: i64) {
        match self.mode {
            DbViewMode::Table => {
                self.col_offset = step(self.col_offset, delta, self.columns.len());
            }
            DbViewMode::Board => {
                let n = self.groups().len();
                self.board_group = step(self.board_group, delta, n);
                let cards = self
                    .groups()
                    .get(self.board_group)
                    .map(|(_, i)| i.len())
                    .unwrap_or(0);
                if self.board_card >= cards {
                    self.board_card = cards.saturating_sub(1);
                }
            }
        }
    }

    pub fn goto_first(&mut self) {
        match self.mode {
            DbViewMode::Table => self.selected = 0,
            DbViewMode::Board => self.board_card = 0,
        }
    }

    pub fn goto_last(&mut self) {
        match self.mode {
            DbViewMode::Table => {
                self.selected = self.visible_indices().len().saturating_sub(1)
            }
            DbViewMode::Board => {
                let n = self
                    .groups()
                    .get(self.board_group)
                    .map(|(_, i)| i.len())
                    .unwrap_or(0);
                self.board_card = n.saturating_sub(1);
            }
        }
    }

    pub fn toggle_mode(&mut self) {
        self.mode = match self.mode {
            DbViewMode::Table => DbViewMode::Board,
            DbViewMode::Board => DbViewMode::Table,
        };
        if self.mode == DbViewMode::Board && self.group_by.is_none() {
            self.group_by = pick_group_by(&self.columns, &self.rows);
        }
        self.board_group = 0;
        self.board_card = 0;
        self.selected = 0;
    }

    /// Cycle the table sort column: Name → each property → Name.
    pub fn cycle_sort(&mut self) {
        let len = self.columns.len() + 1;
        let cur = match &self.sort_by {
            None => 0,
            Some(c) => self.columns.iter().position(|x| x == c).map(|i| i + 1).unwrap_or(0),
        };
        let next = (cur + 1) % len;
        self.sort_by = (next != 0).then(|| self.columns[next - 1].clone());
        self.clamp();
    }

    /// Cycle the board grouping column: All → each property → All.
    pub fn cycle_group(&mut self, forward: bool) {
        let len = self.columns.len() + 1;
        let cur = match &self.group_by {
            None => 0,
            Some(c) => self.columns.iter().position(|x| x == c).map(|i| i + 1).unwrap_or(0),
        };
        let next = if forward {
            (cur + 1) % len
        } else {
            (cur + len - 1) % len
        };
        self.group_by = (next != 0).then(|| self.columns[next - 1].clone());
        self.board_group = 0;
        self.board_card = 0;
    }
}

/// Step `cur` by `delta`, clamped to `[0, n-1]` (no wrap). Returns 0 when empty.
fn step(cur: usize, delta: i64, n: usize) -> usize {
    if n == 0 {
        return 0;
    }
    (cur as i64 + delta).clamp(0, n as i64 - 1) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(path: &str, name: &str, props: &[(&str, &str)]) -> (PathBuf, String, Vec<(String, Vec<String>)>) {
        (
            PathBuf::from(path),
            name.to_string(),
            props
                .iter()
                .map(|(k, v)| (k.to_string(), vec![v.to_string()]))
                .collect(),
        )
    }

    fn sample() -> DatabaseView {
        let (columns, rows) = build_rows(vec![
            row("e/Claude.md", "Claude", &[("source", "notion"), ("Type", "Wants"), ("Amount", "20")]),
            row("e/Rent.md", "Rent", &[("source", "notion"), ("Type", "Needs"), ("Amount", "900")]),
            row("e/Spotify.md", "Spotify", &[("source", "notion"), ("Type", "Wants"), ("Amount", "12")]),
            row("e/Savings.md", "Savings", &[("source", "notion"), ("Type", "Savings"), ("Amount", "300")]),
        ]);
        DatabaseView {
            folder: PathBuf::from("e"),
            title: "Expenses".into(),
            mode: DbViewMode::Table,
            columns,
            rows,
            selected: 0,
            col_offset: 0,
            sort_by: None,
            sort_desc: false,
            group_by: None,
            board_group: 0,
            board_card: 0,
            filter: String::new(),
            filtering: false,
        }
    }

    #[test]
    fn columns_put_housekeeping_last_and_common_first() {
        let v = sample();
        // Type and Amount appear on every row (freq 4) and are real; source is
        // housekeeping → pushed last despite also appearing on every row.
        assert_eq!(v.columns, vec!["Type", "Amount", "source"]);
    }

    #[test]
    fn sort_numeric_and_by_name() {
        let mut v = sample();
        // Default sort is by Name (alphabetical).
        let names: Vec<&str> = v
            .visible_indices()
            .iter()
            .map(|&i| v.rows[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["Claude", "Rent", "Savings", "Spotify"]);

        // Sort by Amount ascending → numeric, not lexicographic ("12" < "900").
        v.sort_by = Some("Amount".into());
        let amounts: Vec<&str> = v
            .visible_indices()
            .iter()
            .map(|&i| v.rows[i].cell("Amount").unwrap())
            .collect();
        assert_eq!(amounts, vec!["12", "20", "300", "900"]);

        v.sort_desc = true;
        let amounts: Vec<&str> = v
            .visible_indices()
            .iter()
            .map(|&i| v.rows[i].cell("Amount").unwrap())
            .collect();
        assert_eq!(amounts, vec!["900", "300", "20", "12"]);
    }

    #[test]
    fn filter_matches_name_and_cells() {
        let mut v = sample();
        v.filter = "needs".into(); // matches Rent's Type cell
        let names: Vec<&str> = v
            .visible_indices()
            .iter()
            .map(|&i| v.rows[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["Rent"]);

        v.filter = "spot".into(); // matches a name
        let names: Vec<&str> = v
            .visible_indices()
            .iter()
            .map(|&i| v.rows[i].name.as_str())
            .collect();
        assert_eq!(names, vec!["Spotify"]);
    }

    #[test]
    fn picks_select_like_group_by() {
        let v = sample();
        // Type (3 distinct: Needs/Wants/Savings) is the select-like column;
        // Amount has 4 distinct numeric values but is also eligible — Type wins
        // on fewer distinct values at equal coverage.
        assert_eq!(pick_group_by(&v.columns, &v.rows).as_deref(), Some("Type"));
    }

    #[test]
    fn board_groups_by_value() {
        let mut v = sample();
        v.group_by = Some("Type".into());
        let groups = v.groups();
        let labels: Vec<&str> = groups.iter().map(|(l, _)| l.as_str()).collect();
        assert_eq!(labels, vec!["Needs", "Savings", "Wants"]);
        // The Wants group has Claude + Spotify.
        let wants = &groups.iter().find(|(l, _)| l == "Wants").unwrap().1;
        let mut names: Vec<&str> = wants.iter().map(|&i| v.rows[i].name.as_str()).collect();
        names.sort();
        assert_eq!(names, vec!["Claude", "Spotify"]);
    }

    #[test]
    fn navigation_clamps_without_wrapping() {
        let mut v = sample();
        v.move_sel(-1); // already at top
        assert_eq!(v.selected, 0);
        v.move_sel(100); // past the end
        assert_eq!(v.selected, 3);
        v.goto_first();
        assert_eq!(v.selected, 0);
    }

    #[test]
    fn cycle_sort_round_trips_through_columns() {
        let mut v = sample();
        assert_eq!(v.sort_by, None);
        v.cycle_sort();
        assert_eq!(v.sort_by.as_deref(), Some("Type"));
        v.cycle_sort();
        assert_eq!(v.sort_by.as_deref(), Some("Amount"));
        v.cycle_sort();
        assert_eq!(v.sort_by.as_deref(), Some("source"));
        v.cycle_sort();
        assert_eq!(v.sort_by, None); // back to Name
    }

    #[test]
    fn empty_values_sort_last_both_directions() {
        let (columns, rows) = build_rows(vec![
            row("a.md", "A", &[("Grade", "P")]),
            row("b.md", "B", &[]), // no Grade
            row("c.md", "C", &[("Grade", "D")]),
        ]);
        let mut v = DatabaseView {
            folder: PathBuf::from("."),
            title: "x".into(),
            mode: DbViewMode::Table,
            columns,
            rows,
            selected: 0,
            col_offset: 0,
            sort_by: Some("Grade".into()),
            sort_desc: false,
            group_by: None,
            board_group: 0,
            board_card: 0,
            filter: String::new(),
            filtering: false,
        };
        let order: Vec<&str> = v.visible_indices().iter().map(|&i| v.rows[i].name.as_str()).collect();
        assert_eq!(order, vec!["C", "A", "B"]); // D < P, empty (B) last
        v.sort_desc = true;
        let order: Vec<&str> = v.visible_indices().iter().map(|&i| v.rows[i].name.as_str()).collect();
        assert_eq!(order, vec!["A", "C", "B"]); // reversed, empty still last
    }
}
