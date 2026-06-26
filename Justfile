# Build the Raspberry Pi Rust service for the local host.
raspi-build:
    cargo build --manifest-path raspi/service/Cargo.toml

# Run the Raspberry Pi Rust service tests.
raspi-test:
    cargo test --manifest-path raspi/service/Cargo.toml

# Cross-build and deploy the service to the Pi (override target with DANCAM_HOST=...).
raspi-deploy:
    ./raspi/deploy.sh

# Provision the Pi's system layer with Ansible over home Wi-Fi (apt, camera overlay,
# mDNS, locale, AP profile, video group). Override the address with host=192.168.1.50
# when mDNS is flaky. Prompts once for dan's sudo password.
raspi-provision host='dancam.local':
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml -e ansible_host={{host}} --ask-become-pass'

# Dry-run the provision: show what is out of sync on the Pi without changing anything.
raspi-provision-check host='dancam.local':
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml -e ansible_host={{host}} --ask-become-pass --check --diff'

# Hardware-free gate: syntax + ansible-lint the playbook on the Mac, no Pi connection.
raspi-provision-lint:
    nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml --syntax-check && ansible-lint site.yml'

# Run from the Mac while the Pi is on home Wi-Fi; join dancam-dev from the iPhone,
# not this Mac. Overrides: DANCAM_HOST, DANCAM_SSH_KEY, DANCAM_HOME_WIFI.
# Flip the Pi to AP mode (dancam-dev) with auto-revert to home Wi-Fi after `minutes`, then count down to the revert.
raspi-ap minutes="5":
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-dan@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519_danneu}"
    HOME_WIFI="${DANCAM_HOME_WIFI:-netplan-wlan0-peluchonet}"
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

# Run the iPhone app's Swift Testing unit suite.
app-test:
    xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamTests test

# Run the mock Pi service on 127.0.0.1:8080 for local dev.
raspi-mock:
    cd raspi/service && cargo run

# Run the mock Pi service with a sample finished clip available from /v1/clips.
raspi-mock-clips:
    cd raspi/service && DANCAM_REC_DIR=assets/clips cargo run

# Run the mock Pi service on 0.0.0.0:9000 for LAN device testing.
raspi-mock-lan:
    cd raspi/service && DANCAM_BIND=0.0.0.0:9000 cargo run

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
