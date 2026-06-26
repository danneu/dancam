# Build the Raspberry Pi Rust service for the local host.
raspi-build:
    cargo build --manifest-path raspi/service/Cargo.toml

# Run the Raspberry Pi Rust service tests.
raspi-test:
    cargo test --manifest-path raspi/service/Cargo.toml

# Cross-build and deploy the service to the Pi (override target with DANCAM_HOST=...).
raspi-deploy:
    ./raspi/deploy.sh

# Build the iPhone app for the iOS simulator.
app-build:
    xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'generic/platform=iOS Simulator' build

# Run the iPhone app's Swift Testing unit suite.
app-test:
    xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamTests test

# Run the mock Pi service on 127.0.0.1:8080 for local dev.
raspi-run:
    cd raspi/service && cargo run

# Run the mock Pi service on 0.0.0.0:9000 for LAN device testing.
raspi-run-lan:
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
