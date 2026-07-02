# Move the Pi runbook to `raspi/README.md`; make the root README a project intro

## Context

The root `README.md` is what GitHub renders as the repo's front door, but today it is
a ~400-line Raspberry Pi field runbook (flash -> SSH -> provision -> camera -> AP ->
deploy -> verify). Nothing in it tells a newcomer what dancam *is* -- that elevator
pitch only exists in `AGENTS.md`, which GitHub does not surface as the landing page.

This change relocates the runbook to `raspi/README.md` (its natural home, next to
`raspi/AGENTS.md`, and the page GitHub shows when you browse into `raspi/`), and
replaces the root `README.md` with a short, human-friendly project introduction that
links out to the existing docs.

**Decisions locked (from planning):**

- **Clean move.** Relocate the runbook near-verbatim -- rebase its internal links,
  de-rot the one dated line, otherwise leave content intact. Reviews as a rename plus a
  handful of edits. Heavier pruning (the Ansible essay, watchdog verification prose,
  mock-backend detail) is a deliberately separate follow-up, out of scope here.
- **No new ADR.** The runbook still exists and still owns bootstrap/verify/ops steps
  Ansible structurally cannot do, so ADR 09's three-way ownership split is unchanged.
  Record the relocation as a minimal locative amend to ADR 09, not a new ADR.
- The root `AGENTS.md` "Raspberry Pi setup runbook" convention block is *already*
  partly stale post-ADR-09 (it claims provisioning/config changes "must update the
  README", but `site.yml` + task comments own that now). Fix location **and** narrow
  scope in the same edit.

## Scope of the link work (from exploration)

Only **6 markdown links** move; everything else is non-breaking prose.

- **3 links point at the runbook** (must re-target):
  - `AGENTS.md` Build/run: `[README.md](README.md)` -> `raspi/README.md`
  - `AGENTS.md` conventions bullet: `[README.md](README.md)` -> `raspi/README.md`
  - `raspi/AGENTS.md` Build/run: `[README.md](../README.md)` -> `README.md`
- **3 links inside the runbook** (rebase, since the file drops into `raspi/`):
  - intro: `[raspi/AGENTS.md](raspi/AGENTS.md)` -> `AGENTS.md`
  - section 3: `[raspi/docs/design/12-...md](raspi/docs/design/12-...md)` -> `docs/design/12-...md`
  - section 7: `[raspi/AGENTS.md](raspi/AGENTS.md)` -> `AGENTS.md`

Confirmed non-issues: no Justfile recipe or shell script references the README by path
(`git mv` touches no build tooling); `.env.example` lives at the repo root and the
runbook's Mac-side commands run from the repo root, so `cp .env.example .env` stays
valid; `scripts/check-adrs.sh` does not scan the README.

## Changes

### 1. Relocate the runbook -> `raspi/README.md`

- `git mv README.md raspi/README.md` (preserves rename history).
- Rebase the 3 internal links above (`raspi/AGENTS.md` -> `AGENTS.md` x2;
  `raspi/docs/design/12-...` -> `docs/design/12-...`).
- Opening sentence: "see `raspi/AGENTS.md`; this file is just the commands" ->
  "see `AGENTS.md`; ...".
- De-rot the dated OS line ("...was at release 2026-06-18 as of writing this") ->
  a stable form, e.g. "Raspberry Pi OS Lite (64-bit), Trixie."
- Clarify command context without over-claiming it. This is a **mixed Mac/Pi**
  runbook: Mac-side commands with repo-relative paths (`just ...`, `cp .env.example
  .env`, the `ffmpeg ... raspi/service/assets/...` regen line) run **from the repo
  root**, while Pi-side commands (`rpicam-*`, `nmcli`, `systemctl`, `journalctl`, the
  `camera.py` smoke test, the `read -rsp` PSK prompt) run **on the Pi over SSH**. Add a
  top note stating that split -- *not* a blanket "everything runs from the repo root" --
  and preserve/add the explicit "on the Mac" / "on the Pi" cues the file already uses in
  spots (e.g. the `scp` block's `# run on the Mac`) so no block is ambiguous now that
  the runbook no longer sits beside `.env.example`.
- Keep the `# Raspberry Pi setup` title, all 8 sections, and the verification detail
  as-is. Mac-side backticked command paths stay root-relative (they execute from the
  repo root); only the 3 markdown *navigation* links rebase to the file's new location.

### 2. New root `README.md` -- concise project intro

A short front door that links into `AGENTS.md` as the source of truth (kept lean to
avoid duplicating/drifting from it). Plain ASCII, straight quotes, `--`. Sourced only
from existing docs:

- **Pitch** (1 short paragraph) -- from `AGENTS.md` opening ("A do-it-yourself dashcam
  system built around an iPhone...").
- **The three parts** -- camera unit (`raspi/`) / iPhone app (`app/`) / CarPlay, one
  line each; the "iPhone-only, app owns the experience, Pi deliberately dumb" framing.
- **Status** -- honest and holding both truths: no users or shipped releases and
  design-doc-heavy, *but* several end-to-end slices already work. Link `docs/roadmap.md`.
- **Hardware** -- one line: Pi Zero 2 W + Arducam IMX708 Autofocus Wide; link
  `raspi/AGENTS.md` for the full spec.
- **Design principles** -- the cross-cutting-principle headlines condensed to one line
  each (SD is the source of truth; Wi-Fi is 2.4 GHz preview+pull only; CarPlay is
  voice/status/control, not a video viewport; recording survives abrupt power loss;
  thermals are a real constraint). Link `AGENTS.md` for the full statements.
- **Repository layout** -- the tree from `AGENTS.md#Repository layout`, trimmed.
- **Where to go next** -- Pi setup -> `raspi/README.md`; iPhone app -> `app/AGENTS.md`;
  whole-system overview + design decisions -> `AGENTS.md`; build plan -> `docs/roadmap.md`.

### 3. Fix inbound references + record the pivot

- **`AGENTS.md`** (root):
  - Build/run: re-target `[README.md](README.md)` -> `raspi/README.md`.
  - The **"Raspberry Pi setup runbook"** convention bullet: re-target the link to
    `raspi/README.md` **and** narrow the scope. It currently says provisioning/onboard
    changes (packages, `config.txt`, Avahi, NetworkManager, systemd units, deploy
    paths...) "must update the README." Post-ADR-09 those update `site.yml` + its task
    comments (already the rule in `raspi/AGENTS.md`). Rewrite so the runbook owns the
    bootstrap/verify/ops + human-facing steps, and defer system-state changes to the
    playbook, cross-referencing ADR 09 / `raspi/AGENTS.md`.
- **`raspi/AGENTS.md`** (Build/run paragraph): `[README.md](../README.md)` ->
  `[README.md](README.md)`; drop the "root" locative ("The root `README.md`" -> "The
  `README.md` here"/"This directory's `README.md`"); keep the accurate
  "bootstrap/verify/ops runbook" description. (The design-index one-liner "the README
  becomes a bootstrap/verify/ops runbook" stays accurate -- leave it.)
- **`raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md`**: minimal
  locative amend only. Update the present-tense role phrases that assert location
  (the **Related** line's `README.md`, the Decision's "**The README becomes a thin
  bootstrap/verify/ops runbook**") to name `raspi/README.md`, and add a light trace:
  `**Amended:** 2026-07-02 -- runbook relocated to raspi/README.md (docs-only; the
  three-way ownership split is unchanged)`. Leave the **Context** past-tense history
  ("The root `README.md` was the only record...") intact -- it is accurate history.
  **Deliberate deviation from the "remove the runbook from the ADR" instinct:** ADRs
  are append-only and the runbook still owns real steps, so this corrects the path
  rather than deleting the decision. If fuller removal is wanted, that is a larger
  ADR-history question to raise separately.

### Explicitly out of scope

- Heavy runbook pruning (section-3 Ansible system-layer essay, the `tail -n1` /
  watchdog-arming verification prose, relocating mock-backend detail into
  `raspi/AGENTS.md`). Deferred, clearly-scoped follow-up.
- Historical prose that mentions "the README"/"runbook" in immutable records:
  everything under `plans/`, the roadmap `loam` acceptance sub-bullet, and the
  `raspi/ansible/site.yml` `(README)` task comments. These are append-only history or
  generic "the README" pointers that stay accurate wherever the file lives -- touching
  them is scope creep.

## Verification

- **ADR check:** `just adr-check` -> `ADR check OK` (no ADR added; the ADR 09 amend is
  filename-neutral).
- **Link integrity:** the greps must be **per file**, not run over both together -- the
  re-targeted `raspi/AGENTS.md` link is itself `](README.md)`, so a combined grep would
  correctly still match. Use fixed-string (`-F`) so the `.` and `()` stay literal:
  - `grep -nF "](README.md)" AGENTS.md` -> **no matches** (both re-targeted to `raspi/README.md`).
  - `grep -nF "](../README.md)" raspi/AGENTS.md` -> **no matches** (the `../` link is gone).
  - `grep -nF "](README.md)" raspi/AGENTS.md` -> **exactly one** match (the re-targeted Build/run link).
  - `grep -nF "raspi/README.md" AGENTS.md` -> **two** hits (Build/run + conventions bullet).
  - The 3 relocated links resolve on disk from `raspi/`: `raspi/AGENTS.md` exists;
    `raspi/docs/design/12-2026-06-30-watchdog-and-persistent-journal.md` exists.
- **Rename tracked:** `git status` shows `R  README.md -> raspi/README.md` plus a new
  untracked root `README.md`; `git diff -M` shows the move as a rename with only the
  link/de-rot edits, not a delete+add.
- **Runbook still executable:** spot-check that the Mac-side, repo-relative command
  blocks still assume the repo root (`cp .env.example .env`, `just raspi-provision`,
  the `ffmpeg ... raspi/service/assets/...` regen line), and that Pi-side blocks
  (`rpicam-*`, `nmcli`, `systemctl`, `journalctl`, the `camera.py` smoke test) keep an
  explicit "on the Pi" cue -- consistent with the new top note's Mac/Pi split.
- **Render spot-check:** open both `README.md` and `raspi/README.md` in a local
  Markdown preview and click each link through (the 3 rebased runbook links + the new
  intro's out-links) to confirm none 404.
- **Tooling untouched:** `just --list` unchanged; no recipe or script references the
  README path, so nothing else needs updating.

## Implementation notes

- Because the same commit replaces `README.md` with a new intro, the final staged diff
  cannot appear as a pure rename under `git diff -M`; `git diff -C
  --find-copies-harder` detects the moved runbook as `README.md => raspi/README.md`
  with 96% similarity.
