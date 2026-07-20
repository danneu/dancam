set dotenv-load := true

# Build and sign a complete production image. On macOS this creates or reuses the
# dedicated OrbStack ARM64 Linux builder; Linux executes the native build directly.
raspi-image:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -s)" in
      Darwin) exec bash raspi/image/build-orbstack.sh ;;
      Linux) exec just _raspi-image-native ;;
      *) echo "raspi-image: unsupported host OS: $(uname -s)" >&2; exit 1 ;;
    esac

# Linux-only implementation invoked directly by the OrbStack wrapper.
_raspi-image-native:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo zigbuild --release --target aarch64-unknown-linux-musl --manifest-path raspi/service/Cargo.toml
    sudo env PATH="$PATH" \
      DANCAM_SERVICE_BINARY="$PWD/raspi/service/target/aarch64-unknown-linux-musl/release/dancam" \
      DANCAM_IMAGE_SIGNING_KEY="${DANCAM_IMAGE_SIGNING_KEY:?set DANCAM_IMAGE_SIGNING_KEY}" \
      bash raspi/image/build.sh

# Hardware-free regression for OrbStack machine creation, reuse, and build dispatch.
raspi-image-builder-test:
    bash raspi/image/build-orbstack-test.sh

# Authenticate, personalize, verify, and eject a removable production card.
# With no argument, flash the newest released manifest under dist/.
raspi-flash manifest='':
    nix develop -c bash raspi/flash/flash.sh {{quote(manifest)}}

# Hardware-free target eligibility and exact-confirmation regression.
raspi-flash-test:
    bash raspi/flash/flash-policy-test.sh
    bash raspi/flash/personalization-test.sh

# Hardware-free geometry and replay regression for first-boot commissioning.
raspi-commission-test:
    bash raspi/image/commission-test.sh

# Build the Raspberry Pi Rust service for the local host.
raspi-build:
    cargo build --manifest-path raspi/service/Cargo.toml

# Run the Raspberry Pi Rust service tests.
raspi-test:
    cargo test --manifest-path raspi/service/Cargo.toml

# Exercise the Python muxer contract and the Rust transaction/duration boundary.
raspi-camera-test:
    python3 raspi/camera/camera.py --self-test
    cargo test --manifest-path raspi/service/Cargo.toml ts_duration
    cargo test --manifest-path raspi/service/Cargo.toml camera

# Run the Raspberry Pi Rust service formatting and lint gate.
raspi-check:
    cargo fmt --manifest-path raspi/service/Cargo.toml --check
    cargo clippy --manifest-path raspi/service/Cargo.toml --all-targets -- -D warnings

# Build the documentation book and validate its links.
docs-build:
    nix develop -c mdbook build

# Serve the documentation book locally and open it in a browser.
docs-serve:
    nix develop -c mdbook serve --open

# Cross-build and deploy the service to the Pi (override target with DANCAM_HOST=...).
raspi-deploy:
    ./raspi/deploy.sh

# Hardware-free regression for deploy's status/readiness phases and diagnostics.
raspi-deploy-test:
    bash raspi/scripts/deploy-test.sh

# Wipe recorded footage on the Pi: refuse unless /data is a real mount, then stop dancam,
# delete everything under /data/rec (segments + witness/time state, so the next run
# restarts at seq 0 / session 1), and always restart dancam and wait for it to answer
# recording-ready /v1/status -- failing loudly if it does not come back. Destructive; prompts unless
# DANCAM_YES=1. Override host with DANCAM_HOST=...
raspi-reset-data:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    PORT="${DANCAM_PORT:-8080}"
    READINESS_TIMEOUT="${DANCAM_RECORDING_READINESS_TIMEOUT:-60}"
    REMOTE_SCRIPT=/tmp/dancam-reset-data.sh
    # Mount witness identical to the service's stat-based ensure_required_mountpoint:
    # /data is mounted iff dev(/data) != dev(/) OR ino(/data) == ino(/); abort on the
    # complement. Each stat is captured in its own fail-closed assignment (a stat that
    # fails aborts under set -e -- it never leaves an empty value that a bare `$(stat)`
    # inside the `if` condition could let slip past the guard). Defined once and
    # interpolated into both SSH sessions so they stay in lockstep.
    WITNESS='
      [ -d /data ] || { echo "ABORT: /data missing or not a directory; refusing to touch /data/rec" >&2; exit 1; }
      data_dev=$(stat -c %d /data) || { echo "ABORT: cannot stat /data; refusing to touch /data/rec" >&2; exit 1; }
      root_dev=$(stat -c %d /)     || { echo "ABORT: cannot stat /; refusing to touch /data/rec" >&2; exit 1; }
      data_ino=$(stat -c %i /data) || { echo "ABORT: cannot stat /data; refusing to touch /data/rec" >&2; exit 1; }
      root_ino=$(stat -c %i /)     || { echo "ABORT: cannot stat /; refusing to touch /data/rec" >&2; exit 1; }
      if [ "$data_dev" = "$root_dev" ] && [ "$data_ino" != "$root_ino" ]; then
        echo "ABORT: /data is not a mounted filesystem (same device as /); refusing to touch /data/rec" >&2
        exit 1
      fi'
    echo "==> current footage on $HOST:"
    ssh -t -i "$SSH_KEY" "$HOST" "
      set -euo pipefail
      $WITNESS
      sudo du -sh /data/rec 2>/dev/null || true
      printf 'entries: '; sudo find /data/rec -mindepth 1 2>/dev/null | wc -l
    "
    if [ "${DANCAM_YES:-}" != "1" ]; then
      read -r -p "Delete ALL of /data/rec on $HOST? [y/N] " ans
      case "$ans" in y | Y) ;; *) echo "aborted"; exit 1 ;; esac
    fi
    scp -i "$SSH_KEY" raspi/scripts/reset-data.sh "${HOST}:${REMOTE_SCRIPT}"
    remote_command="sudo DANCAM_PORT=$(printf %q "$PORT") DANCAM_RECORDING_READINESS_TIMEOUT=$(printf %q "$READINESS_TIMEOUT") bash $(printf %q "$REMOTE_SCRIPT")"
    ssh -t -i "$SSH_KEY" "$HOST" "$remote_command"
    echo "==> /data/rec cleared; dancam restarted and recording-ready (next run: seq 0 / session 1)"

# Hardware-free behavioral regression for the recording-data reset.
raspi-reset-data-test:
    bash raspi/scripts/reset-data-test.sh

# Hardware-free regression for the SD-card partition math.
raspi-partition-test:
    bash raspi/scripts/partition-card-test.sh

# Copy the SD-card partitioner to the Pi and run it with sudo.
raspi-partition:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    scp -i "$SSH_KEY" raspi/scripts/partition-card.sh "$HOST:/tmp/dancam-partition-card.sh"
    scp -i "$SSH_KEY" raspi/system/card-layout.env "$HOST:/tmp/card-layout.env"
    ssh -t -i "$SSH_KEY" "$HOST" "sudo bash /tmp/dancam-partition-card.sh"

# Toggle IMX708 on-sensor HDR while the camera is closed, then restart dancam and
# wait for recording readiness. HDR caps the sensor at 2304x1296@30 (still enough
# for 1080p30) and resets off on reboot. Override the host with DANCAM_HOST=...
raspi-hdr mode:
    #!/usr/bin/env bash
    set -euo pipefail
    mode={{quote(mode)}}
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    PORT="${DANCAM_PORT:-8080}"
    READINESS_TIMEOUT="${DANCAM_RECORDING_READINESS_TIMEOUT:-60}"
    REMOTE_SCRIPT=/tmp/dancam-hdr-set.sh
    scp -i "$SSH_KEY" raspi/scripts/hdr-set.sh "${HOST}:${REMOTE_SCRIPT}"
    remote_command="sudo DANCAM_PORT=$(printf %q "$PORT") DANCAM_RECORDING_READINESS_TIMEOUT=$(printf %q "$READINESS_TIMEOUT") bash $(printf %q "$REMOTE_SCRIPT") $(printf %q "$mode")"
    ssh -t -i "$SSH_KEY" "$HOST" "$remote_command"

# Hardware-free behavioral regression for the IMX708 HDR toggle.
raspi-hdr-test:
    bash raspi/scripts/hdr-set-test.sh

# Provision the Pi's system layer with Ansible over home Wi-Fi (apt, camera overlay,
# mDNS, locale, AP profile, video group). Override the address with host=192.168.1.50
# when mDNS is flaky. Prompts once for your sudo password.
raspi-provision host='dancam.local':
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml -e ansible_host="$1" -e ansible_user="$2" -e ansible_ssh_private_key_file="$3" --ask-become-pass' _ "{{host}}" "${HOST%%@*}" "$SSH_KEY"

# Provision the car-image hardening layer after the dev-shared storage layout has
# converged. This flips the next boot to read-only root and persistent bind mounts.
raspi-provision-car host='dancam.local':
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml -e car_image=true -e ansible_host="$1" -e ansible_user="$2" -e ansible_ssh_private_key_file="$3" --ask-become-pass' _ "{{host}}" "${HOST%%@*}" "$SSH_KEY"

# Dry-run the provision: show what is out of sync on the Pi without changing anything.
raspi-provision-check host='dancam.local':
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml -e ansible_host="$1" -e ansible_user="$2" -e ansible_ssh_private_key_file="$3" --ask-become-pass --check --diff' _ "{{host}}" "${HOST%%@*}" "$SSH_KEY"

# Hardware-free gate: syntax + ansible-lint the playbook on the Mac, no Pi connection.
raspi-provision-lint:
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml --syntax-check && ansible-lint site.yml'

# Run from the Mac while the Pi is on home Wi-Fi; join dancam-dev from the iPhone,
# not this Mac. Overrides: DANCAM_HOST, DANCAM_SSH_KEY, DANCAM_HOME_WIFI.
# Flip the Pi to AP mode (dancam-dev) with auto-revert to home Wi-Fi after `minutes`, then count down to the revert.
raspi-ap minutes="5":
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    HOME_WIFI="${DANCAM_HOME_WIFI:-preconfigured}"
    SECS=$(( {{minutes}} * 60 ))

    echo "==> arming +{{minutes}}min revert to $HOME_WIFI, then flipping Pi to AP (dancam-dev)"
    # Detach both via systemd so this SSH session returns before Wi-Fi drops. The
    # stop/reset-failed makes the task re-runnable (clears any prior transient units).
    ssh -t -i "$SSH_KEY" "$HOST" "
      set -e
      sudo systemctl stop  dancam-restore-home-wifi.timer dancam-restore-home-wifi.service dancam-go-ap.timer dancam-go-ap.service 2>/dev/null || true
      sudo systemctl reset-failed dancam-restore-home-wifi.timer dancam-restore-home-wifi.service dancam-go-ap.timer dancam-go-ap.service 2>/dev/null || true
      sudo systemd-run --unit=dancam-restore-home-wifi --on-active={{minutes}}min /usr/bin/nmcli connection up '$HOME_WIFI'
      sudo systemd-run --unit=dancam-go-ap          --on-active=2s             /usr/bin/nmcli connection up dancam-ap
    "

    echo "==> AP comes up in ~2s; this Mac will drop the Pi (stay on $HOME_WIFI)."
    echo "==> iPhone: join dancam-dev, then hit http://10.42.0.1:8080/v1/status"
    echo

    end=$(( $(date +%s) + SECS ))
    trap 'printf "\n  (countdown stopped; the Pi auto-revert still fires on its own)\n"; exit 0' INT
    while :; do
      left=$(( end - $(date +%s) ))
      (( left <= 0 )) && break
      printf '\r  %s restores in %02d:%02d   ' "$HOME_WIFI" $(( left / 60 )) $(( left % 60 ))
      sleep 1
    done
    printf '\r  auto-revert fired: Pi should be back on %s now.            \n' "$HOME_WIFI"

# Build the iPhone app for the iOS simulator.
app-build:
    xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'generic/platform=iOS Simulator' build

# Clean-build the app and report just the compiler warnings/errors (clean so every
# file recompiles and all warnings surface, not only the ones an incremental build touches).
app-lint:
    #!/usr/bin/env bash
    set -euo pipefail
    log="$(mktemp)"
    trap 'rm -f "$log"' EXIT
    echo "==> clean-building DanCam (this recompiles everything so all warnings surface)"
    if ! xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam \
        -destination 'generic/platform=iOS Simulator' clean build > "$log" 2>&1; then
      echo "BUILD FAILED:"
      grep -E '^/.*: error:' "$log" | sort -u
      exit 1
    fi
    warnings="$(grep -E '^/.*: warning:' "$log" | sort -u || true)"
    if [[ -n "$warnings" ]]; then
      printf '%s\n' "$warnings"
      echo "==> $(printf '%s\n' "$warnings" | wc -l | tr -d ' ') warning(s)"
    else
      echo "==> no warnings"
    fi

# Run the iPhone app's Swift Testing unit suite.
app-test:
    xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamTests test

# Run the iPhone app's XCUITest suite.
app-test-ui:
    xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamUITests test

# For a physical device, use Console.app and filter subsystem == "com.danneu.dancam".
# Stream DanCam unified logs from the booted simulator.
app-logs:
    xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "com.danneu.dancam"'

# Run the mock Pi service on 127.0.0.1:8080 for local dev.
raspi-mock:
    cd raspi/service && DANCAM_REC_DIR=.mock-rec DANCAM_MOCK_SEGMENT_SECS=5 cargo run

# Run mock commissioning presentation: preparing, complete, or failed:<reason>.
raspi-mock-commissioning state="preparing":
    cd raspi/service && DANCAM_REC_DIR=.mock-rec DANCAM_MOCK_COMMISSIONING={{quote(state)}} cargo run

# Watch ring GC evict live against the mock recorder: an intentionally huge
# floor keeps the Mac's "avail" below it, so while recording every FINISHED 5s
# mock segment becomes eviction fodder (drip oldest-first; only the currently
# open segment, protected by the live floor, survives) and the loud
# below-floor-exhausted warning + 30s backoff show up in the logs. After you
# stop recording, that last segment becomes evictable too and drains on the
# next retry, leaving the ring empty before Exhausted fires.
raspi-mock-gc:
    mkdir -p raspi/service/.mock-rec
    cd raspi/service && DANCAM_REC_DIR=.mock-rec DANCAM_MOCK_SEGMENT_SECS=5 DANCAM_GC_FLOOR_BYTES=18446744073709551615 cargo run

# Run a realistic 30s mock segment and a deterministic capacity so Settings
# converges to "About 23 hours" after the first finalized clip.
raspi-mock-retention:
    mkdir -p raspi/service/.mock-rec-retention
    cd raspi/service && DANCAM_REC_DIR=.mock-rec-retention DANCAM_MOCK_SEGMENT_SECS=30 DANCAM_MOCK_RECORDING_CAPACITY_BYTES=162432000 cargo run

# Run the mock Pi service with a sample finished clip available from /v1/clips.
# Seeds a throwaway scratch dir with the committed seg_00000.ts fixture so the
# recorder serves it as a finished clip without polluting the tracked assets dir.
raspi-mock-clips:
    cd raspi/service && mkdir -p .mock-rec-clips && cp assets/clips/seg_00000.ts .mock-rec-clips/ && DANCAM_REC_DIR=.mock-rec-clips cargo run

# Run the mock Pi service on [::]:9000 for LAN device testing.
raspi-mock-lan:
    cd raspi/service && DANCAM_BIND=[::]:9000 cargo run

# Seed/refresh third-party source references into references/ (pinned to the Pi's versions).
fetch-references:
    bash scripts/fetch-references.sh

# Print the picamera2 + libcamera versions installed on the Pi (confirm/bump the pins in scripts/fetch-references.sh).
references-pi-version:
    bash scripts/references-pi-version.sh

# Report what's using the Pi's RAM: free/top processes/GPU+CMA reservations/swap (override target with DANCAM_HOST=...).
pi-mem:
    bash scripts/pi-mem.sh
