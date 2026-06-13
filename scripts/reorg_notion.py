#!/usr/bin/env python3
"""Relocate the migrated Notion/ subtree into the existing vault structure.

Relocates every file (collision-safe: never overwrites — suffixes the incoming
file with " (Notion)" on a clash), then removes the emptied Notion/ tree.
Run with --apply to actually move; default is a dry run.
"""
import sys, shutil
from pathlib import Path

VAULT = Path.home() / "OnyxVault"
APPLY = "--apply" in sys.argv

# (source prefix, destination prefix) — both vault-relative. A source that is a
# file maps to the destination file; a source dir maps each contained file to
# dest + the path below the source prefix.
MAPPINGS = [
    ("Notion/Courses/Data Science", "02 - Data Science"),
    ("Notion/Courses/Cyber Security - Networking",
     "04 - IT Infrastructure & Networking/Cyber Security - Networking"),
    ("Notion/Courses/Physics of Quantum Information.md",
     "05 - Physics/Physics of Quantum Information.md"),
    ("Notion/Finance", "07 - Business/05 - Finance"),
    ("Notion/Degree Planning", "11 - Degree Planning"),
    ("Notion/Entertainment", "Entertainment"),
    ("Notion/Work", "xProjectsx/Work"),
]


def collision_free(dest: Path) -> Path:
    """Return dest, or a ' (Notion)'-suffixed sibling if dest already exists."""
    if not dest.exists():
        return dest
    stem, suf = dest.stem, dest.suffix
    cand = dest.with_name(f"{stem} (Notion){suf}")
    n = 2
    while cand.exists():
        cand = dest.with_name(f"{stem} (Notion {n}){suf}")
        n += 1
    return cand


def main():
    moves = []          # (src_file, dest_file)
    collisions = []
    for src_rel, dst_rel in MAPPINGS:
        src = VAULT / src_rel
        dst = VAULT / dst_rel
        if not src.exists():
            print(f"!! missing source: {src_rel}")
            continue
        if src.is_file():
            files = [src]
            def dest_for(f):  # noqa: E306
                return dst
        else:
            files = sorted(p for p in src.rglob("*") if p.is_file())
            def dest_for(f, src=src, dst=dst):  # noqa: E306
                return dst / f.relative_to(src)
        for f in files:
            d = dest_for(f)
            final = collision_free(d)
            if final != d:
                collisions.append((f, final))
            moves.append((f, final))

    # Summary per destination top-level.
    from collections import Counter
    by_dst = Counter()
    for _, d in moves:
        by_dst[d.relative_to(VAULT).parts[0]] += 1
    print(f"== {'APPLY' if APPLY else 'DRY RUN'}: {len(moves)} files ==")
    for k in sorted(by_dst):
        print(f"  {by_dst[k]:4d} -> {k}/")
    print(f"  collisions (kept both, suffixed): {len(collisions)}")
    for f, d in collisions[:40]:
        print(f"    + {f.relative_to(VAULT)}  ->  {d.relative_to(VAULT)}")

    if not APPLY:
        print("\n(dry run — re-run with --apply to move)")
        return

    for src_file, dest_file in moves:
        dest_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src_file), str(dest_file))
    # Remove the now-empty Notion/ tree (only if no files remain).
    notion = VAULT / "Notion"
    leftover = [p for p in notion.rglob("*") if p.is_file()]
    if leftover:
        print(f"!! {len(leftover)} files still under Notion/ — NOT deleting:")
        for p in leftover[:20]:
            print("   ", p.relative_to(VAULT))
    else:
        shutil.rmtree(notion)
        print("removed empty Notion/ tree")


if __name__ == "__main__":
    main()
