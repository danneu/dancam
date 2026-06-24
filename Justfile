# Build the Raspberry Pi Rust service for the local host.
raspi-build:
    cargo build --manifest-path raspi/service/Cargo.toml

# Run the Raspberry Pi Rust service tests.
raspi-test:
    cargo test --manifest-path raspi/service/Cargo.toml

# Run the mock Pi service on 127.0.0.1:8080 for local dev.
raspi-run:
    cd raspi/service && cargo run

# Run the mock Pi service on 0.0.0.0:9000 for LAN device testing.
raspi-run-lan:
    cd raspi/service && DANCAM_BIND=0.0.0.0:9000 cargo run

# Validate ADR filenames: format, per-side contiguous sequence, seq/date order.
adr-check:
    bash scripts/check-adrs.sh
