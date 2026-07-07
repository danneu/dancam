set dotenv-load := true

# Build the Raspberry Pi Rust service for the local host.
raspi-build:
    cargo build --manifest-path raspi/service/Cargo.toml

# Run the Raspberry Pi Rust service tests.
raspi-test:
    cargo test --manifest-path raspi/service/Cargo.toml

# Run the Raspberry Pi Rust service formatting and lint gate.
raspi-check:
    cargo fmt --manifest-path raspi/service/Cargo.toml --check
    cargo clippy --manifest-path raspi/service/Cargo.toml --all-targets -- -D warnings

# Cross-build and deploy the service to the Pi (override target with DANCAM_HOST=...).
raspi-deploy:
    ./raspi/deploy.sh

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
    ssh -t -i "$SSH_KEY" "$HOST" "sudo bash /tmp/dancam-partition-card.sh"

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
    echo "==> iPhone: join dancam-dev, then hit http://10.42.0.1:8080/v1/health"
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

# For a physical device, use Console.app and filter subsystem == "com.danneu.dancam".
# Stream DanCam unified logs from the booted simulator.
app-logs:
    xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "com.danneu.dancam"'

# Run the mock Pi service on 127.0.0.1:8080 for local dev.
raspi-mock:
    cd raspi/service && DANCAM_REC_DIR=.mock-rec DANCAM_MOCK_SEGMENT_SECS=5 cargo run

# Run the mock Pi service with a sample finished clip available from /v1/clips.
raspi-mock-clips:
    cd raspi/service && DANCAM_REC_DIR=assets/clips cargo run

# Run the mock Pi service on [::]:9000 for LAN device testing.
raspi-mock-lan:
    cd raspi/service && DANCAM_BIND=[::]:9000 cargo run

# Validate ADR filenames: format, per-side contiguous sequence, seq/date order.
adr-check:
    bash scripts/check-adrs.sh

# Seed/refresh third-party source references into references/ (pinned to the Pi's versions).
fetch-references:
    bash scripts/fetch-references.sh

# Print the picamera2 version installed on the Pi (confirm/bump the pin in scripts/fetch-references.sh).
references-pi-version:
    bash scripts/references-pi-version.sh

# Report what's using the Pi's RAM: free/top processes/GPU+CMA reservations/swap (override target with DANCAM_HOST=...).
pi-mem:
    bash scripts/pi-mem.sh
