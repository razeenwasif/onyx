//! File tree of the vault — folders and `.md` files (plus a few extras).

use std::cmp::Ordering;
use std::path::{Path, PathBuf};

use ignore::WalkBuilder;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeNode {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub depth: usize,
    pub children: Vec<TreeNode>,
}

impl TreeNode {
    pub fn leaf(path: PathBuf, depth: usize) -> Self {
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string_lossy().into_owned());
        Self {
            path,
            name,
            is_dir: false,
            depth,
            children: Vec::new(),
        }
    }

    pub fn dir(path: PathBuf, depth: usize) -> Self {
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string_lossy().into_owned());
        Self {
            path,
            name,
            is_dir: true,
            depth,
            children: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct FileTree {
    pub root: TreeNode,
    /// All notes (markdown files) in the vault, sorted by path.
    pub notes: Vec<PathBuf>,
}

impl FileTree {
    pub fn scan(root: &Path) -> Self {
        let mut all: Vec<PathBuf> = Vec::new();
        let walker = WalkBuilder::new(root)
            .hidden(true)
            .git_ignore(true)
            .git_exclude(true)
            .require_git(false)
            .follow_links(false)
            .build();
        for entry in walker.flatten() {
            let path = entry.path();
            if path == root {
                continue;
            }
            if entry.file_type().is_some_and(|t| t.is_file())
                && is_note(path) {
                    all.push(path.to_path_buf());
                }
        }
        all.sort();

        // Build tree by grouping under common ancestors.
        let mut root_node = TreeNode::dir(root.to_path_buf(), 0);
        for note in &all {
            insert(&mut root_node, root, note);
        }
        sort_tree(&mut root_node);

        Self {
            root: root_node,
            notes: all,
        }
    }

    pub fn contains(&self, path: &Path) -> bool {
        self.notes.iter().any(|p| p == path)
    }

    /// Flatten the tree to a linear list of (depth, node) for rendering.
    pub fn flatten<'a>(&'a self, expanded: &dyn ExpansionSet) -> Vec<&'a TreeNode> {
        let mut out = Vec::new();
        for child in &self.root.children {
            push_node(child, expanded, &mut out);
        }
        out
    }
}

pub trait ExpansionSet {
    fn is_expanded(&self, path: &Path) -> bool;
}

fn push_node<'a>(node: &'a TreeNode, exp: &dyn ExpansionSet, out: &mut Vec<&'a TreeNode>) {
    out.push(node);
    if node.is_dir && exp.is_expanded(&node.path) {
        for child in &node.children {
            push_node(child, exp, out);
        }
    }
}

fn is_note(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|s| s.to_str()),
        Some("md") | Some("markdown") | Some("mdx")
    )
}

fn insert(root: &mut TreeNode, vault_root: &Path, note: &Path) {
    let rel = match note.strip_prefix(vault_root) {
        Ok(p) => p,
        Err(_) => return,
    };
    let components: Vec<_> = rel.components().collect();
    let mut current = root;
    let mut acc = vault_root.to_path_buf();
    for (i, comp) in components.iter().enumerate() {
        acc.push(comp.as_os_str());
        let is_last = i + 1 == components.len();
        if is_last {
            current
                .children
                .push(TreeNode::leaf(acc.clone(), current.depth + 1));
        } else {
            // Find or create subdir.
            let idx = current
                .children
                .iter()
                .position(|n| n.is_dir && n.path == acc);
            let next_idx = match idx {
                Some(i) => i,
                None => {
                    current
                        .children
                        .push(TreeNode::dir(acc.clone(), current.depth + 1));
                    current.children.len() - 1
                }
            };
            current = &mut current.children[next_idx];
        }
    }
}

fn sort_tree(node: &mut TreeNode) {
    node.children.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
        _ => a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase()),
    });
    for c in &mut node.children {
        sort_tree(c);
    }
}
