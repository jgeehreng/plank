# PLANK Broker — Admission wire contract and Host/Client integration

**Status:** Design only. No Broker, Host, Client, protocol, or config implementation.

**Date:** 2026-09-22

**Checkout:** `jgeehreng/plank` (fork of `instinctual/plank`), branch `uppercut/studio`.

**Baselines:**

- `docs/development/investigations/plank-broker-architecture-review.md`
- `docs/development/investigations/plank-broker-admission-trust-design.md`
- `docs/development/investigations/plank-broker-api-state-data-architecture.md`

**This document answers:** Exactly which bytes are a PLANK Broker admission, who signs them, who trusts the signing key, how the Host verifies them, when they are consumed, how replay is prevented, how the Client presents them, how Host identity is checked, what each failure does, and what existing PLANK behavior stays unchanged.

**Non-goals:** Language, database, IdP, Duo SDK, REST/gRPC, JWT, deployment. TTL and clock-skew *numbers* stay policy (section 8).

---

## 1. Status and scope

The control plane stays:

```text
User → IdP → Duo → Broker → signed admission → Client
Client ══ direct TLS then QUIC ══ Host
Host: verify admission → PAM / Open Directory → existing ownership → Host tokens → QUIC
```

The Broker does not proxy video, audio, input, QUIC, kymux, Wacom, or capture.

This pass specifies the **admission bytes** and the **Host/Client presentation contract** only. It does not implement a production Broker.

---

## 2. Source verification

No contradiction requires abandoning Model A, uniqueid binding, or offline verification.

Facts that constrain the wire:

| Fact | Source |
| --- | --- |
| `POST /plank/auth/start` JSON is `username` plus optional boolean `start_desktop` | Client `NvHTTP::authenticate` in `apps/client/app/backend/nvhttp.cpp` |
| Linux accepts that body and **ignores unknown JSON keys** | `nvhttp.cpp` `auth_start` checks `username` and `start_desktop` only |
| macOS **rejects** any other key: body count must be 1 or 2 | `plankMacAuthStartBody` in `apps/host/macos/control/https-auth-server.m` |
| macOS ignores `start_desktop` (does not start/destroy the console) | Comment above `plankMacOptionalStartDesktop` |
| Linux `start_desktop` omitted defaults true; `false` skips GDM start | `read_start_desktop` / `maybe_start_user_session_after_pam` |
| Linux body cap 64 KiB; Mac body cap 32768; Mac header cap 4096 | `read_auth_json`; `docs/architecture/macos-control-plane.md` |
| Peer identity is the accepted TCP address, not a header | `authentication_peer()`; Mac HTTPS server |
| Linux `uniqueid` is a canonical lowercase UUID in `plank-state.json` | `uuid.h` `string()`; `nvhttp.cpp` `load_state` / `save_state` |
| Mac `uniqueid` is lowercase `NSUUID` from Host config | `server-information.m`; `host-main.m` |
| `PlankWorkerInstance` is process-local | `nvhttp.cpp` `worker_instance_id()` |
| Linux HTTP token is in-memory, peer-bound, 300 s wall from issue, monotonic clock in `web_auth` | `web_auth.cpp` `expire_locked` uses `steady_clock` |
| Mac HTTP token removed at `claimToken:`; `transport_token` is separate | `authentication-session.m` |
| Client cert check is profile-based self-signed RSA ≥3072, DNS SAN, no IP SAN, TLS 1.3 | `isPlankCertificate` |
| Bookmark UUID match | `NvComputer::acceptsServerUuid` |
| Host TLS sign primitive today is RSA + SHA-256 | `crypto.cpp` `sign256` / `gen_creds(..., 3072)` |
| Passwords and tokens must not be logged | `protocol/authentication.md` |

**Source disagreement to keep visible (not papered over):**

1. **Linux ignores extra `auth/start` keys. macOS rejects them.** Adding `admission` is a real Mac parser change and a real Linux *check* (today Linux would skip an admission field and still start PAM). A managed Host that has not been updated must not be treated as enforcing. Enforcement exists only after the Host code path in section 9 exists.
2. **Host token clocks are monotonic and process-local. Admission time is absolute.** Do not store admission expiry on `web_auth_manager_t`'s `steady_clock`. A worker restart resets monotonic time and in-memory maps (`web_auth` tokens, Mac `_tokens`). An in-memory consume-set would make a consumed admission reusable after worker replacement. Resolution is in section 7: machine-stable consume-set, not the PAM token map.
3. **Mac `start_desktop` is not a console grant.** It must stay out of the admission. Linux still owns skip-GDM after PAM.

These do not change Model A. They change where the bytes are checked and where the consume-set lives.

---

## 3. Approved architectural invariants

1. Address is routing, not identity.
2. Admission binds to workstation `uniqueid`, not IP, DNS, hostname, `PlankWorkerInstance`, or Client/TCP peer.
3. Consume happens after cryptographic and binding checks and **before** PAM/OD. PAM failure does not refund the admission.
4. Short TTL, unique `admission_id`, signature, Host consume-set. One copy cannot be used twice or on another workstation. It is not a Host session credential.
5. Broker `revoked` is not an instant Host kill unless that Host has learned the id. Otherwise the ticket lasts until `expires_at`.
6. Host PAM/OD, seat0, stream 409, and takeover always beat the Broker.
7. Broker `available` is operational, possibly stale.
8. Host→Broker connectivity is never required to verify an admission.
9. `request_id` (Broker retry idempotency) is not `admission_id` (signed security id). `request_id` is **not** inside the signed admission.
10. `ReleaseReservation` frees an unused Broker reservation. It does not stop QUIC, revoke a Host Bearer, or log out the OS user. After consume, the Broker does not own the PLANK session.

---

## 4. Admission object

Meaning, unchanged:

> Facility principal P may attempt PLANK HTTPS authentication against workstation W (`uniqueid`) until T, purpose `connect-attempt`, audience `plank-host`.

### Required signed fields

| Field | Type | Rule |
| --- | --- | --- |
| `issuer` | UTF-8 | 1–64 bytes. Token charset `A-Za-z0-9._-`. Names the Broker trust domain. |
| `key_id` | UTF-8 | 1–64 bytes. Same charset. Selects the Host's pinned public key. **Not** an algorithm name. |
| `admission_id` | UUID | Canonical lowercase `8-4-4-4-12`. Unique per issued ticket. |
| `subject` | UTF-8 | 1–256 bytes. Facility principal id. No U+0000, CR, or LF. Host must not treat it as a UID or OS username. |
| `workstation_uniqueid` | UUID | Canonical lowercase UUID. Matches this Host's persisted `uniqueid`, ignoring letter case. |
| `issued_at` | decimal | ASCII Unix seconds, no sign, no fraction, no leading zeros except `0`. |
| `expires_at` | decimal | Same. Must be greater than `issued_at`. |
| `audience` | literal | Exactly `plank-host`. |
| `purpose` | literal | Exactly `connect-attempt`. |

No other signed fields in version 1. Unknown fields are a malformed admission.

### Explicitly excluded

| Candidate | Why it stays out |
| --- | --- |
| OS username | Would become an allowlist. PAM/OD maps the name the user types. |
| Client IP / device id | No Client key. Host already binds **Host** tokens to TCP peer after PAM. |
| Application, project, department, GPU, Wacom, display, OS/Host version, site | Allocation policy. Admission names the workstation already chosen. |
| Takeover, `start_desktop` | Host/Client already. Ticket must not skip GDM or override 409. |
| Host address / hostname | Routing. A DNS change must not change the ticket. |
| `request_id` | Broker idempotency only. |
| `alg` | Algorithm is fixed by version and by the key the Host pinned. A message `alg` is an algorithm-confusion bug. |
| Worker instance | Process-local. |

`subject` is in the ticket so the Host audit log can record who the Broker named. It is not an authorization input for PAM.

---

## 5. Canonical encoding

### Why this encoding

- **Not JWT.** JWT carries `alg` in the header, is a bearer-session convention, and would be confused with Host `session_token`.
- **Not re-signed JSON.** Key order, Unicode, and whitespace change bytes. Linux and macOS JSON libraries do not produce one canonical form.
- **Not the PAM `PLAP` frame.** That is local root IPC (`pam_broker_protocol.h`), not a Client object.
- **Not Host TLS.** `crypto::sign256` signs with the Host leaf. Admission keys are a different key.

Version 1 is a **length-prefixed UTF-8 document** plus a detached signature. Length prefixes avoid delimiter bugs in `subject`. Both Hosts can parse it without a JOSE stack. The version byte freezes the algorithm (section 6), so there is no per-message `alg`.

### Canonical payload bytes

All integers below are **big-endian**.

```text
offset 0:  4 bytes ASCII "PLAD"
offset 4:  uint8 version = 1
then nine fields, in this exact order, each:
  uint16 length
  length bytes of UTF-8 (no U+0000)
```

Field order:

1. `issuer`
2. `key_id`
3. `admission_id`
4. `subject`
5. `workstation_uniqueid`
6. `issued_at`
7. `expires_at`
8. `audience`
9. `purpose`

Rules:

- No extra bytes before, between, or after the nine fields.
- `admission_id` and `workstation_uniqueid` are exactly 36 ASCII bytes, lowercase hex and hyphens, matching Linux `uuid_t::string()` / Mac `UUIDString.lowercaseString`. The signed field stays lowercase. A Host whose persisted `uniqueid` differs only by letter case still matches; a different UUID does not. The Client uses that same comparison against `/serverinfo` before `POST /plank/auth/start`.
- `audience` is the 10 ASCII bytes `plank-host`.
- `purpose` is the 15 ASCII bytes `connect-attempt`.
- Timestamps are ASCII digits only.
- `issued_at` numeric value `<` `expires_at`.
- Payload length is at most 1024 bytes (fits Mac's 32768-byte HTTP body after base64 and JSON).

The signature is **not** inside this payload.

### Transport wrapper (not signed)

The Client places one JSON object on `auth/start`. The wrapper is transport. The Host verifies the signature over the **decoded payload bytes**, then parses those bytes. The Host must not canonicalize the wrapper and must not trust wrapper copies of `uniqueid` or `expires_at`.

```text
admission = {
  "v": 1,
  "payload": "<base64url, no padding, of canonical payload>",
  "sig": "<base64url, no padding, of the signature>"
}
```

`v` must equal the payload version byte. If they differ, the admission is malformed (do not consume).

Base64url is RFC 4648 §5, no `=` padding. Reject standard base64 (`+`, `/`, padding).

---

## 6. Signing and trust

```text
Broker private signing key  (never on a Host)
        signs canonical payload bytes
        ↓
payload || sig
        ↓
Host looks up key_id in its local pin set
        verifies with that public key only
        does not read an algorithm from the message
```

### Version-1 algorithm

**Ed25519.** The signature is exactly 64 bytes. `key_id` on a version-1 pin is an Ed25519 public key (32 bytes).

Why this, and not the existing RSA-SHA256 Host leaf path:

- Host TLS keys are RSA-3072 and already have a different job (`generate-plank-certificate.sh`, `crypto::gen_creds`). Reusing that algorithm invites operators to pin the Host leaf as the Broker key.
- Version 1 has one algorithm. There is no `alg` field to swap.
- OpenSSL 3 (Rocky 9) and Apple Security.framework can both verify Ed25519. That is a protocol constant, not a Broker language choice.

A later version may add a new version byte. Hosts reject version bytes they do not implement. They do not "try RSA if Ed25519 fails."

### Key roles (not interchangeable)

| Object | Lives | Used for |
| --- | --- | --- |
| Broker Ed25519 private key | Broker secret store | Sign payload |
| Broker public key, named by `key_id` | Host local config | Verify payload |
| Host TLS private key | Host `/etc/plank/tls` or Mac identity | HTTPS and QUIC |
| Host registration credential | Optional Host→Broker channel | Heartbeat/commands only |
| `uniqueid` | Host state file / Mac config | Workstation bind |

### Rotation

- Broker signs new tickets with `key_id` of the active key.
- Host may pin more than one public key.
- Drain: stop signing with the old id; wait until `expires_at` of the last old ticket; Host removes that pin.
- Tickets do not change meaning when a Host's IP or DNS changes.
- **Signing-key compromise:** remove that `key_id` from Hosts. Outstanding tickets for that id die when the pin is gone, even if `expires_at` is in the future. Hosts that have not received the pin update keep accepting until TTL or until an operator edits Host config. That lag is the same class of problem as shipping a new `host.conf`. It is not online Broker verify.
- **Stale Host pins:** a Host that only has a retired key rejects new tickets (`unknown key_id` locally). A Host that still has a retired key accepts those tickets until the pin is removed. Operators must push pin updates. The protocol does not phone home to check.
- **Broker down:** verification uses only the pin and the consume-set.
- **Host quarantine:** local Host flag refuses `auth/start` even if the signature is valid. Separate from key pins.

The private key is never installed on a Host.

---

## 7. Replay and consume semantics

### When consume happens

```text
POST /plank/auth/start
  → parse JSON
  → if require_admission: decode wrapper, verify sig, parse PLAD
  → check issuer, audience, purpose, uniqueid, times, skew, max TTL
  → if admission_id already in consume-set: reject, do not start PAM
  → INSERT admission_id into consume-set   ← consume
  → existing username / start_desktop / PAM or OD
```

Consume is the insert, and it happens **before** `web_auth->begin` / `startForPeer`.

```text
valid admission → consumed → PAM fails
```

The id stays consumed until `expires_at` + skew. The Client must get a new admission. This is intentional. Refunding on PAM failure would let a stolen ticket be reused for password guessing.

Do **not** consume when:

- signature, version, or parse fails
- `uniqueid` does not match this Host
- time is outside the window
- `require_admission` is false and the field is absent
- the request is `auth/respond`, launch, or resume (those use Host tokens)

A wrong-workstation Host must not burn the id. The Client can still present it to the correct Host.

### What is stored

Machine-stable set, not the media-worker heap:

| Column | Notes |
| --- | --- |
| `admission_id` | Primary key |
| `expires_at` | Unix seconds from the signed payload |
| `key_id` | For local audit only |

No payload, signature, subject, or password.

**Where:** same trust boundary as `uniqueid` persistence.

- Linux: root-owned file beside state, e.g. under `/var/lib/plank/`, not inside `web_auth`'s in-memory maps. `plank-state.json` today stores only `root.uniqueid` (`save_state`). Do not overload that JSON with a growing list if a separate file is cleaner; either way it must survive worker replacement.
- macOS: machine-coordinator scope, not only `PLANKMacAuthenticationSession` (that object is wiped by `revokeAll` and agent replacement).

**Retention:** delete entries with `expires_at + skew < now`. Not a forever log. The protocol needs no history older than the longest accepted ticket.

**Worker replacement:** `PlankWorkerInstance` changes (`worker_instance_id()`). `uniqueid` does not. The consume-set must remain. If it lived only in the worker, replacement would replay. That is why it is machine-stable.

**Host reboot:** same store. In-memory Host Bearers die (current behavior). Consumed admissions stay consumed.

**Two racing `auth/start` calls, same id:** one insert wins. The loser gets the same client-visible admission failure as a replay (section 13). The winner proceeds to PAM. Lock around check-and-insert.

**Process crash after insert, before PAM:** id stays spent. Correct.

---

## 8. Time semantics

| Clock | Use |
| --- | --- |
| Unix wall time | `issued_at`, `expires_at`, consume-set purge |
| Monotonic `steady_clock` | Existing Host conversation/token lifetimes only (`web_auth.h`) |

Do not compare admission expiry to monotonic time. A worker restart must not move admission deadlines.

Checks, in order, using Host wall clock `now`:

1. `expires_at > issued_at`
2. `expires_at - issued_at <= max_ttl` (Host config)
3. `now + skew >= issued_at` (not too far in the future)
4. `now - skew <= expires_at` (not expired)

**`max_ttl` and `skew` are policy, not fixed in this contract.** A Host with `require_admission=true` must have both set. If either is missing, the Host fails closed (refuses admission attempts) rather than accepting unbounded tickets.

This document does **not** choose the numbers. The test milestone (section 22) uses a fixture whose `expires_at` lies inside whatever window the test Host is configured with.

Expired, not-yet-valid, and over-long lifetime are rejected **without** consume.

---

## 9. Host verification boundary

Smallest integration: the existing HTTPS start handler, before OS authentication.

### Linux

`nvhttp.cpp` `auth_start`, after `read_auth_json` and the existing `username` / `start_desktop` checks, **before** `web_auth->begin`.

Do not put it in:

- `web_auth_manager_t` (PAM token map; monotonic clock)
- `session_context` (seat0 attestation)
- `session_stream` (already an authorized launch)
- launch/resume (too late; PAM would already have run)

`maybe_start_user_session_after_pam` stays after PAM success and still honors `start_desktop`.

### macOS

`https-auth-server.m` `handlePath` for `/plank/auth/start`, after JSON parse, **before** `startForPeer:`.

`plankMacAuthStartBody` today requires `body.count` of 1 or 2. A future implementation must allow exactly one additional key, `admission`, and no others. Do not put the check in `PLANKMacGraphicalAuthority` or `agent-connection` machine admission.

Graphical generation, `transport_token`, and `revokeAll` stay as they are.

### Shared behavior

Same payload, signature, consume-set rules. Different code. If `require_admission` is false, absence of `admission` is today's path. Presence on a standalone Host is ignored (section 15).

---

## 10. Client presentation contract

### Bundle (from Broker or from a test fixture)

In Client memory only:

- opaque `admission` object (`v`, `payload`, `sig`)
- routing address (host, port 28989)
- expected `workstation_uniqueid`
- `expires_at` for UI (advisory; Host trusts the signed payload)
- optional TLS SHA-256 pin

Not written to bookmarks, settings, logs, or URLs. Same secrecy class as the in-memory Host password (`protocol/authentication.md`).

`request_id` never goes to the Host.

### On the wire

Extend `POST /plank/auth/start` JSON. Client today sends:

```text
{ "username", "start_desktop" }
```

Managed attempt sends:

```text
{ "username", "start_desktop", "admission": { "v", "payload", "sig" } }
```

`auth/respond` does **not** carry the admission again. The consume already happened. Repeating it would look like a replay.

### Why this, and not a header

- Auth secrets already travel in the JSON body, not headers or URLs (`protocol/authentication.md`).
- Mac rejects odd framing, folded headers, and `Transfer-Encoding` (`macos-control-plane.md`). A new `X-Plank-Admission` header would be a second identity channel and would invite forwarding-header bugs. Peer identity stays the socket address.
- There is no pre-auth PLANK message that is both Client-implemented and free of PAM. `/serverinfo` is discovery and must stay credential-free.
- A dedicated round trip would be a new protocol. One field on the existing start body is the smallest change that still sits **before** PAM/OD.

### Idempotent Broker retry (not Host)

If the Client retries `RequestConnection` with the same `request_id` because the Broker response was lost, the Broker returns the **same** `admission_id` and the same payload bytes. It does not reserve a second ticket. That logic is Broker-side. The Host only sees `admission_id`.

---

## 11. Host identity verification

Before the Client sends the OS password **or** the admission:

```text
TCP to the routing address
  → TLS 1.3
  → existing isPlankCertificate profile
  → if the bundle has a pin: cert SHA-256 must match (same compare as hostrecovery expectedCertificate)
  → GET /serverinfo (no Bearer, no admission)
  → uniqueid must equal the bundle workstation_uniqueid
     (manual bookmarks: acceptsServerUuid)
  → only then POST /plank/auth/start with username, start_desktop, admission
```

The Broker address is not checked against a signed hostname. The signed bind is `uniqueid`. The TLS pin, when present, stops a different leaf at that address. Existing profile checks stay; the pin is additional when the bundle has one.

If `/serverinfo` uniqueid mismatches, the Client stops. It does not send the admission (so a confused dial does not depend on the wrong Host being honest about not consuming).

Linux `/serverinfo` is unauthenticated and already returns `uniqueid` (`nvhttp.cpp` `serverinfo`). Mac discovery returns `uniqueid` and does not return account identity (`server-information.m`).

---

## 12. Failure behavior

Client-visible admission failures are one result (section 13). Local logs may be specific. "Consumed?" is the Host consume-set. "New ticket?" means a new Broker admission before another `auth/start`.

| Case | Consumed? | Client result | Retry `auth/start` with same ticket? | New admission? |
| --- | --- | --- | --- | --- |
| 1. Missing, and required | No | Admission failure | No | Yes |
| 2. Malformed | No | Admission failure | No | Yes |
| 3. Bad signature | No | Admission failure | No | Yes |
| 4. Unknown `key_id` | No | Admission failure | No | Yes, after pins fixed |
| 5. Issuer not accepted for that key | No | Admission failure | No | Yes |
| 6. Wrong audience | No | Admission failure | No | Yes |
| 7. Wrong purpose | No | Admission failure | No | Yes |
| 8. Wrong `uniqueid` | **No** | Client should have stopped at `/serverinfo`. If sent, Host admission failure | Only against the correct Host | No, if the ticket itself is still valid |
| 9. Not yet valid | No | Admission failure | After skew window only if still inside `expires_at` | Usually yes |
| 10. Expired | No | Admission failure | No | Yes |
| 11. Replay | Already consumed | Admission failure | No | Yes |
| 12. Revoked **and Host was told** | No, unless already consumed | Admission failure | No | Yes |
| 13. Broker down, ticket already in memory | Verify locally | Connect can proceed | — | No |
| 14. Host→Broker down | Verify locally | No effect on this check | — | No |
| 15. Client lost Broker after bundle issued | Ticket still in memory | Connect Host | — | No |
| 16. Client lost Host before start | Not consumed if start never accepted | Existing connect failure | Same ticket if unexpired | No |
| 17. PAM/OD fails after consume | **Yes** | Existing `denied` / 401 | No | **Yes** |
| 18. Host 409 / active stream | Admission already consumed at start; launch uses Host Bearer | Existing 409 | Launch retry is existing takeover rules, not a new admission | No, while Bearer lives |
| 19. Desktop owned by another OS user | Consume already done; Linux `authenticated_account_uid_for_desktop` cancels Host token | Existing 403 | No | Yes for a new attempt |
| 20. Worker restart | Consume-set remains if machine-stable | Old Bearer dead (in-memory). New login needs a **new** admission if the old one was consumed or expired | No | Yes for a new `auth/start` |
| 21. Host reboot | Consume-set remains; Bearers gone | Same as worker restart for tokens | No | Yes for a new `auth/start` |
| 22. Signing-key rotation | Old key verifies only while pinned | New tickets use new `key_id` | Old ticket until TTL if old pin remains | No until pin removed |

Broker-side `ReleaseReservation` on an **unconsumed** ticket does not by itself make the signature fail. The Client might still hold the bytes. Releasing the reservation stops a second allocate; it does not erase a signature. To stop presentation, the Host must learn a revoke or the ticket must expire. v1 test milestone does not need online revoke.

PAM failure after consume does **not** change Broker occupancy to `in_use`. The reservation stays until TTL or an explicit release. That split is the Prompt 3 rule: Broker does not observe consume in v1.

---

## 13. Security error semantics

Before PAM, every admission reject is the same Client-visible JSON:

```text
{ "state": "admission_rejected" }
```

HTTP 401. No distinction among signature, key id, issuer, audience, purpose, uniqueid, time, replay, or local revoke.

Reasons:

- Different strings would tell an attacker which check failed.
- Operators still get a **local** log reason code (`bad_signature`, `expired`, `replay`, …) with `admission_id` and `key_id`, never the payload signature or `subject` if local policy says subject is sensitive. Default local log: reason code, `key_id`, `admission_id`, `uniqueid`. Not `subject` unless an admin audit sink is separate.
- Do not use 403 (ownership), 409 (busy stream), or `denied` (PAM/OD). Those stay exactly as they are today so a PAM failure is not disguised as a bad ticket and a bad ticket is not retried as a wrong password.

Missing admission when required uses the same `admission_rejected`. Standalone Hosts do not emit this state.

Mac body that is neither the legacy shape nor the one extra `admission` key stays the existing invalid-request / denied path (400), not a new oracle.

---

## 14. Host configuration

Conceptual keys only (not a file format):

| Key | Meaning |
| --- | --- |
| `require_admission` | Default **false**. If true, `auth/start` requires a valid admission. |
| Pinned keys | Set of `key_id` → Ed25519 public key, each with allowed `issuer`. |
| `admission_max_ttl` | Rejects longer signed lifetimes. Required if `require_admission`. Number is policy. |
| `admission_clock_skew` | Future/past tolerance. Required if `require_admission`. Number is policy. |
| `quarantine` | If true, `auth/start` fails closed even with a valid ticket. |

Invalid combinations fail closed:

- `require_admission=true` with no pins, no max TTL, or no skew → do not start the network service, or reject all starts. Do not fall open.
- Unknown `key_id` on a ticket → `admission_rejected`.
- Client cannot send a flag to set `require_admission=false`.

Rollback: set `require_admission=false`. Outstanding tickets become irrelevant. Live QUIC is untouched. Pins may stay installed.

Quarantine is stronger than rollback: it blocks new OS logins through PLANK even for a valid ticket. It does not by itself kill an existing QUIC session (that remains `terminate_sessions` / `revokeAll`).

---

## 15. Backward compatibility

| Pair | Behavior |
| --- | --- |
| Existing Client → unmanaged Host | Unchanged. No `admission` field. |
| New Client → unmanaged Host | Direct bookmarks unchanged. If a bundle is used anyway, Host **ignores** `admission` when `require_admission=false`. |
| Existing Client → managed Host | No admission field → `admission_rejected`. No silent fallback. |
| New Client → managed Host | Bundle, then `auth/start` with `admission`. |
| Mixed estate | Per Host flag. No global cutover. |

Ignoring a presented admission on an unmanaged Host keeps mixed estates working. Enforcing on a managed Host does not depend on Client goodwill.

Linux today ignores unknown keys, so an **unmodified** Linux binary is unmanaged-by-accident even if an operator wishes it were managed. Managed means the new check is actually running. Do not document current Linux as already enforcing.

macOS today **rejects** unknown keys, so an unmodified Mac Host returns invalid body if a new Client sends `admission`. That is fail-closed for the new field, and it also means a new Client must not send `admission` to an old Mac Host. Client rule: send `admission` only for a bundle the operator marked managed, not on every bookmark.

---

## 16. Provisioning and trust bootstrap

```text
Administrator
  → creates Broker signing key (private stays on Broker)
  → enrolls workstation uniqueid in Broker inventory
  → installs on the Host: require_admission, issuer, key_id, public key, max_ttl, skew
  → optionally installs a Host→Broker registration credential (heartbeat only)
  → does not copy Host TLS key to the Broker
  → does not treat a machine as enrolled because it announced a uniqueid
```

Enrollment is an administrator action. No self-enrollment.

`uniqueid` in `/serverinfo` is not proof the Broker trusts that machine. The Broker's inventory is a separate list. A Host verifies tickets with **its** pins; a Client verifies the Host with TLS profile, optional pin, and `uniqueid` match.

Registration credentials never sign admissions. Host TLS keys never sign admissions.

---

## 17. Credential boundary comparison

| Credential | Issuer | Purpose | Lifetime | Bound to | Verified by |
| --- | --- | --- | --- | --- | --- |
| Facility session | IdP + Broker | Call Broker APIs | IdP/Broker policy | Facility principal | Broker |
| Duo/MFA state | Duo | Fresh facility auth / admin step-up | IdP/Duo policy | Facility principal | Broker |
| Broker admission | Broker Ed25519 key | Attempt `auth/start` on one workstation | `issued_at`..`expires_at` (≤ Host max TTL) | `uniqueid` + `admission_id` | Host, offline, pinned `key_id` |
| Linux HTTP `session_token` | Host `web_auth` after PAM | Bearer for launch/resume | 300 s from issue; peer-bound; claim may share PAM handle | TCP peer + PAM username | Host `authorize` / `claim` |
| Mac HTTP `session_token` | Host after OD | Bearer until claim | 300 s; removed at claim | TCP peer + UID/UUID + generation | `authorizeToken:` |
| Mac `transport_token` | Host `claimToken:` | QUIC after claim | 15 s to activate | That lease | Host stream lease |
| Kyber `ClientAuth` | Transport setup | QUIC application token | Connection | QUIC connection | kymux |

The admission is not any row below it. It is spent before those rows are created. `auth/respond` and launch do not carry it.

---

## 18. Allocation policy vs admission

These stay Broker-side filters when choosing W. They are not version-1 payload fields:

application, project, department, pool, GPU, Wacom, display topology, OS version, Host version, site/room, takeover, `start_desktop`.

The signed result is only "principal P may attempt workstation W until T."

---

## 19. Privacy and audit

| Data | Client | Host verify | Host local log | Broker audit |
| --- | --- | --- | --- | --- |
| `payload` / `sig` | Memory only | Verify then discard sig | **Never** | Store id, not raw sig, if the Broker already has the ticket |
| `subject` | Opaque inside payload | Not used for PAM | Omit from routine logs | Yes, as facility id |
| `admission_id`, `key_id`, `uniqueid` | Bundle | Consume-set | Yes | Yes |
| OS password | Sent only to Host after identity checks | PAM/OD | **Never** | **Never** |
| IdP access token | Never to Host | Never | Never | Never in PLANK logs |

Do not log PAM conversation text, private keys, or signatures (`protocol/authentication.md`).

---

## 20. Explicit non-changes

Unchanged: QUIC, kymux, FEC, video, audio, input, Wacom, NvFBC, VideoToolbox, launch and resume bodies, takeover (`plankTakeover`), `start_desktop` meaning, PAM conversation (`/plank/auth/respond`), Open Directory verification, Host Bearer and Mac `transport_token` rules, peer-IP binding, `/serverinfo` credential-free discovery, graphical authority, machine XPC admission, worker-instance vs `uniqueid`, no media proxy, no Client device key, no UPnP, no pairing.

The only future protocol addition is an optional `admission` object on `POST /plank/auth/start`, plus Host config to require it.

---

## 21. Open questions

**Not open (this contract fixes them):**

- Bytes of version 1, field order, Ed25519, detached signature, wrapper JSON, consume-before-PAM, machine-stable consume-set, generic `admission_rejected`, no header, no `alg`, no OS username.

**Still policy (do not invent here):**

1. Numeric `admission_max_ttl` and `admission_clock_skew`.
2. Whether routine Host logs may include `subject`.
3. Reachability source for the bundle address.
4. Occupancy heartbeat and same-user resume.
5. How fast pin removal is pushed after key compromise (operations, not a wire field).

**Implementation note, not a design hole:** macOS must relax `plankMacAuthStartBody` to allow the one new key; Linux must stop ignoring it when `require_admission` is true. Section 2 states that source difference explicitly.

---

## 22. Design readiness assessment

> Can we implement the smallest Host and Client changes needed to accept a test-signed admission, without a production Broker?

**Yes.**

The bytes, trust, consume point, presentation, identity checks, and failure collapse are specified. TTL and skew are Host **configuration inputs**, not unspecified protocol. A test can set them.

No production Broker, IdP, or Duo. No QUIC changes.

### Minimal test fixture

- One Ed25519 key pair generated outside the repo.
- Public key and `key_id` configured on a test Host with `require_admission=true`, a max TTL, and a skew.
- A file or stdin blob: canonical `PLAD` payload plus sig, wrapped as the JSON object in section 5.
- Payload `workstation_uniqueid` equal to that Host's `uniqueid`.
- `expires_at` inside the Host window.

### Minimal code surfaces (later prompt, not this one)

| Piece | Where |
| --- | --- |
| Verify + consume | Linux `auth_start` before `web_auth->begin` |
| Same | Mac `handlePath` before `startForPeer:`; allow `admission` in `plankMacAuthStartBody` |
| Consume-set | Machine-stable store, purged by `expires_at` |
| Config | `require_admission`, pins, max TTL, skew |
| Client | If a test bundle is present: `/serverinfo` uniqueid (and optional pin) **then** add `admission` to the existing `postPlankJson("start", …)` body. Do not persist it. |
| Tests | Accept, reject bad sig, reject wrong uniqueid without consume, second `auth/start` replay, PAM-failure-still-consumed, unmanaged Host ignores field |

---

## 23. Recommended next step

Prompt 5 should be the first implementation pass, narrowly:

1. Host admission verify and consume at the boundaries in section 9.
2. Host configuration for pins, `require_admission`, max TTL, and skew.
3. Machine-stable consume-set.
4. Client test-bundle ingestion and `auth/start` field, after existing uniqueid/TLS checks.
5. Tests listed above, using a test key, not a production Broker.
6. No IdP, Duo, Broker service, or media/QUIC changes.

Do not start Prompt 5 until this wire contract is accepted. The contract is specific enough that an implementer should not have to invent field order, signature input, consume timing, or Client-visible errors.

This file is an investigation note. It does not change the protocol in the tree.
