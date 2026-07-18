# Plan: One-command DanCam card image and offline commissioning (swoop `seed`)

## Problem and desired outcome

The current production-card path is a development bring-up sequence: Raspberry Pi
Imager writes stock Raspberry Pi OS Lite, the operator edits the boot command line,
boots on home Wi-Fi, partitions the card from the Pi, runs internet-dependent
Ansible, deploys the service, enters an AP secret, and finally hardens the image.
That sequence is useful for development, but it is not the product story for a Pi
that runs only as a no-internet access point.

The desired user story is:

1. Insert a fresh 32 GB or larger microSD card into an Apple Silicon Mac.
2. Run `just raspi-flash` and explicitly approve erasing the identified card.
3. Move the verified, ejected card into the DanCam Pi and power it on without an
   internet connection.
4. Scan the generated setup QR in the DanCam app, watch commissioning reach ready,
   and record without SSH, Raspberry Pi Imager, home Wi-Fi, Ansible, apt, or manual
   partitioning.

### Load-bearing premises

- The Zero 2 W has one microSD card for both the OS and footage. A fresh retail card
  therefore needs a complete bootable DanCam image, not runtime management of an
  independently replaceable data card.
- The production unit has one 2.4 GHz radio and operates as an AP with no upstream
  internet. Every runtime dependency and product configuration must be present in
  the flashed image.
- The `dune` four-partition MBR layout, 32 GB minimum, read-only car root and boot,
  writable `/persist`, writable `/data`, and 5% unwritten tail remain the storage
  contract.
- Existing recording-readiness and mount-witness behavior already keeps status and
  diagnosis reachable while refusing recording when `/data` is unavailable.
- The Ansible, partition, deploy, and AP-toggle workflows remain valuable for
  writable development cards; this plan replaces only production card creation.

## Decision

### D1: Replace runtime formatting with whole-card creation

Roadmap swoop `seed` supersedes `kelp`. It also absorbs `wren`'s production AP
identity and QR onboarding because a production image is not complete while it
depends on a shared or hand-entered AP secret. The remaining card-management surface
is read-only health and recovery guidance; there is no app-triggered `/data` format.

The roadmap and owning living design pages will be updated with the implementation:
the OS-image design owns the produced disk and commissioning authority, provisioning
owns the development/image-build split, networking owns the production AP identity,
the transport contract owns commissioning state, and the app connection design owns
QR onboarding and setup presentation.

### D2: Separate image production from card flashing

`just raspi-image` produces a versioned, compressed production image and authenticated
manifest from pinned Raspberry Pi OS, package, repository, and DanCam revisions. The
image is built in a controlled Linux environment and contains the service, camera
runtime, system configuration, and final car posture. The manifest makes the exact OS
base and DanCam revision inspectable.

`just raspi-flash` is a native Mac operator flow. It obtains or reuses an authenticated
release image, safely selects and writes a removable card, personalizes that card, and
verifies and ejects it. Building an image is never part of the ordinary flash path.

Production image assembly and development convergence may execute different tools,
but they share the configuration artifacts that describe DanCam-owned services,
mounts, camera setup, and networking. The repository must not acquire independent
production and development definitions of the same system fact.

### D3: Ship a complete generic image and grow only existing storage

The generic image contains all four partitions and valid filesystems. Its p1 through
p3 geometry matches `dune`; p4 begins at the final fixed offset with a small,
initialized `dancam-data` ext4 filesystem. On first boot, commissioning extends only
the end of p4 to the actual card's 95% boundary and grows that existing filesystem.
It never decides whether an unknown or signature-free partition is safe to format.
The generic filesystem contains no pre-minted recording namespace; commissioning
creates the card's storage generation only after growth succeeds.

The image reaches its final read-only root/boot posture without a user-run hardening
pass. `/persist` carries durable machine identity, NetworkManager state, commissioning
state, and logs. `/data` remains the footage ring and storage-generation authority.

### D4: Personalize on the Mac, commission on the Pi

After writing the generic image, the Mac creates a random unit identity, an SSID of
the form `dancam-<unit-id>`, and a per-unit WPA2-AES credential containing at least
128 bits of entropy from the OS cryptographic random source. Outside transient
in-process handling, the credential's only authorized representations are the
versioned commissioning envelope, intentional QR/recovery output, protected app/iOS
Wi-Fi configuration, and the commissioned NetworkManager secret under `/persist`.
It never enters the repository, process arguments or environment, shell history,
ordinary logs, failure diagnostics, or unowned temporary files.

The image contains no shared production SSID or PSK. First boot validates the
envelope and makes the unit identity, AP profile, p4/filesystem growth, and new
recording-storage generation durable. Only then does it durably commit `complete`,
which permanently retires the one-time commissioning authority before publishing
completion or admitting normal service storage work. The production image contains
no home-Wi-Fi profile and never waits for internet, package repositories, SSH, or a
workstation.

### D5: Make commissioning visible through the existing product boundary

The canonical status snapshot and event stream expose a complete commissioning value
whose state is `preparing`, `complete`, or `failed`. A failed value includes a stable,
actionable reason suitable for app presentation. Recording readiness remains false
until commissioning is durably complete and the existing camera/storage evidence is
ready.

The AP becomes reachable while commissioning is still preparing. The DanCam app's
Add Camera flow scans the standard Wi-Fi QR, derives the unit identity from the
per-unit SSID, requests a persistent iOS Wi-Fi configuration, retains the onboarding
record while the Pi boots, and connects to the existing `10.42.0.1` endpoint. It shows
preparing, ready, and actionable failure presentation from canonical Pi state rather
than estimating progress locally. The mock Pi carries the same contract.

The Pi's onboard activity LED provides visibly distinct preparing, complete, and
failed indications as a fallback when the phone cannot yet reach the AP. It mirrors
commissioning state but is not a second source of truth.

## Invariants

- **I1 - Explicit whole-card destruction.** The common command can erase only
  identified removable whole-disk media of at least 32 GB that is not the Mac's system
  storage, and performs no disk mutation until the image is authenticated and the user
  types the displayed disk identifier in an erase confirmation.
- **I2 - Stable target identity.** The flasher binds approval to the same physical
  media across selection, privilege escalation, unmount, write, personalization,
  verification, and eject; disappearance, replacement, ambiguity, or any internal
  system-storage or non-removable classification fails closed.
- **I3 - Verified completion.** Success is reported only after the image and per-card
  personalization have been read back successfully and the target has been ejected.
  Cancellation and failure never claim the card is ready.
- **I4 - Offline completeness.** A card created from a released image reaches its AP,
  canonical API, camera runtime, final mount policy, and recording readiness on a Pi
  with no upstream network from its first power-on.
- **I5 - Unique onboarding and storage identity.** Cards personalized from the same
  generic image receive different unit identities, recording storage generations, and
  AP secrets with at least 128 bits of independent cryptographic entropy. The secret
  exists only on the authorized commissioning, recovery, app/iOS, and NetworkManager
  surfaces defined by D4. The saved QR/recovery record joins only its matching unit,
  and the app does not require manual password entry.
- **I6 - Layout preservation.** Every supported card ends with the existing four MBR
  partitions, fixed p1 through p3, 4 MiB-aligned starts, p4 ending at the 95% boundary,
  the required filesystem labels and mount policy, and no writes in the reserved tail.
- **I7 - Commissioning is the only destructive authority.** Storage growth is admitted
  only while the valid one-time image marker and matching envelope prove that the card
  has never completed commissioning. While commissioning is incomplete, normal service
  startup, camera supervision, API reads, telemetry, and GC cannot modify `/data` or
  mint its generation. An ordinary or damaged post-commission boot can report a
  storage fault but cannot recreate, format, shrink, or replace `/data`.
- **I8 - Power-loss-safe admission.** Interruption at any commissioning boundary is
  resumable or fails closed. All commissioning-owned identity, AP, partition,
  filesystem, and generation prerequisites become durable before the terminal
  `complete` commit. Publishing `complete`, recording readiness, and normal service
  storage work follow that commit; once the first recording is admitted, no replay
  can erase it.
- **I9 - One product truth.** Snapshot, SSE, mock, and app agree on commissioning state
  and its transition to recording readiness. A connected phone can distinguish work
  in progress from a terminal fault without a second health model, and the physical
  indication agrees with that state.
- **I10 - Development workflow retained.** Writable development cards can still use
  the current home-Wi-Fi Ansible, partition, deploy, AP-toggle, and `changed=0`
  convergence loop without acquiring production credentials or automatic AP boot.

## Proof obligations

- **PO1 (I1).** Prove every ineligible, ambiguous, rejected, or incorrectly confirmed
  target remains unmodified, and that exact approval authorizes only the displayed
  eligible card.
- **PO2 (I2).** Prove approval cannot be replayed onto media different from the
  selected macOS media identity, including a target that changes after selection.
- **PO3 (I3).** Prove reported success implies authenticated and traceably rebuildable
  source material, verified image and personalization readback, and successful eject;
  prove faults cannot claim readiness. Complete the same flow on a real removable
  microSD attached to the supported Mac.
- **PO4 (I4).** Boot a freshly created card on the real Zero 2 W with upstream access
  physically unavailable; prove the per-unit AP, canonical status/events, IMX708,
  read-only root/boot, persistent state, and a completed recording all work without a
  package or workstation dependency.
- **PO5 (I5).** Personalize two cards from one image, prove their unit, AP, and storage
  identities differ and each AP secret meets the cryptographic entropy floor. Scan
  each QR through the physical iPhone app, verify persistent rejoin to the matching AP,
  and prove malformed or mismatched onboarding data is rejected. Across successful
  and failed personalization, commissioning, and onboarding paths, prove the secret
  appears only on D4's authorized surfaces and never in arguments, environment,
  history, repository state, logs, failure diagnostics, or unowned temporary files.
- **PO6 (I6).** Verify layout math and resulting filesystems for representative 32,
  64, 128, and 256 GB capacities, including the minimum-size refusal boundary and the
  unwritten tail; confirm at least the minimum and one larger card on real media.
- **PO7 (I7).** Prove service startup, camera supervision, status/SSE reads, telemetry,
  and GC leave `/data` and its generation untouched while commissioning is incomplete.
  Prove every unavailable or untrusted post-commission `/data` state keeps boot/status
  reachable while admitting no destructive storage operation and exposing no format
  route.
- **PO8 (I8).** Inject abrupt termination at every durable boundary in the complete
  transaction, from its first commissioning mutation through the terminal commit and
  first post-commission recording. Each reboot must converge to a safe preparing,
  failed, or complete state, no normal service storage work may precede the terminal
  commit, and the first admitted footage must survive every later replay.
- **PO9 (I9).** Round-trip every commissioning snapshot and delta through the root
  golden event corpus and both Rust and Swift folds; prove app preparing/failure/ready
  presentation, reconnect convergence, readiness blocking, physical indication, and
  mock parity without asserting internal decomposition.
- **PO10 (I10).** Re-run the existing development provisioning, partition regression,
  deploy, manual AP-return path, and car-state checks; a converged development Pi still
  reports `changed=0` and retains its non-autoconnect development AP behavior.
- **PO11 (premises and documentation).** Build the docs and verify that roadmap,
  runbook, OS image, provisioning, networking, telemetry/transport, and app connection
  pages describe one production-card story, with `kelp` and the absorbed portion of
  `wren` removed rather than left as competing future behavior.

## Non-goals

- Preserving footage, `/persist`, or device identity while reflashing a card.
- Formatting or repairing `/data` from the app or raw API after commissioning.
- Hot-swappable or independently replaceable recording media.
- In-place package updates, OTA, A/B system updates, or production SSH maintenance.
- Windows, Linux-desktop, Intel Mac, other Raspberry Pi models, or a public Imager GUI
  distribution in this swoop.
- Migrating existing development cards; they may be recreated from a released image
  when production acceptance begins.

## Accepted risks

- **AR1 - Whole-card recovery loses Pi-local state.** Reimaging destroys footage and
  `/persist`. This matches the one-card hardware model; phone-owned incidents remain
  durable, and the operator receives an explicit destructive warning.
- **AR2 - The onboarding record contains the AP secret.** Anyone who can read the QR,
  recovery record, or physical card can recover the local-link credential. Restrictive
  local handling and unique per-unit secrets are sufficient for this physical-access
  boundary.
- **AR3 - Production software is pinned until reimage.** With no upstream network or
  in-place update path, fixes require a newly released image and destructive reflash.
  Update preservation is a separate product decision.

## Rejected ideas

- **RI1 - Stock Lite followed by Pi-side production provisioning.** It requires home
  Wi-Fi, apt, SSH, and several operator phases that the deployed topology does not
  have.
- **RI2 - Blank-p4 autoformat or an app format command.** After first use, an absent
  filesystem signature can mean damaged recoverable footage; normal boot does not
  have enough authority to choose destruction.
- **RI3 - Build the custom image during every flash.** It makes the user wait on a
  privileged Linux image build and permits two users flashing the same release to get
  different package inputs.
- **RI4 - Shared production credentials or a manually entered PSK.** They leave the
  whole-card command incomplete and make compromise of one unit affect every unit.

## Implementation discretion

- The image-construction framework, compression, manifest, and signing mechanisms are
  implementation choices provided the produced artifact is traceable, authenticated,
  reproducible from pinned inputs, and satisfies the image invariants.
- The Mac block writer, removable-media discovery mechanism, and QR rendering library
  are implementation choices provided the operator and safety contracts above remain
  observable.
