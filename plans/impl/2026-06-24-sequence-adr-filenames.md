# Plan: sequence ADR filenames with a per-side number prefix

## Context

ADR files are named `YYYY-MM-DD-{slug}.md`. The date does not sequence ADRs
created on the same day (e.g. four of the seven share a date), so reading the
folder gives no reliable decision order. We are switching to
`{seq}-YYYY-MM-DD-{slug}.md`, where `{seq}` is a two-digit, zero-padded sequence
number assigned **per side** (each side's `docs/design/` restarts at `01`). The
date stays for human readability; `{seq}` carries the ordering and disambiguates
same-day decisions.

Decisions already made (with the user):
- **Per-side numbering** -- `app/docs/design/` and `raspi/docs/design/` each start
  at `01`. Sequence = git creation order within that folder.
- **Zero-padded two digits** -- `01`, `02`, ... (lexical sort matches numeric up
  to 99).

This touches four things: the file names, every reference to them, the root
`AGENTS.md` text that explains the ADR convention, and a new `just adr-check` that
enforces the format and ordering so the convention can't silently rot.

## Rename mapping (old -> new)

Sequence = creation order within each folder (from git history).

**app/docs/design/**
| seq | old | new |
|---|---|---|
| 01 | `2026-06-22-carplay-integration-surface.md` | `01-2026-06-22-carplay-integration-surface.md` |
| 02 | `2026-06-22-app-pi-transport-and-api.md` | `02-2026-06-22-app-pi-transport-and-api.md` |

**raspi/docs/design/**
| seq | old | new |
|---|---|---|
| 01 | `2026-06-22-crash-safe-recording.md` | `01-2026-06-22-crash-safe-recording.md` |
| 02 | `2026-06-22-app-pi-transport-and-api.md` | `02-2026-06-22-app-pi-transport-and-api.md` |
| 03 | `2026-06-23-storage-ring-buffer-incident-lock.md` | `03-2026-06-23-storage-ring-buffer-incident-lock.md` |
| 04 | `2026-06-23-power-source-and-shutdown.md` | `04-2026-06-23-power-source-and-shutdown.md` |
| 05 | `2026-06-23-service-language-rust.md` | `05-2026-06-23-service-language-rust.md` |

**Key property that keeps reference updates simple:** each unique `{date}-{slug}`
string maps to exactly one prefix, even across sides. The transport ADR exists in
both folders but is `02-` in both. So the six replacements below are unambiguous
no matter where the reference lives or whether it is bare or path-qualified.

The six string replacements (apply everywhere):
- `2026-06-22-carplay-integration-surface.md` -> `01-2026-06-22-carplay-integration-surface.md`
- `2026-06-22-crash-safe-recording.md`        -> `01-2026-06-22-crash-safe-recording.md`
- `2026-06-22-app-pi-transport-and-api.md`    -> `02-2026-06-22-app-pi-transport-and-api.md`
- `2026-06-23-storage-ring-buffer-incident-lock.md` -> `03-2026-06-23-storage-ring-buffer-incident-lock.md`
- `2026-06-23-power-source-and-shutdown.md`   -> `04-2026-06-23-power-source-and-shutdown.md`
- `2026-06-23-service-language-rust.md`        -> `05-2026-06-23-service-language-rust.md`

## Step 1 -- rename the files with `git mv`

Preserves history. Seven moves:

```
git mv app/docs/design/2026-06-22-carplay-integration-surface.md app/docs/design/01-2026-06-22-carplay-integration-surface.md
git mv app/docs/design/2026-06-22-app-pi-transport-and-api.md app/docs/design/02-2026-06-22-app-pi-transport-and-api.md
git mv raspi/docs/design/2026-06-22-crash-safe-recording.md raspi/docs/design/01-2026-06-22-crash-safe-recording.md
git mv raspi/docs/design/2026-06-22-app-pi-transport-and-api.md raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md
git mv raspi/docs/design/2026-06-23-storage-ring-buffer-incident-lock.md raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md
git mv raspi/docs/design/2026-06-23-power-source-and-shutdown.md raspi/docs/design/04-2026-06-23-power-source-and-shutdown.md
git mv raspi/docs/design/2026-06-23-service-language-rust.md raspi/docs/design/05-2026-06-23-service-language-rust.md
```

## Step 2 -- update every reference (the six replacements)

**Scope: tracked Markdown only** (`git ls-files '*.md'`). This deliberately
**excludes this plan file** (`plans/wip/update-the-adrs-so-reflective-spindle.md`,
untracked) -- it is the rename's own documentation and intentionally holds both old
and new names in its mapping table and `git mv` commands; rewriting it would corrupt
the table and poison the verification grep. There are no other untracked docs to
include (only this plan is untracked).

Apply the six replacements above to those files. A guarded `perl` replacement
avoids double-prefixing (do not match a filename already preceded by a digit or
dash):

```
# run from repo root; one invocation per mapping, guarded by a negative lookbehind,
# operating only on tracked Markdown
perl -0777 -pi -e 's/(?<![0-9-])2026-06-22-app-pi-transport-and-api\.md/02-2026-06-22-app-pi-transport-and-api.md/g' \
  $(git ls-files '*.md' | xargs grep -lE '2026-06-22-app-pi-transport-and-api\.md')
# ... repeat for the other five mappings ...
```

Equivalently, the implementer may do these as targeted `Edit`s -- there are only
~40 references across ~13 files. Either way, the guard (don't touch an
already-prefixed occurrence) is what matters.

Files known to carry references (from a fresh grep of tracked Markdown; re-grep to
confirm, don't trust this list as exhaustive):
- `AGENTS.md` -- 3 cross-cutting-principle `See ...` links (~lines 103/106/114).
- `app/AGENTS.md` -- intro link (~40), CarPlay link (~55), ADR listing (~78-79).
- `raspi/AGENTS.md` -- power link (~75), service-language link (~91), ADR listing
  (~180-193).
- All seven ADR bodies -- cross-references between ADRs and dated editorial notes
  (`crash-safe` -> transport/power; `transport` <-> carplay/storage; `storage`,
  `power`, `rust` -> their dependencies; plus self-reference notes).
  - Note: `app/docs/design/...carplay-integration-surface.md` has **no** ADR-file
    cross-references (only mentions `raspi/AGENTS.md`); nothing to change there.
- `plans/impl/2026-06-24-mock-pi-health-service.md` (tracked) -- references the
  transport and service-language ADRs (lines ~23/25/236). These edits are part of
  this change and **must be staged** with the rest.

`docs/roadmap.md` needs **no** change: it refers to ADRs only by prose ("the
storage ADR", "the power-source ADR"), never by filename.

## Step 3 -- rewrite the convention text in root `AGENTS.md`

These are placeholder/prose, so the Step 2 replacements do not touch them; edit by
hand.

3a. In the "Design decisions (ADRs)" -> "Convention" list, replace the Filename
bullet:

> - Filename: `docs/design/YYYY-MM-DD-{slug}.md`, dated the day the decision is taken.

with:

> - Filename: `docs/design/{seq}-YYYY-MM-DD-{slug}.md`. `{seq}` is a two-digit,
>   zero-padded sequence number assigned per side -- each side's `docs/design/`
>   starts at `01`, and a new ADR takes the highest number in that folder plus one.
>   The date is the day the decision is taken. `{seq}` is what orders ADRs and
>   disambiguates decisions made on the same day; the date alone does not sequence
>   them.

3b. In the "Repository layout" code block, update the two annotations:

> `    docs/design/         <- app-side ADRs (YYYY-MM-DD-{slug}.md)`
> `    docs/design/         <- raspi-side ADRs (YYYY-MM-DD-{slug}.md)`

to use `{seq}-YYYY-MM-DD-{slug}.md` in both.

3c. In the same "Convention" list, after the Filename bullet add a line pointing at
the enforcement added in Step 4:

> - These naming rules are enforced by `just adr-check` (run it after adding an ADR).

(The app/ and raspi/ `AGENTS.md` files defer to the root convention -- "See the
root `AGENTS.md` for the ADR convention" -- so no convention text changes there,
only the filename references handled in Step 2.)

## Step 4 -- add an ADR format/order check (`just adr-check`)

A repo-level guard so the convention can't silently rot. New script
`scripts/check-adrs.sh` (no `scripts/` dir exists yet -- create it) invoked by a new
`just adr-check` recipe. Per side (`app/docs/design`, `raspi/docs/design`) it asserts:

- **Format:** every `*.md` matches `^NN-YYYY-MM-DD-slug.md` -- two-digit zero-padded
  seq, numeric date, lowercase/digit/hyphen slug.
- **Unique + contiguous:** the per-side seq set is exactly `01..N` -- no duplicates,
  no gaps. (ADRs are append-only and never deleted, so a gap means a numbering
  mistake, not a removed ADR.)
- **Order:** taken in seq order, the dates are non-decreasing -- a later seq must not
  predate an earlier one (seq is creation order, so it has to track the date).

Sequence is checked **per side**: `app/docs/design/01-...` and
`raspi/docs/design/01-...` coexisting is correct, not a duplicate (per the per-side
numbering decision). "No dupe seq per project" means per ADR set, i.e. per side.

Reference implementation (bash 3.2-compatible, so it runs on the stock macOS shell;
implementer finalizes and runs it):

```bash
#!/usr/bin/env bash
# scripts/check-adrs.sh -- validate ADR filenames: {seq}-YYYY-MM-DD-{slug}.md
set -euo pipefail
status=0
fmt='^([0-9]{2})-([0-9]{4}-[0-9]{2}-[0-9]{2})-[a-z0-9]+(-[a-z0-9]+)*\.md$'
for dir in app/docs/design raspi/docs/design; do
  [ -d "$dir" ] || continue
  seqs=(); dates=()
  for path in "$dir"/*.md; do
    [ -e "$path" ] || continue                       # empty dir: glob stays literal
    name=$(basename "$path")
    if [[ ! $name =~ $fmt ]]; then echo "BAD FORMAT: $dir/$name"; status=1; continue; fi
    seqs+=("${BASH_REMATCH[1]}"); dates+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
  done
  [ ${#seqs[@]} -eq 0 ] && continue
  sorted=$(printf '%s\n' "${seqs[@]}" | sort)        # zero-padded -> lexical = numeric
  dups=$(printf '%s\n' "$sorted" | uniq -d)
  [ -n "$dups" ] && { echo "DUP SEQ in $dir: $dups"; status=1; }
  i=1; for s in $sorted; do printf -v want '%02d' "$i"
    [ "$s" = "$want" ] || { echo "SEQ NOT 01..N in $dir: expected $want, got $s"; status=1; }
    i=$((i+1)); done
  prev=""; while read -r s d; do
    [ -n "$prev" ] && [[ "$d" < "$prev" ]] && { echo "SEQ/DATE ORDER in $dir: seq $s ($d) precedes $prev"; status=1; }
    prev=$d; done < <(printf '%s\n' "${dates[@]}" | sort)
done
[ $status -eq 0 ] && echo "ADR check OK"
exit $status
```

Append the recipe to the root `Justfile` (matches the existing one-line-comment
style):

```
# Validate ADR filenames: format, per-side contiguous sequence, seq/date order.
adr-check:
    bash scripts/check-adrs.sh
```

Running `just adr-check` against the post-rename tree doubles as machine-checked
verification that the new names are well-formed (see Verification #6).

## Verification

1. **Files renamed:** `ls app/docs/design/ raspi/docs/design/` shows the seven
   `NN-`-prefixed names and nothing un-prefixed.
2. **Renames, not delete+add:** `git status --short` shows `R` for the seven files
   (history preserved) plus `M` for the edited reference files.
3. **No stale (un-prefixed) references remain** (tracked Markdown only, so this
   untracked plan's mapping table does not poison the result):
   `git ls-files '*.md' | xargs grep -nE '(^|[^0-9-])202[0-9]-[01][0-9]-[0-3][0-9]-[a-z]'`
   -> expect zero matches. (The `YYYY-MM-DD` placeholder in the convention text is
   non-numeric, so it won't match.)
4. **No double prefixes introduced:**
   `git ls-files '*.md' | xargs grep -nE '[0-9]{2}-[0-9]{2}-202[0-9]-[a-z]'`
   -> expect zero matches (a correct `02-2026-...` does not match this).
5. **Spot-read the diff:** confirm every backtick filename reference now carries
   the right prefix, the convention bullet reads correctly, and ADR cross-links
   still point at real files. Open one cross-link per side to confirm it resolves.
6. **`just adr-check` passes** -- exits 0 and prints `ADR check OK` against the
   renamed tree (and would fail on a dup/gap/mis-ordered/malformed name).

## Commit

Two logical commits (keep them separate -- one renames, one adds tooling).

1. The rename + reference + convention change:

```
docs: sequence ADR filenames with a per-side number prefix

ADRs are now {seq}-YYYY-MM-DD-{slug}.md, with a two-digit per-side
sequence (each docs/design/ starts at 01). The date didn't order
same-day ADRs; the seq does. Renames the seven files, updates all
references, and rewrites the ADR convention in AGENTS.md.
```

Stage the seven renames plus every edited tracked `.md` file together -- this
includes `plans/impl/2026-06-24-mock-pi-health-service.md`, whose ADR references are
part of this change.

2. The enforcement tooling (`scripts/check-adrs.sh`, the `Justfile` recipe, and the
   `just adr-check` line in the AGENTS convention from Step 3c):

```
chore(adr): add just adr-check to validate ADR filenames

Checks per-side {seq}-YYYY-MM-DD-{slug}.md naming: two-digit padded
seq, unique and contiguous from 01, and seq order matching date order.
```

The only untracked file is this plan
(`plans/wip/update-the-adrs-so-reflective-spindle.md`); do not stage it with either
commit unless asked.

## Implementation notes

- `$impl-plan` promotes the plan into `plans/impl/`, so stale-reference verification
  excludes `plans/impl/2026-06-24-sequence-adr-filenames.md`; this plan's mapping
  table intentionally preserves old-to-new filename examples.
