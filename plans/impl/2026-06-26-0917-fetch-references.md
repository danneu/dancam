# Plan: `just fetch-references` -- seed third-party source references

## Context

When working on the Pi camera process (`raspi/camera/camera.py`), agents and humans
need to read the *actual* picamera2 API source -- not guess at it. Today a full
picamera2 clone sits untracked at `references/picamera2/`, but it was cloned from
`main` (a moving target) and isn't reproducible or documented.

This change adds a `just fetch-references` task that seeds `references/` with upstream
source **pinned to the version we actually run**, so the reference matches the tool.
picamera2 is installed on the Pi via `apt install python3-picamera2` on Raspberry Pi OS
Trixie -- there is no version pin in the repo, and the Rust service shells out to
`camera.py`, which imports picamera2. The reference must therefore track a *released
tag* matching the Pi's apt package, refreshable with one command.

## Decisions (locked with user)

- **Version source: explicit pin + Pi check.** The fetch script pins each reference's
  version (the committed authority); a helper SSHes to the Pi to report its installed
  version so the pin can be confirmed/bumped. Deterministic and works offline; the Pi is
  consulted deliberately, not on every fetch.
- **Tracking: git-ignore `references/`.** It's large, external, and regenerable from the
  pin. AGENTS.md documents that it exists and how to seed it, so LLMs/agents know about it.

## Changes

### 1. New: `scripts/fetch-references.sh` (clone/refresh logic)

Mirrors the existing `scripts/check-adrs.sh` style (`#!/usr/bin/env bash`,
`set -euo pipefail`) and the `REPO_ROOT` cd-to-root idiom from `raspi/deploy.sh`. An
extensible `name|url|ref` list (only picamera2 for now); idempotent clone-or-update.

```bash
#!/usr/bin/env bash
# scripts/fetch-references.sh -- seed/refresh third-party source clones under references/.
#
# Clones each reference at a pinned version (git tag/branch/commit) so the source we read
# matches the tool we actually run. references/ is git-ignored; re-run any time to reseed.
# Confirm/bump the pins against the Pi with `just references-pi-version`.
set -euo pipefail

# picamera2: match the python3-picamera2 version apt installs on Raspberry Pi OS Trixie.
PICAMERA2_REF="${PICAMERA2_REF:-v0.3.36}"

# Each entry: name|git-url|ref. Add a line to register a new reference.
REFERENCES=(
  "picamera2|https://github.com/raspberrypi/picamera2.git|${PICAMERA2_REF}"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p references

for entry in "${REFERENCES[@]}"; do
  IFS='|' read -r name url ref <<<"$entry"
  dest="references/$name"
  if [ -d "$dest/.git" ]; then
    echo "==> updating $name -> $ref"
    git -C "$dest" fetch --depth 1 --tags origin "$ref"
    git -C "$dest" checkout --quiet --detach FETCH_HEAD
  else
    echo "==> cloning $name @ $ref"
    git clone --depth 1 --branch "$ref" "$url" "$dest"
  fi
done

echo "==> references seeded under references/"
```

Notes:
- Shallow (`--depth 1 --branch <ref>`) keeps clones small; reading source needs no history.
- The upstream tag is `v0.3.36` (confirmed via `git ls-remote --tags` during review).
  `0.3.36` is also the version in the currently-cloned `references/picamera2/pyproject.toml`.
- **The default pin is provisional until proven against the Pi.** `v0.3.36` is derived from
  the existing untracked clone, *not* from the Pi's apt package -- it has never been shown
  to match what Trixie installs. Establishing or changing `PICAMERA2_REF` **requires**
  running `just references-pi-version` and mapping its `apt:` output (e.g. `0.3.36-1`) to the
  tag (`v0.3.36`); see Verification. Do not claim the reference "matches the version we run"
  before that check passes.
- First run converts the existing `main` clone to the pinned tag via the update path.

### 2. New: `scripts/references-pi-version.sh` (drift check)

Reuses the `DANCAM_HOST` / `DANCAM_SSH_KEY` defaults from `raspi/deploy.sh`. Read-only
on the Pi (queries only). The **apt package version is authoritative** -- it's what maps
to the upstream git tag (`0.3.36-1` -> `v0.3.36`) -- so the helper hard-fails if
`python3-picamera2` can't be queried. The Python dist-metadata line is a best-effort
cross-check.

Two correctness details (both flagged in review):
- The remote command is single-quoted locally, so `${Version}` would be expanded by the
  *remote* shell to empty before `dpkg-query` sees its field spec. Escape it as
  `\${Version}` so `dpkg-query` receives the literal `${Version}` and expands it itself.
- picamera2 exposes **no** `picamera2.__version__` (verified in
  `references/picamera2/picamera2/__init__.py` -- it only re-exports classes). Query the
  installed package metadata via `importlib.metadata.version("picamera2")` instead.

```bash
#!/usr/bin/env bash
# scripts/references-pi-version.sh -- report the picamera2 version installed on the Pi,
# so the pin in scripts/fetch-references.sh can be confirmed/bumped to match.
set -euo pipefail

HOST="${DANCAM_HOST:-dan@dancam.local}"
SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519_danneu}"

echo "==> querying python3-picamera2 on $HOST"
ssh -i "$SSH_KEY" "$HOST" '
  set -eu
  # apt package version is authoritative (maps to the upstream git tag); fail if absent.
  printf "apt:    "; dpkg-query -W -f="\${Version}\n" python3-picamera2
  # python dist metadata as a cross-check (best-effort; Debian may omit it).
  printf "python: "; python3 -c "import importlib.metadata as m; print(m.version(\"picamera2\"))" || echo "(unavailable)"
'
```

### 3. `Justfile` -- two new recipes (append at end)

Matches the lowercase-hyphen + `# comment` + `bash scripts/...` delegation style.

```just
# Seed/refresh third-party source references into references/ (pinned to the Pi's versions).
fetch-references:
    bash scripts/fetch-references.sh

# Print the picamera2 version installed on the Pi (confirm/bump the pin in scripts/fetch-references.sh).
references-pi-version:
    bash scripts/references-pi-version.sh
```

### 4. `.gitignore` -- ignore the seeded clones (append new section)

```
# Third-party source references (seeded via `just fetch-references`)
references/
```

This also resolves the current untracked `?? references/` noise.

### 5. `AGENTS.md` -- document the references (the user's explicit ask)

a) Add to the Repository layout tree (after the `raspi/...` lines, before the closing fence):

```
  references/            <- third-party source clones (git-ignored; `just fetch-references`)
```

b) Add a short `## References` section immediately after the Repository layout prose
(before `## Architecture at a glance`). Keep it lean -- this file loads into every agent
context:

```markdown
## References

`references/` holds read-only clones of upstream source we build against, so agents and
humans can read the *exact* API we target. It is git-ignored (large, regenerable) --
seed or refresh it with `just fetch-references`. Versions are pinned in
`scripts/fetch-references.sh` to match what the Pi actually runs; run
`just references-pi-version` to confirm the Pi's installed version before establishing or
bumping a pin.

- **picamera2** (`references/picamera2/`) -- Raspberry Pi camera stack imported by the Pi
  camera process (`raspi/camera/camera.py`). Pinned to the `python3-picamera2` version on
  Raspberry Pi OS Trixie. Upstream: https://github.com/raspberrypi/picamera2
```

## Not changing (preempting conventions)

- **README.md:** no change required. The AGENTS.md "Raspberry Pi setup runbook" rule
  triggers only on changes to *Pi provisioning / onboard state*. `fetch-references` clones
  source on the Mac; `references-pi-version` only reads from the Pi. Neither alters Pi state.
- **No ADR:** this is dev tooling, not an architecture/design decision, so the ADR system
  does not apply.

## Verification

1. `just --list` shows `fetch-references` and `references-pi-version`.
2. **Pin proof against the Pi (required to establish or change `PICAMERA2_REF`).**
   `just references-pi-version` prints the apt version (authoritative) and exits non-zero if
   `python3-picamera2` isn't installed. Map its `apt:` output (e.g. `0.3.36-1`) to the tag
   (`v0.3.36`) and set `PICAMERA2_REF` to that. Cross-check the tag exists with
   `git ls-remote --tags https://github.com/raspberrypi/picamera2.git | grep 0.3.36`.
   If the Pi isn't provisioned yet and this can't run, the pin stays explicitly *provisional*
   (note it in the script comment) -- do not assert the reference matches the deployed tool
   until this step passes.
3. `just fetch-references` -> `references/picamera2/` exists; `grep version
   references/picamera2/pyproject.toml` shows the pinned version; the clone is detached at
   the tag (`git -C references/picamera2 describe --tags`).
4. Run `just fetch-references` a second time -> updates cleanly, no error (idempotent).
5. `git status` -> `references/` no longer appears (ignored), and is not staged.
