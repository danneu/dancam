# Plan: Replace the ADR corpus with living design pages and an mdBook site

## Context

The ADR system has hit its failure mode: 54 ADRs across two per-side folders
(24 in `raspi/docs/design/`, 30 in `app/docs/design/`), 7 of them fully
superseded, several amended in place (raspi 02 six times), with two colliding
per-side sequence number lines and "app ADR 26 vs raspi ADR 24" disambiguation
prose everywhere. Understanding the current system requires mentally folding
every active ADR; the side AGENTS.md files each carry a ~100-line hand-
maintained ADR catalog that grows with every decision and pollutes agent
context on every task.

The owner's actual need from ADRs is narrower than what they provide: document
the *reasons* behind decisions and the *ideas that didn't pan out*. The "what
the system is now" belongs in living reference docs.

**New system:** one top-level `docs/` tree of living subsystem pages, each
page ending in an append-only, dated **Decision log** that preserves the why
and the rejected alternatives. No ADR files, no sequence numbers, no
supersession ceremony -- git history is the true append-only record. mdBook
renders `docs/` as a browsable site, publishable when dancam goes public.
This also completes the earlier "lean AGENTS.md" direction: AGENTS.md files
shrink to stance + constraints + links-with-blurbs into the book.

Decided with the owner:
- **Fidelity: preserve richly.** Decision-log entries carry over each ADR's
  Context and Alternatives-considered content mostly intact -- trim only what
  the page body now states and dead cross-reference plumbing (status headers,
  supersession pointers). Long pages are accepted.
- **Scope: full payback.** Includes AGENTS.md slimming, hardware/references
  extractions, the runbook move into the book, and the root README refresh.
- **Cadence: pause once, after the pilot page**, to approve the page template.
  Then execute the remaining commits in batches without stopping.

## End state

```
book.toml                  <- repo root; [book] src = "docs"
docs/
  SUMMARY.md
  overview.md              <- reader-facing system picture
  roadmap.md               <- stays (prose ADR refs rewritten)
  hardware.md              <- extracted from raspi/AGENTS.md
  references.md            <- extracted from root AGENTS.md
  design/
    boundary/transport.md
    pi/recording.md  storage.md  os-image.md  networking.md
       provisioning.md  service.md  telemetry.md
    app/architecture.md  connection.md  clips.md  browsing.md
        incidents.md  sharing.md  capacity.md  carplay.md  logging.md
  reference/events.md      <- non-owning projection; body = {{#include}} of
                              contract/events/README.md (the canonical source)
  setup/pi-runbook.md      <- moved from raspi/README.md
  research/                <- stays
  battle-notes/            <- stays
```

Deleted at the end: `app/docs/`, `raspi/docs/` (both contain only `design/`),
`scripts/check-adrs.sh`, the `adr-check` Justfile recipe. `raspi/README.md`
becomes a short pointer to the runbook chapter. `contract/` stays where it is
(code-adjacent fixtures) and `contract/events/README.md` remains the
**canonical source of truth** for the event wire format. The book's
`docs/reference/events.md` is an explicitly non-owning projection: its body is
a `{{#include}}` of the contract README (no forked prose to drift), and it
opens with a one-line note naming the contract README as canonical and linking
to the design pages that own the *rationale* -- `design/boundary/transport.md`
(SSE framing / snapshot-delta-heartbeat semantics) and the app/pi pages that
consume events. It carries no Decision log of its own; event-design rationale
belongs on those owning design pages, which is where future event changes
record their why.

### Page anatomy

- **Body**: the current design, written as canonical present-tense reference.
  Kept current in the same change as any behavior change (same rule that
  already governs `raspi/ansible/site.yml` comments and the runbook).
  Cross-references follow the cross-reference style below: in-book pages are
  Markdown links, out-of-book targets (code, config) are backticked anchors.
- **`## Decision log`** at the end: dated `###` entries, chronological,
  append-only. Each entry opens with an attribution line, e.g.
  `(absorbed from app ADR 08, 2026-06-27)`, then preserves the original
  Context / why / Alternatives-considered content. Dead ADRs (superseded
  ideas) become entries that state what was tried and why it was killed --
  this is the "didn't pan out" graveyard.

### Convention text (replaces "Design decisions (ADRs)" in root AGENTS.md)

- Design docs are living pages under `docs/design/{boundary,pi,app}/`; the
  folder is the owner (no Owner metadata, no sequence numbers).
- Every behavior change updates the owning page body in the same change.
- The why behind a decision, and abandoned ideas, go in the page's Decision
  log as a dated appended entry. Never record history by leaving stale prose
  in the body; never rewrite or delete log entries.
- AGENTS.md files stay lean: always-on stance, constraints, and commands
  only; task-specific instructions live in docs pages linked with a blurb
  saying when to read them.
- **Cross-reference style.** A reference to another page *inside the book*
  is a real Markdown link -- `[storage](../pi/storage.md)` -- so it renders
  as a clickable link and linkcheck validates it. A reference to anything
  *outside `docs/`* (source files, config, scripts, AGENTS.md) is wrapped in
  backticks and never linked -- `` `raspi/service/src/storage.rs#fn evict` `` --
  so it stays a stable textual anchor the book won't try to resolve. This
  extends the existing "stable anchor, never line numbers" rule (see
  root AGENTS.md Conventions): the backtick `path#identifier` form is the
  out-of-book anchor; in-book links carry no line numbers either.
- **Research and battle-notes are point-in-time findings, not living pages.**
  Pages under `docs/research/` and `docs/battle-notes/` record an
  investigation as of a date (carried in the filename/heading); they get no
  body-rewrite obligation and no Decision log, and they may go stale honestly
  -- that's expected, and keeps them clearly distinct from `docs/design/`
  pages so nobody is on the hook to maintain them. A new file in either
  folder gets its `docs/SUMMARY.md` entry in the same change (with
  `create-missing = false`, a SUMMARY *typo* fails the build, but a *missing*
  entry silently won't render -- this convention is the guard for that
  direction).

### Migration-period authority rule (goes into the same convention commit)

- A living page, once created, is the sole authority for its subsystem; the
  ADRs it absorbs are deleted in the same commit.
- ADRs not yet absorbed remain authoritative until their page lands.
- New design decisions during the migration create/extend the owning living
  page and absorb that page's remaining ADRs in the same change. No new ADR
  files from the convention commit onward.

## Fold procedure (every page commit in Phase 2/3 follows this)

1. Write the page body: current design synthesized from the absorbed ADRs'
   in-force content (fold amendments and scoped supersessions into one
   coherent present-tense description).
2. Write the Decision log: one dated entry per absorbed decision, richly
   preserving Context/Alternatives per the fidelity rule. Dead ADRs in the
   page's lineage become "didn't pan out" entries.
3. **Source-to-destination audit (required before any deletion).** For each
   absorbed ADR *and each amendment on it*, walk its Context, Decision,
   Consequences, and Alternatives-considered and confirm every in-force
   constraint now lives in the page body and every reason/rejected idea now
   lives in the Decision log. This is the only guard against silent semantic
   loss -- once the ADR is deleted the page is the sole authority, and no
   mechanical check (linkcheck, grep) can detect a dropped constraint.
   Record the audit as a short per-ADR checklist in the commit body
   (e.g. `raspi 20: ring-buffer eviction -> body; fsync-cadence rationale
   -> log; O_DIRECT alt -> log`) so the fold is auditable in review.
4. Delete the absorbed ADR files.
5. Add the page to `docs/SUMMARY.md`.
6. Update the owning side's AGENTS.md: delete the absorbed catalog bullets;
   add/extend a short "Design pages" link list (link + when-to-read blurb).
7. Retarget every remaining reference to the deleted files:
   - **Still-living ADRs** that link to them (cross-side links are common;
     e.g. app 16/26 link into raspi 02/03/21) -- point them at the new page
     so no commit leaves a dangling link.
   - **Known prose/path reference hotspots** (inventory below).
   - Mechanical check: `git grep` each deleted filename, and grep
     `ADR <seq>` prose for the absorbed seqs; the only allowed matches are
     `plans/`, `app/plans/`, untracked files, and the just-written page's own
     Decision-log attribution lines (e.g. `(absorbed from raspi ADR 21, ...)`),
     which are deliberate provenance -- mirror the Verification section's
     exemption.
8. Verify: `just docs-build` green (build + linkcheck), `just adr-check`
   green (relaxed form), greps clean.

Reference-rewrite inventory (from a full repo sweep; assign to the commit
that deletes the target):
- `AGENTS.md` (root): app 01, app 26, raspi 01, 02, 09.
- `app/AGENTS.md` / `raspi/AGENTS.md`: full per-side catalogs -- die
  incrementally via step 6.
- `docs/roadmap.md`: ~11 prose refs (app 16, app 26, raspi 03, raspi 21,
  plus unqualified ADR 02/06/09/13/16/19/20/24 -- disambiguate side from
  context during rewrite).
- `raspi/ansible/site.yml`: raspi 01, 04, 06, 07, 09, 12 (one path ref +
  "See ADR NN" task comments).
- `raspi/README.md`: raspi 08, 09, 12 (already slimmed to pure commands;
  its rationale pointers retarget to design pages).
- `docs/research/1-rust-camera-owner.md`: raspi 07 (heavy), 01, 05, 08;
  app 08.
- `prompts/video-system-review.md`: app 09; raspi 01, 02, 03.
- Source comments: `raspi/service/src/storage.rs` (raspi 16, 19, 20),
  `raspi/service/src/recorder.rs` (raspi 20),
  `app/DanCam/DanCam/Media/Remux/H264AccessUnitAssembler.swift` (raspi 01).
- `contract/` and root `README.md` carry no ADR path refs (README prose
  mentions "ADRs" -- refreshed in Phase 5).

Exempt from rewriting (historical; resolve via git history): `plans/`,
`app/plans/`. Untracked files (`qa-incident-button-v1.md`,
`personal-notes/`, `video-review.*/`, `prompts/fable-repo-review.md`) are
not part of any commit. (The untracked `docs/research/2-fmp4-container-
measurement.md` is the exception: commit 1 tracks it and lists it under the
Research part -- see Phase 1.)

## Commit sequence

### Phase 0 -- preflight (no commits from this plan)

Land or park the in-flight working-tree changes (raspi readiness work,
`plans/impl/2026-07-15-0911-...`) before starting. The migration begins from
a clean tree.

### Phase 1 -- scaffolding (2 commits)

1. `chore(docs): add mdBook scaffolding`
   - `book.toml` at repo root: `[book] src = "docs"`, title "dancam";
     `[output.html]`; `[output.linkcheck2]` (mdbook-linkcheck2 backend).
     Under `[build]`: `create-missing = false` (a typo'd SUMMARY entry must
     fail the build, not silently ship a blank chapter -- SUMMARY is touched
     by nearly every commit) and `extra-watch-dirs = ["contract/events"]` so
     `docs-serve` rebuilds when the `{{#include}}`-d canonical contract README
     changes (it lives outside `src = "docs"`, so mdBook won't watch it
     otherwise).
   - `docs/SUMMARY.md` covering only what exists, structured with mdBook
     part headers so later phases slot pages into a named section rather than
     one flat list: a thin new `docs/overview.md` (front page: what dancam
     is, the three parts; links) and `roadmap.md` as the ungrouped prefix,
     then a `# Research` part listing both `research/1-rust-camera-owner.md`
     and `research/2-fmp4-container-measurement.md`, then a `# Battle notes`
     part listing the battle-notes file. (Design / Setup / Reference parts
     get added as those pages land in Phases 2-4.)
   - Track `docs/research/2-fmp4-container-measurement.md` (currently
     untracked) in this commit so it can be listed -- research docs belong in
     the book's browsable record just like the Decision logs.
   - `flake.nix`: add `pkgs.mdbook` and `pkgs.mdbook-linkcheck2` to the dev
     shell (the original `mdbook-linkcheck` is dropped from current nixpkgs;
     same version-managed pattern as ansible).
   - `Justfile`: `docs-build` (`nix develop -c mdbook build`) and
     `docs-serve` (`nix develop -c mdbook serve --open`), commented in the
     existing recipe style.
   - `.gitignore`: add `/book/` (build output).
   - Verify: `just docs-build` green, site renders existing docs.
2. `docs: adopt living design pages, retire the ADR convention`
   - Root `AGENTS.md`: replace the "Design decisions (ADRs)" section with the
     convention text + migration-period authority rule above; add the lean-
     AGENTS.md convention bullet.
   - `scripts/check-adrs.sh`: relax contiguous-sequence to unique-sequence
     (deletions mid-migration must not break it); update the Justfile recipe
     comment.
   - Root `README.md`: retitle the "ADR conventions" pointer to "design
     docs" (full README refresh happens in Phase 5).

### Phase 2 -- pilot (1 commit, then PAUSE for owner review)

3. `docs(pi): fold storage ADRs into living storage page`
   - `docs/design/pi/storage.md` absorbs raspi 03, 15, 16, 17, 19, 20, 21
     -- the hardest fold (amendments, cross-side supersession by app 26, a
     scoped-supersession chain), so it stress-tests the template.
   - Inbound refs: `raspi/AGENTS.md` catalog; `docs/roadmap.md`;
     `raspi/service/src/storage.rs` and `recorder.rs` comments;
     `prompts/video-system-review.md`; retarget links in still-living app
     ADRs 16, 19, 20, 24, 26 that point into these files.
   - **PAUSE: owner approves page shape, body/log balance, entry format.**

### Phase 3 -- the sweep (13 commits, one `docs(...): fold ...` each)

Order: transport first (most-cited target), then Pi clusters, then app
clusters. Each commit follows the fold procedure; "absorbs" lists side+seq.

4.  `docs/design/boundary/transport.md` -- absorbs raspi 02 + app 02 (the
    twin ADRs merge; fold raspi 02's six amendments into one coherent
    contract). This page owns the event-design rationale (SSE framing,
    snapshot/delta/heartbeat semantics). Also creates the non-owning
    `docs/reference/events.md`: a canonical-source note + links to this page,
    then `{{#include}}` of `contract/events/README.md` as its body (no Decision
    log). Heaviest inbound-ref commit: root AGENTS.md, roadmap, prompts file,
    and most still-living app ADRs link into raspi 02.
5.  `docs/design/pi/recording.md` -- absorbs raspi 01, 07, 08, 10, 23.
    Inbound: site.yml, raspi/README.md, research doc (heavy), the Swift
    remux doc comment, prompts file, root AGENTS.md.
6.  `docs/design/pi/os-image.md` -- absorbs raspi 04, 12, 18. Note raspi 04
    has sat Proposed while treated as settled; the fold accepts it and the
    log entry records that. Inbound: site.yml, raspi/README.md.
7.  `docs/design/pi/networking.md` -- absorbs raspi 06. Inbound: site.yml,
    roadmap.
8.  `docs/design/pi/provisioning.md` -- absorbs raspi 09, 11. Inbound:
    site.yml (path ref), raspi/README.md, root AGENTS.md, roadmap.
9.  `docs/design/pi/service.md` -- absorbs raspi 05, 13, 14. Inbound:
    research doc, roadmap.
10. `docs/design/pi/telemetry.md` -- absorbs raspi 22, 24. Inbound: roadmap;
    raspi/AGENTS.md deploy/readiness prose. Empties `raspi/docs/`; delete it.
11. `docs/design/app/architecture.md` -- absorbs app 03, 06, 10, 17.
12. `docs/design/app/connection.md` -- absorbs app 09, 11, 18, 21 + dead
    04, 05 (as didn't-pan-out log entries).
13. `docs/design/app/clips.md` -- absorbs app 07, 12, 13, 16 + dead 08.
    Inbound: research doc (app 08), roadmap (app 16).
14. `docs/design/app/browsing.md` -- absorbs app 22, 23, 24 + dead 19, 20.
15. `docs/design/app/incidents.md` -- absorbs app 26, 27, 29. Inbound: root
    AGENTS.md (cross-cutting principle link), roadmap.
16. `docs/design/app/sharing.md`, `capacity.md`, `carplay.md`, `logging.md`
    (one commit, four small pages) -- absorbs app 30 + dead 15, 25;
    app 28; app 01; app 14 plus the `app/AGENTS.md` "Logging" conventions
    section. Inbound: root AGENTS.md (app 01). Empties `app/docs/`; delete
    it.

### Phase 4 -- runbook and extractions (2 commits)

17. `docs: move Pi runbook into the book`
    - `raspi/README.md` -> `docs/setup/pi-runbook.md`. Prose content moves
      as-is. Rebase **only Markdown link destinations** -- distinguish two
      kinds and treat them differently:
      - **In-book targets** (Markdown links to other docs pages): rewrite
        relative to `docs/setup/`. The old `AGENTS.md`/`raspi/AGENTS.md` links
        retarget to the appropriate in-book overview/design pages (AGENTS.md
        files are not part of the rendered book, so never point at them); any
        already-in-book design-page links get their relative path adjusted.
      - **Repo-root inline commands and paths** (e.g. `./raspi/deploy.sh`,
        `raspi/ansible/site.yml`, `service/` paths): leave verbatim -- these
        are meant to be run from the repo root, not link-resolved, and
        rebasing them would corrupt operational guidance.
      Sweep the moved file for every `](` link destination, apply the split
      above, and let `just docs-build` linkcheck confirm no in-book link
      dangles (linkcheck ignores inline non-link paths). Leave a 2-line
      pointer at `raspi/README.md`.
    - Update the root AGENTS.md runbook convention bullet and
      `raspi/AGENTS.md` links to the new path.
18. `docs: extract hardware and references pages`
    - `docs/hardware.md`: full part list, cabling/connector detail, FOV spec
      notes, Imager-version notes, Arducam-driver warning from
      `raspi/AGENTS.md`; that file keeps only the constraint-bearing facts
      (512 MB, 2.4 GHz-only, 1080p30 cap, no RTC, camera 50 C ceiling).
    - `docs/references.md`: the upstream-clones + pin-workflow section from
      root `AGENTS.md`, which keeps a 3-line link+blurb.
    - Both added to SUMMARY.

### Phase 5 -- teardown and slimming (3 commits)

19. `chore: retire ADR tooling`
    - Delete `scripts/check-adrs.sh` and the `adr-check` recipe; linkcheck
      (already running in `just docs-build`) is the replacement gate.
20. `docs: slim AGENTS.md files to the lean layout`
    - Root: compress the Contract section (golden-corpus detail moves into
      `contract/events/README.md`); tighten remaining prose.
    - `raspi/AGENTS.md`: compress "Software stack" bullets to 1-2 lines +
      page links; drop ops content now owned by the runbook chapter and
      design pages; keep mission, constraints, structure, just-commands, the
      dev-vs-car-image paragraph, env vars, log pointers.
    - `app/AGENTS.md`: keep responsibilities, tech, skills paragraph,
      build/run; everything else is links.
    - Enrich `docs/overview.md` into the real reader-facing front page
      (system picture + cross-cutting principles, now linking to design
      pages). **`docs/overview.md` becomes the single canonical home for the
      full cross-cutting-principles prose.** Root `AGENTS.md` must not keep a
      second full rendition (two copies of the firmest layer would drift --
      the exact failure this migration kills); it keeps one-line constraint
      bullets, each linking to the owning design page or the overview section
      (per the lean-AGENTS.md rule). Fold this retargeting into the root-
      AGENTS.md edit in this same commit.
21. `docs: refresh root README`
    - Point "where to go next" at the book (`just docs-serve`), the runbook
      chapter, and design pages; drop ADR vocabulary.

### Phase 6 -- publish (out of scope)

A GitHub Actions -> Pages workflow lands as one commit when dancam goes
public. Nothing in this plan blocks on it.

## Verification

Per commit:
- `just docs-build` -- mdBook build + linkcheck both green.
- `just adr-check` green while any ADRs remain (relaxed form).
- `git grep -l` each filename deleted in the commit: hits only under
  `plans/`, `app/plans/` (tracked) -- nothing else.
- Prose check for absorbed seqs, e.g. `git grep -nE "(app |raspi )?ADR 0?3\b"`
  scoped by side context: no hits outside plans dirs and Decision-log
  attribution lines.

End state:
- `git grep -E "docs/design/[0-9]{2}-"` -- hits only in `plans/`/`app/plans/`.
- `git grep -E "\bADR [0-9]+"` outside `plans/`, `app/plans/`, and
  `docs/design/` (log attributions) -- empty.
- `app/docs/` and `raspi/docs/` gone; `just --list` shows `docs-build` /
  `docs-serve`, no `adr-check`.
- `just docs-serve` -- visually walk the site: SUMMARY covers every page,
  `reference/events.md` renders the included contract README (and names it
  canonical), runbook chapter intact.
- Spot-read two migrated pages against git history of their source ADRs to
  confirm no in-force constraint was dropped in the fold (storage and
  transport, the two hardest).

## Notes

- The sweep's real risk is synthesis quality, not mechanics: folding
  amendments into coherent present-tense prose can silently drop a
  constraint an ADR was carrying. The pilot pause and the two spot-reads in
  verification are the mitigations; keep each fold commit small enough to
  actually read.
- `docs/SUMMARY.md` is touched by nearly every commit; execute sequentially
  (no parallel-agent fan-out on sweep commits).
- Decision-log attribution lines ("absorbed from raspi ADR 21") are
  deliberate historical provenance, not live references; verification greps
  exclude them.

## Commit progress

- [x] 1. Add mdBook scaffolding
- [x] 2. Adopt living design pages and retire the ADR convention
- [x] 3. Fold Pi storage ADRs into a living storage page
- [x] 4. Fold the transport ADRs into a living boundary page
- [x] 5. Fold Pi recording ADRs into a living recording page
- [x] 6. Fold Pi OS-image ADRs into a living OS-image page
- [x] 7. Fold Pi networking ADRs into a living networking page
- [ ] 8. Fold Pi provisioning ADRs into a living provisioning page
- [ ] 9. Fold Pi service ADRs into a living service page
- [ ] 10. Fold Pi telemetry ADRs into a living telemetry page
- [ ] 11. Fold app architecture ADRs into a living architecture page
- [ ] 12. Fold app connection ADRs into a living connection page
- [ ] 13. Fold app clip ADRs into a living clips page
- [ ] 14. Fold app browsing ADRs into a living browsing page
- [ ] 15. Fold app incident ADRs into a living incidents page
- [ ] 16. Fold app sharing, capacity, CarPlay, and logging ADRs
- [ ] 17. Move the Pi runbook into the book
- [ ] 18. Extract hardware and references pages
- [ ] 19. Retire ADR tooling
- [ ] 20. Slim AGENTS.md files to the lean layout
- [ ] 21. Refresh the root README

## Implementation notes

- Commit 5 found that raspi ADR 01's auto-record-on-boot sketch was never realized:
  systemd starts the service and camera owner, but the recorder stays idle until the
  app issues `/v1/recording/start`. The living recording page and nearby operational
  comments now state the implemented behavior instead of carrying the stale claim
  forward.
