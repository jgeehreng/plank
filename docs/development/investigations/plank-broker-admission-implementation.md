# PLANK admission verification — implementation report

This is the first Host/Client implementation of the Prompt 4 admission wire contract. It proves a test-signed PLAD v1 admission. It does not implement a Broker, an identity provider, or Duo.

The wire authority remains `docs/development/investigations/plank-broker-admission-wire-contract.md`.

## A. Implementation summary

### Files added

- `apps/host/linux/src/auth/plank_admission.h`
- `apps/host/linux/src/auth/plank_admission.c`
- `tests/auth/test-admission.c`
- `scripts/test/run-admission-codec.sh`

### Files modified

- `apps/host/linux/src/nvhttp.cpp`
- `apps/host/linux/src/config.h`
- `apps/host/linux/src/config.cpp`
- `apps/host/linux/docs/configuration.md`
- `apps/host/linux/tests/integration/test_config_consistency.cpp`
- `apps/host/linux/cmake/compile_definitions/common.cmake`
- `apps/host/linux/cmake/targets/common.cmake`
- `packaging/host/linux/config/plank-host.conf`
- `apps/host/macos/control/https-auth-server.h`
- `apps/host/macos/control/https-auth-server.m`
- `apps/host/macos/session/host-runtime.h`
- `apps/host/macos/session/host-runtime.m`
- `apps/host/macos/session/host-main.m`
- `apps/client/app/backend/nvhttp.h`
- `apps/client/app/backend/nvhttp.cpp`
- `scripts/build/build-macos-host.sh`
- `scripts/test/build-macos-control.sh`
- `scripts/test/build-macos-preview.sh`
- `scripts/test/build-macos-display-recovery.sh`

### Host

Linux `auth_start` parses the existing JSON, then, only when `require_admission` is true, verifies the admission and either returns HTTP 401 `{"state":"admission_rejected"}` or continues into `web_auth->begin`. macOS does the same check inside `/plank/auth/start`, after JSON parsing and before `startForPeer:`.

`maybe_start_user_session_after_pam`, `start_desktop`, PAM/OD, launch, resume, session tokens, and QUIC are untouched.

### Client

`NvHTTP::authenticate` can hold one in-memory admission. If one is present it reads `/serverinfo`, compares `uniqueid` (and an optional certificate SHA-256), and only then posts `/plank/auth/start` with the admission object. `/plank/auth/respond` is unchanged.

### Configuration

Linux keys, under the existing `host.conf` parser, default off:

- `require_admission` (bool, default false)
- `admission_max_ttl` (seconds, 1–604800; unset stays 0)
- `admission_clock_skew` (seconds, 0–86400; unset stays -1)
- `admission_consume_dir` (path; empty derives `<file_state parent>/admissions`)
- `admission_trust` (`key_id|issuer|<base64url 32-byte public key>`, comma-separated, at most 8)

macOS does not add keys to the 4-key public `host.plist`. An optional sibling `admission.plist` in the private configuration directory supplies `RequireAdmission`, `MaxTTL`, `ClockSkew`, `ConsumeDirectory`, and `Trust` entries of `KeyID`, `Issuer`, `PublicKey`. A missing file leaves the host unmanaged.

### Tests

`scripts/test/run-admission-codec.sh` compiles `tests/auth/test-admission.c` with the shared codec twice on this Mac: once with OpenSSL Ed25519 and once with Security.framework. Both runs passed. Keys are generated in the test process and are not committed.

## B. Exact protocol implementation

Canonical payload, produced only by `plank_admission_encode`:

```text
"PLAD" | version 1 | nine fields
```

Each field is a big-endian `uint16` length followed by UTF-8. Order is issuer, key_id, admission_id, subject, workstation_uniqueid, issued_at, expires_at, audience, purpose. No extra bytes. Maximum 1024 bytes. UUIDs are lowercase `8-4-4-4-12`. Timestamps are ASCII Unix seconds with no sign, fraction, or leading zeroes. `audience` must be `plank-host`. `purpose` must be `connect-attempt`.

The wrapper is `{"v":1,"payload":"<base64url>","sig":"<base64url>"}`. `+`, `/`, and `=` are rejected. `v` must equal 1, which is also the payload version byte. The signature is 64 raw Ed25519 bytes over the decoded payload. The host does not reserialize before verifying.

`key_id` selects a pinned 32-byte public key and the one issuer allowed for that key. The version byte selects Ed25519. There is no `alg` field.

Time checks use wall-clock Unix seconds, in this order: `expires_at > issued_at`, lifetime `<= admission_max_ttl`, `now + skew >= issued_at`, `now - skew <= expires_at`. They are not compared to the `web_auth` monotonic clock.

Verification order after a managed `/plank/auth/start` parse: wrapper, base64url, structural payload parse, key lookup, signature, issuer, audience, purpose, workstation `uniqueid`, time, then atomic consume. A wrong `uniqueid` returns before consume.

Every managed failure is HTTP 401 `{"state":"admission_rejected"}`. Local reasons include `bad_signature`, `unknown_key_id`, `issuer_not_allowed`, `wrong_audience`, `wrong_purpose`, `wrong_uniqueid`, `not_yet_valid`, `expired`, `excessive_ttl`, `replay`, `malformed`, `config_invalid`, and `store_error`. Logs may include reason, admission id, key id, and workstation uniqueid. They do not include the signature, payload, subject, or password.

## C. Persistence

The consume-set is a directory of files, not a `web_auth` map. Each file is named by `admission_id` and is created with `openat(O_CREAT|O_EXCL|O_NOFOLLOW)`. The file body is `expires_at\nkey_id\n`. Mode is `0600` for the file and `0700` for the directory. `EEXIST` is replay. The directory fd is `fsync`ed after a successful create.

Linux defaults the directory to `admissions` beside `file_state` (`/var/lib/plank/admissions` in the packaged profile). macOS requires `ConsumeDirectory` when admission is required.

That directory is machine state. It is outside the worker process, so replacing the worker or restarting the process still sees the exclusive file. A host reboot keeps it because it is a normal directory on the host filesystem. Entries may be removed once `expires_at + clock_skew` is before now.

The concurrent test got exactly one accept and one replay. A forked child process, after the parent had consumed the admission, also received replay.

## D. Client behavior

A test bundle enters in one of two ways, both memory-only:

- `NvHTTP::setAdmissionBundle(admission, workstationUniqueId, certificateSha256)`
- environment variable `PLANK_ADMISSION_BUNDLE`, a path to JSON `{ "admission": {...}, "workstation_uniqueid": "...", "certificate_sha256": "..." }`

The file is read into the process. It is not copied into bookmarks, `QSettings`, URLs, or logs. `certificate_sha256` is optional. `expires_at` in that file is not sent and is not trusted; the host trusts the signed payload. `request_id` is not sent.

When a bundle is set, `authenticate` does this before the password can leave the process:

```text
GET /serverinfo
compare uniqueid
optional SHA-256 pin
POST /plank/auth/start
```

A mismatch throws before `postPlankJson`. The start body is `username`, `start_desktop`, and `admission`. The respond body is still `conversation_id`, `responses`, and `start_desktop`.

With no bundle, the client posts the legacy start body.

## E. Security tests

Command: `bash scripts/test/run-admission-codec.sh`

OpenSSL verify and Security.framework verify both printed `all passed` on this Mac (darwin 27, Homebrew OpenSSL 3).

| Test | Result |
| --- | --- |
| PLAD prefix, version, big-endian issuer length, base64url without padding, 64-byte signature | pass |
| Ed25519 over the exact payload bytes | pass |
| One-byte payload change after signing | pass (`bad_signature` at the verify primitive) |
| Valid admission consumed | pass |
| Replay | pass |
| Concurrent pair: one accept, one replay | pass |
| Second use after the first consume, modeling PAM failure with no refund | pass |
| Forked process sees the consumed file | pass |
| Bad signature, not consumed | pass |
| Unknown `key_id`, not consumed | pass |
| Wrong issuer, not consumed | pass |
| Wrong audience (`wrong-host`), not consumed | pass |
| Wrong purpose (`wrong-purpose!`), not consumed | pass |
| Wrong workstation, not consumed | pass |
| Expired, not-yet-valid, excessive TTL, not consumed | pass |
| Wrapper `v` mismatch | pass (`malformed`) |
| Modified payload encoding, standard Base64 `+` | pass |
| Payload longer than 1024 bytes | pass (`malformed`) |
| Two pinned keys, then old key removed | pass |
| `require_admission` false does not consume | pass |
| Managed request with no admission | pass (`malformed`, which the HTTP layer maps to `admission_rejected`) |
| Managed request with invalid trust configuration | pass (`config_invalid`) |
| Uniqueid equality used by the client gate | pass |

Not executed here:

- A live Linux Host PAM conversation, launch, resume, or QUIC session.
- A live macOS Open Directory conversation.
- A packaged Host reboot. The consume record is an `fsync`ed directory entry; this machine was not rebooted.
- The Qt client against a running host. The uniqueid predicate and the order in `NvHTTP::authenticate` were reviewed; the client binary was not built in this pass.
- The Linux `test_config_consistency` binary. The new option names were added to the documented headings and the expected set so that test still matches `config.cpp`.

## F. Compatibility matrix

These are source-level results plus the codec tests. They are not live client/host session results.

| Pair | Result |
| --- | --- |
| Existing client, unmanaged host | `require_admission` defaults false. Linux ignores an absent admission and never enters the verifier. macOS still accepts the legacy body and calls `startForPeer:`. |
| New client, unmanaged host | A presented admission is ignored. The client still posts username and `start_desktop`. No consume file is created (`unmanaged-skips`). |
| Existing client, managed host | No admission object. The codec returns a rejection and the HTTP handlers return 401 `admission_rejected` before PAM/OD. |
| New client, managed host | Admission is required, verified, consumed, then the existing PAM/OD path runs. The PAM continuation itself was not executed live. |
| Wrong host | Codec rejects `wrong_uniqueid` without creating a consume file. Client code throws after `/serverinfo` and before `POST /plank/auth/start`. |
| Replay | Pass, including two threads and a second process. |
| Worker restart | Pass as a new process reading the same directory. A real `plank` worker replacement was not run. |
| PAM failure | The consume record is not removed by the verifier or by `auth_start`. A second presentation is replay. A real PAM failure was not run. |

## G. Deviations

1. The codec is compiled from `apps/host/linux/src/auth/plank_admission.c` on both hosts. `PLANK_ROOT_DIR` in the Linux CMake files is `apps/`, not the repository root, so a `protocol/admission` path would not have been on the host target. There is still one encoder. The Mac build scripts compile that same file.

2. The macOS 27 Security headers do not declare Ed25519, but `Security.tbd` exports `kSecAttrKeyTypeEd25519` and `kSecKeyAlgorithmEdDSASignatureMessageCurve25519SHA512`. The Mac path uses those exported symbols. The OpenSSL path uses `EVP_PKEY_ED25519`. The same test vectors passed on both.

3. A payload that is not structurally valid (bad UUID, bad timestamp grammar, truncated field, extra bytes, length that does not fit the fixed field buffer) is `malformed` before signature verification. `key_id` is inside the payload, so the host cannot select a key without parsing. A grammar-preserving byte change is `bad_signature`. The host never re-encodes the payload and verifies the re-encoded bytes.

4. There is no separate local-revoke list. `local_revoke` is not produced. Replay is the exclusive-create conflict.

5. When `require_admission` is false the host does not inspect a presented admission at all. That matches "may be ignored" and keeps a new client usable on an unmanaged host.

6. Invalid managed configuration rejects `/plank/auth/start`. The listener can still serve `/serverinfo`.

7. Linux trust material is one existing-style string option. macOS trust material is the sibling plist described above, because the public host plist is rejected unless it has exactly four keys.

8. A wrong audience or purpose that does not fit the fixed field buffer is `malformed` rather than `wrong_audience` or `wrong_purpose`. The client-visible result is still `admission_rejected`, and nothing is consumed. The tests cover same-size and shorter substitutes, which do return the specific reasons.

## Acceptance

Checked in this pass:

- Host codec verifies a real Ed25519 PLAD v1 admission.
- `key_id` selects a configured public key and issuer. It is not the key.
- The signature covers the canonical payload bytes.
- The admission binds to workstation `uniqueid`, not an address.
- Expiry uses Unix wall time. Max TTL and clock skew are configuration.
- Consume is `O_EXCL`, happens inside authorize before the function returns to PAM/OD, and is not undone.
- A second process sees the consume record.
- Wrong-workstation admissions are not consumed.
- Managed missing/invalid admissions reject. Unmanaged mode does not consume and does not require an admission.
- The client gate compares `uniqueid` before it would send the admission.
- The admission object is added only on `auth/start`.
- No Broker, IdP, Duo, or production signing key was added.

Not checked live:

- Linux or macOS host binaries through PAM/OD, launch, resume, and QUIC.
- A physical reboot.
- The Qt client process.

## What the next pass should not assume

The env-file and `setAdmissionBundle` path is a development injector. A Broker should replace it with an in-memory bundle delivered to the client. The host verification path does not need a network call to that Broker.

Linux and macOS already differ in configuration shape and in JSON strictness. Both call the same authorize function. Do not fold the Mac machine-XPC "admission" or `transport_token` into this ticket.

The consume directory survives reboot only as ordinary root-owned host state. It is not replicated, and it is not a workstation identity. `uniqueid` remains the identity.
