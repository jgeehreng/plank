# PLANK Broker plan

Facility access control for direct PLANK connections. No VPN, no media proxy,
and no replacement of Host login.

The Broker answers one question: this facility principal may attempt that
workstation until this time. The Host remains the authority for the OS
account, the seat, and the session.

Authorities:

- `docs/development/investigations/plank-broker-admission-wire-contract.md`
- `docs/development/investigations/plank-broker-admission-implementation.md`
- `docs/development/investigations/plank-broker-api-state-data-architecture.md`
- `docs/development/investigations/plank-broker-admission-trust-design.md`

The Broker is a separate product. It does not enter this repository as a
submodule. Host and Client changes stay here.

## Locked decisions

- Model A. A signed admission allows an attempt. PAM and Open Directory still
  authenticate the OS user.
- Admission purpose is `connect-attempt`. Audience is `plank-host`. The
  workstation identity is `uniqueid`.
- Offline Ed25519 verification. `key_id` selects a pinned public key and its
  allowed issuer. No `alg` field. No online check at connect time.
- The Client compares `/serverinfo` `uniqueid` before it sends the admission
  or the OS password. The admission stays in memory.
- `require_admission` is per Host and defaults false. A Client cannot turn it
  off. Rollback is setting it back to false. Active QUIC is left alone.
- The facility network already routes the Client to the workstation. The
  bundle carries that address as a hint. The Broker does not create a path.
- Facility login uses the existing identity provider and Duo. OS passwords
  never enter the Broker. A suggested OS username may prefill the Client and
  grants nothing.
- v1 occupancy is a Broker reservation with a deadline. The Broker does not
  claim to know who is sitting at the machine. The Host still enforces seat
  ownership.
- One artist operation: request a connection to a workstation. That authorizes,
  reserves, and signs. Releasing a reservation does not end a stream.
- Key removal is a Host configuration change. There is no online revoke channel
  in v1. Unconsumed tickets die at `expires_at`.

Recommended starting policy, configured on the Host, not baked into PLAD:
maximum signed lifetime 15 minutes, clock skew 60 seconds, issued tickets
shorter than that maximum. Administrators can change the numbers.

## Phase 0 — Qualify the admission already in this tree

Do this before any Broker service. The codec tests passed on this Mac.
Live PAM, Open Directory, reboot, and the Qt client have not.

On one Linux Host and one macOS Host:

- Unmanaged Host, current Client: login unchanged.
- Managed Host, current Client: `auth/start` returns 401
  `admission_rejected` and does not reach PAM or Open Directory.
- Managed Host, test bundle from `scripts/test/run-admission-codec.sh`:
  valid ticket is consumed, then the existing OS login runs.
- Replay, including after a worker restart and after a Host reboot.
- Wrong `uniqueid`: rejected, consume file absent, ticket still usable on
  the intended Host.
- PAM or Open Directory failure: the same ticket is rejected on the next try.
- Client pointed at the other Host: it stops before `POST /plank/auth/start`.

Gate: those cases pass on both operating systems. Then start the Broker.

## Phase 1 — Separate Broker that signs the same bytes

New repository. No identity provider yet.

- Workstation inventory: `uniqueid`, routing address, optional certificate
  SHA-256, display name. Address is not identity.
- One Ed25519 signing key, `key_id` such as `broker-2026-01`. Private key
  stays on the Broker. Hosts receive only the public key through the existing
  Linux `admission_trust` string or macOS `admission.plist`.
- An admin action mints a PLAD v1 admission with the encoder rules already
  implemented in `apps/host/linux/src/auth/plank_admission.c`.
- Enroll one Linux Host and one macOS Host with `require_admission=true`.
- A Client using the existing in-memory bundle path connects. Phase 0 cases
  still pass when the signer is this service instead of the test process.

No database product requirement beyond what is needed to store inventory,
the public key id, and an audit row. Do not build a UI beyond the minimum
admin mint.

## Phase 2 — Facility identity

- Broker login is the existing identity provider plus Duo.
- A facility session names a facility principal. That principal is the
  admission `subject`.
- It is not an OS user, a UID, or a Host session token.
- OS passwords and PAM conversations never appear in Broker requests, logs,
  or storage.
- Roles needed for v1: a person who may request a workstation, and an
  admin who may enroll a Host and mint or revoke an unconsumed reservation.

## Phase 3 — Request a connection

One operation, authenticated by the facility session:

```text
request connection to workstation uniqueid
  → authorize the principal for that workstation
  → atomic reservation
  → sign one admission
  → return a memory bundle
```

The bundle contains the admission wrapper, the routing address, the
workstation `uniqueid`, `expires_at` for display, and the optional
certificate pin. It does not contain `request_id`. The Host never sees
`request_id`.

Rules:

- Two concurrent requests for one workstation produce one reservation.
- A second request uses a new `admission_id` only after the first reservation
  is released or expired.
- Retry of the same client request id returns the original bundle and does
  not reserve twice.
- Release frees the workstation at the Broker. It does not consume or refund
  the Host record, and it does not stop QUIC.
- The Client stores the bundle in the memory already used by
  `NvHTTP::setAdmissionBundle`. Replace `PLANK_ADMISSION_BUNDLE` as the
  normal path. Keep that environment variable only as a development injector.
- The Client still performs the `/serverinfo` `uniqueid` check before
  `auth/start`.

This phase changes the Client in this repository. It does not change
`/plank/auth/respond`, launch, resume, or QUIC.

## Phase 4 — Per-Host enforcement

- Enroll Hosts one at a time. Inventory and a pinned key with
  `require_admission=false` changes nothing for current Clients.
- Turn on `require_admission` only after that Host's Phase 0 checks pass
  with Broker-signed tickets.
- A mixed estate is normal. Unmanaged Hosts keep today's login.
- Rollback for one Host is `require_admission=false`. Outstanding tickets
  expire. An active stream keeps running.
- Removing a `key_id` from Host configuration rejects later tickets signed
  by that key. Tickets signed by a key that is still pinned keep working.

## Later, not v1

- Heartbeat and a better occupancy cache. Still no OS account name in that
  cache. Mac already publishes a boolean occupied flag; Linux does not.
- Pool, project, GPU, and application filters. Those choose a workstation.
  They do not become admission fields.
- Pushing quarantine or stream termination to a Host.
- Automated distribution of Host trust configuration.
- A Broker-to-Host control channel.

## Out of scope

VPN or other overlay. Media relay. Replacing PAM, Open Directory, seat
checks, takeover, or `start_desktop`. An allowlist inside PLANK. Client
certificates. Online admission checks. Pairing, UPnP, or ENet. Putting the
Broker private key on a Host, or a Host private key on the Broker.

## Done when

A person signs in through the existing identity provider and Duo, is given
one workstation, and receives a short-lived admission. The Client checks
that workstation's `uniqueid`, then the Host verifies and consumes the
admission and continues with today's OS login and today's stream. Another
person cannot use the same ticket. The wrong Host rejects it without
consuming it. A Host that does not require admission still works exactly
as it does today.
