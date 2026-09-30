/* SPDX-License-Identifier: GPL-3.0-or-later
 * Test-signed PLAD v1 admissions. The key pair exists only in this process.
 */
#include "plank_admission.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <openssl/evp.h>

static int failures = 0;
static const char *k_host = "11111111-1111-4111-8111-111111111111";
static const char *k_other = "22222222-2222-4222-8222-222222222222";
static char consume_dir[256];
static int64_t now_unix = 1700000000;

#define CHECK(cond, name) do { \
    if (!(cond)) { \
      fprintf(stderr, "FAIL %s\n", name); \
      ++failures; \
    } else { \
      printf("PASS %s\n", name); \
    } \
  } while (0)

static void next_id(char out[37]) {
  static unsigned seq = 0;
  snprintf(out, 37, "aaaaaaaa-bbbb-4ccc-8ddd-%012x", ++seq);
}

static int generate_key(EVP_PKEY **private_key, uint8_t public_key[32]) {
  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, NULL);
  EVP_PKEY *key = NULL;
  size_t len = 32;
  int ok = ctx && EVP_PKEY_keygen_init(ctx) == 1 && EVP_PKEY_keygen(ctx, &key) == 1 &&
      EVP_PKEY_get_raw_public_key(key, public_key, &len) == 1 && len == 32;
  EVP_PKEY_CTX_free(ctx);
  *private_key = ok ? key : NULL;
  if (!ok) EVP_PKEY_free(key);
  return ok;
}

static int sign_bytes(EVP_PKEY *key, const uint8_t *message, size_t len, uint8_t signature[64]) {
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  size_t sig_len = 64;
  int ok = ctx && EVP_DigestSignInit(ctx, NULL, NULL, NULL, key) == 1 &&
      EVP_DigestSign(ctx, signature, &sig_len, message, len) == 1 && sig_len == 64;
  EVP_MD_CTX_free(ctx);
  return ok;
}

static void fill(plank_admission_fields *fields, const char *issuer, const char *key_id,
                 const char *uniqueid, int64_t issued, int64_t expires) {
  memset(fields, 0, sizeof *fields);
  snprintf(fields->issuer, sizeof fields->issuer, "%s", issuer);
  snprintf(fields->key_id, sizeof fields->key_id, "%s", key_id);
  next_id(fields->admission_id);
  snprintf(fields->subject, sizeof fields->subject, "%s", "facility-principal");
  snprintf(fields->workstation_uniqueid, sizeof fields->workstation_uniqueid, "%s", uniqueid);
  snprintf(fields->issued_at, sizeof fields->issued_at, "%lld", (long long) issued);
  snprintf(fields->expires_at, sizeof fields->expires_at, "%lld", (long long) expires);
  snprintf(fields->audience, sizeof fields->audience, "%s", "plank-host");
  snprintf(fields->purpose, sizeof fields->purpose, "%s", "connect-attempt");
}

static int wrap(EVP_PKEY *key, const plank_admission_fields *fields, char *payload_b64, size_t payload_cap,
                char *sig_b64, size_t sig_cap, uint8_t *raw, size_t raw_cap, size_t *raw_len) {
  uint8_t signature[64];
  if (!plank_admission_encode(fields, raw, raw_cap, raw_len)) return 0;
  if (!sign_bytes(key, raw, *raw_len, signature)) return 0;
  return plank_admission_b64url_encode(raw, *raw_len, payload_b64, payload_cap) &&
      plank_admission_b64url_encode(signature, 64, sig_b64, sig_cap);
}

static void decide(const plank_admission_key *keys, size_t key_count, int require, int config_valid,
                   int presented, int version, const char *payload, const char *sig,
                   const char *uniqueid, int64_t now, int64_t ttl, int64_t skew,
                   plank_admission_decision *out) {
  plank_admission_authorize(require, config_valid, presented, version, payload, sig, keys, key_count,
                            uniqueid, now, ttl, skew, consume_dir, out);
}

static int consumed(const char *admission_id) {
  char path[512];
  snprintf(path, sizeof path, "%s/%s", consume_dir, admission_id);
  return access(path, F_OK) == 0;
}

static plank_admission_key trust_for(const char *key_id, const char *issuer, const uint8_t public_key[32]) {
  plank_admission_key key;
  char token[160];
  char pub[64];
  memset(&key, 0, sizeof key);
  plank_admission_b64url_encode(public_key, 32, pub, sizeof pub);
  snprintf(token, sizeof token, "%s|%s|%s", key_id, issuer, pub);
  if (!plank_admission_parse_trust_token(token, &key)) memset(&key, 0, sizeof key);
  return key;
}

static void test_wire(EVP_PKEY *key, const uint8_t public_key[32]) {
  plank_admission_fields fields;
  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  uint8_t raw[PLANK_ADMISSION_PAYLOAD_MAX];
  size_t raw_len = 0;
  char payload[2048];
  char signature[128];
  CHECK(wrap(key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "encode-sign");
  CHECK(memcmp(raw, "PLAD", 4) == 0 && raw[4] == 1, "plad-prefix-version");
  CHECK(raw[5] == 0 && raw[6] == (uint8_t) strlen("plank-broker"), "issuer-length-be");
  CHECK(memcmp(raw + 7, "plank-broker", 12) == 0, "issuer-bytes");
  CHECK(strchr(payload, '+') == NULL && strchr(payload, '/') == NULL && strchr(payload, '=') == NULL, "payload-b64url");
  CHECK(strchr(signature, '=') == NULL && strlen(signature) == 86, "signature-b64url-unpadded");
  uint8_t decoded[64];
  size_t decoded_len = 0;
  CHECK(plank_admission_b64url_decode(signature, decoded, sizeof decoded, &decoded_len) && decoded_len == 64, "signature-64");
  CHECK(plank_admission_ed25519_verify(public_key, raw, raw_len, decoded), "verify-exact-bytes");
  raw[20] ^= 0x01;
  CHECK(!plank_admission_ed25519_verify(public_key, raw, raw_len, decoded), "one-byte-payload-change");
}

static void expect_reason(EVP_PKEY *key, const plank_admission_key *trust, size_t trust_count,
                          const char *issuer, const char *key_id, const char *uniqueid,
                          int64_t issued, int64_t expires, int version,
                          void (*mutate)(plank_admission_fields *), const char *reason, const char *name) {
  plank_admission_fields fields;
  fill(&fields, issuer, key_id, uniqueid, issued, expires);
  if (mutate) mutate(&fields);
  uint8_t raw[PLANK_ADMISSION_PAYLOAD_MAX];
  size_t raw_len = 0;
  char payload[2048];
  char signature[128];
  plank_admission_decision decision;
  if (!wrap(key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len)) {
    CHECK(0, name);
    return;
  }
  decide(trust, trust_count, 1, 1, 1, version, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_REJECT && strcmp(decision.reason, reason) == 0 &&
            !consumed(fields.admission_id),
        name);
}

static void wrong_audience(plank_admission_fields *fields) { snprintf(fields->audience, sizeof fields->audience, "wrong-host"); }
static void wrong_purpose(plank_admission_fields *fields) { snprintf(fields->purpose, sizeof fields->purpose, "wrong-purpose!"); }

typedef struct concurrent_arg {
  plank_admission_key trust;
  char payload[2048];
  char signature[128];
  int status;
  char reason[32];
} concurrent_arg;

static void *concurrent_worker(void *arg) {
  concurrent_arg *input = arg;
  plank_admission_decision decision;
  decide(&input->trust, 1, 1, 1, 1, 1, input->payload, input->signature, k_host, now_unix, 300, 60, &decision);
  input->status = decision.status;
  snprintf(input->reason, sizeof input->reason, "%s", decision.reason);
  return NULL;
}

static void rm_tree(const char *path) {
  /* The consume directory contains only admission files created by this process. */
  char command[512];
  snprintf(command, sizeof command, "rm -rf '%s'", path);
  if (system(command) != 0) fprintf(stderr, "cleanup failed\n");
}

int main(void) {
  char tmpl[] = "/tmp/plank-admission-XXXXXX";
  if (!mkdtemp(tmpl)) return 2;
  snprintf(consume_dir, sizeof consume_dir, "%s", tmpl);

  EVP_PKEY *old_key = NULL;
  EVP_PKEY *new_key = NULL;
  uint8_t old_pub[32];
  uint8_t new_pub[32];
  if (!generate_key(&old_key, old_pub) || !generate_key(&new_key, new_pub)) return 2;
  plank_admission_key old_trust = trust_for("broker-2026-01", "plank-broker", old_pub);
  plank_admission_key old_wrong_issuer = trust_for("broker-2026-01", "other-issuer", old_pub);
  plank_admission_key new_trust = trust_for("broker-2026-02", "plank-broker", new_pub);
  CHECK(old_trust.public_key[0] || old_trust.public_key[1] || old_trust.key_id[0], "trust-token");

  test_wire(old_key, old_pub);

  plank_admission_fields fields;
  uint8_t raw[PLANK_ADMISSION_PAYLOAD_MAX + 8];
  size_t raw_len = 0;
  char payload[2048];
  char signature[128];
  plank_admission_decision decision;

  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "valid-fixture");
  decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_ACCEPT && consumed(fields.admission_id), "valid-consumed");
  char accepted_id[37];
  snprintf(accepted_id, sizeof accepted_id, "%s", fields.admission_id);
  decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_REJECT && strcmp(decision.reason, "replay") == 0, "replay");
  decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "replay") == 0 && consumed(accepted_id), "pam-failure-does-not-refund");

  pid_t child = fork();
  if (child == 0) {
    decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
    _exit(decision.status == PLANK_ADMISSION_STATUS_REJECT && strcmp(decision.reason, "replay") == 0 ? 0 : 1);
  }
  int status = 1;
  waitpid(child, &status, 0);
  CHECK(child > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, "worker-replacement-replay");

  signature[0] = signature[0] == 'A' ? 'B' : 'A';
  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "bad-signature-fixture");
  signature[0] = signature[0] == 'A' ? 'B' : 'A';
  decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_REJECT && strcmp(decision.reason, "bad_signature") == 0 &&
            !consumed(fields.admission_id),
        "bad-signature");

  expect_reason(old_key, &old_trust, 1, "plank-broker", "missing-key", k_host, now_unix - 10, now_unix + 50, 1, NULL, "unknown_key_id", "unknown-key");
  expect_reason(old_key, &old_wrong_issuer, 1, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50, 1, NULL, "issuer_not_allowed", "wrong-issuer");
  expect_reason(old_key, &old_trust, 1, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50, 1, wrong_audience, "wrong_audience", "wrong-audience");
  expect_reason(old_key, &old_trust, 1, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50, 1, wrong_purpose, "wrong_purpose", "wrong-purpose");
  expect_reason(old_key, &old_trust, 1, "plank-broker", "broker-2026-01", k_other, now_unix - 10, now_unix + 50, 1, NULL, "wrong_uniqueid", "wrong-workstation");
  {
    static const char *stored_upper = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
    static const char *ticket_lower = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    fill(&fields, "plank-broker", "broker-2026-01", ticket_lower, now_unix - 10, now_unix + 50);
    CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "stored-uppercase-fixture");
    decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, stored_upper, now_unix, 300, 60, &decision);
    CHECK(decision.status == PLANK_ADMISSION_STATUS_ACCEPT && consumed(fields.admission_id), "stored-uppercase-uniqueid");
    decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, stored_upper, now_unix, 300, 60, &decision);
    CHECK(strcmp(decision.reason, "replay") == 0, "stored-uppercase-replay");
    fill(&fields, "plank-broker", "broker-2026-01", k_other, now_unix - 10, now_unix + 50);
    CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "stored-uppercase-other-fixture");
    decide(&old_trust, 1, 1, 1, 1, 1, payload, signature, stored_upper, now_unix, 300, 60, &decision);
    CHECK(strcmp(decision.reason, "wrong_uniqueid") == 0 && !consumed(fields.admission_id), "stored-uppercase-other-host");
  }
  expect_reason(old_key, &old_trust, 1, "plank-broker", "broker-2026-01", k_host, now_unix - 120, now_unix - 61, 1, NULL, "expired", "expired");
  expect_reason(old_key, &old_trust, 1, "plank-broker", "broker-2026-01", k_host, now_unix + 61, now_unix + 90, 1, NULL, "not_yet_valid", "not-yet-valid");
  expect_reason(old_key, &old_trust, 1, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 301, 1, NULL, "excessive_ttl", "excessive-ttl");

  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "wrapper-fixture");
  decide(&old_trust, 1, 1, 1, 1, 2, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "malformed") == 0 && !consumed(fields.admission_id), "wrapper-version-mismatch");
  char mutated[2048];
  snprintf(mutated, sizeof mutated, "%s", payload);
  mutated[0] = mutated[0] == 'A' ? 'B' : 'A';
  decide(&old_trust, 1, 1, 1, 1, 1, mutated, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_REJECT && !consumed(fields.admission_id), "modified-payload-encoding");
  char padded[2048];
  snprintf(padded, sizeof padded, "%s+", payload);
  decide(&old_trust, 1, 1, 1, 1, 1, padded, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "malformed") == 0, "reject-standard-base64");

  uint8_t oversize[PLANK_ADMISSION_PAYLOAD_MAX + 1];
  memset(oversize, 0x61, sizeof oversize);
  memcpy(oversize, "PLAD", 4);
  oversize[4] = 1;
  char oversize_b64[2048];
  CHECK(plank_admission_b64url_encode(oversize, sizeof oversize, oversize_b64, sizeof oversize_b64), "oversize-encoded");
  decide(&old_trust, 1, 1, 1, 1, 1, oversize_b64, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "malformed") == 0, "oversize-payload-rejected");

  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "concurrent-fixture");
  concurrent_arg first = {.trust = old_trust};
  concurrent_arg second = {.trust = old_trust};
  snprintf(first.payload, sizeof first.payload, "%s", payload);
  snprintf(second.payload, sizeof second.payload, "%s", payload);
  snprintf(first.signature, sizeof first.signature, "%s", signature);
  snprintf(second.signature, sizeof second.signature, "%s", signature);
  pthread_t threads[2];
  pthread_create(&threads[0], NULL, concurrent_worker, &first);
  pthread_create(&threads[1], NULL, concurrent_worker, &second);
  pthread_join(threads[0], NULL);
  pthread_join(threads[1], NULL);
  int accepts = (first.status == PLANK_ADMISSION_STATUS_ACCEPT) + (second.status == PLANK_ADMISSION_STATUS_ACCEPT);
  int replays = (strcmp(first.reason, "replay") == 0) + (strcmp(second.reason, "replay") == 0);
  CHECK(accepts == 1 && replays == 1 && consumed(fields.admission_id), "concurrent-replay");

  plank_admission_key both[2] = {old_trust, new_trust};
  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "rotation-old-fixture");
  decide(both, 2, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_ACCEPT, "rotation-old-key-during-transition");
  fill(&fields, "plank-broker", "broker-2026-02", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(new_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "rotation-new-fixture");
  decide(both, 2, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_ACCEPT, "rotation-new-key-during-transition");
  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "rotation-retired-fixture");
  decide(&new_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "unknown_key_id") == 0 && !consumed(fields.admission_id), "rotation-old-key-removed");
  fill(&fields, "plank-broker", "broker-2026-02", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(new_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "rotation-current-fixture");
  decide(&new_trust, 1, 1, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_ACCEPT, "rotation-new-key-remains");

  fill(&fields, "plank-broker", "broker-2026-01", k_host, now_unix - 10, now_unix + 50);
  CHECK(wrap(old_key, &fields, payload, sizeof payload, signature, sizeof signature, raw, sizeof raw, &raw_len), "unmanaged-fixture");
  decide(&old_trust, 1, 0, 1, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(decision.status == PLANK_ADMISSION_STATUS_SKIP && !consumed(fields.admission_id), "unmanaged-skips");
  decide(&old_trust, 1, 1, 1, 0, 1, NULL, NULL, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "malformed") == 0, "managed-missing");
  decide(&old_trust, 1, 1, 0, 1, 1, payload, signature, k_host, now_unix, 300, 60, &decision);
  CHECK(strcmp(decision.reason, "config_invalid") == 0 && !consumed(fields.admission_id), "managed-invalid-config");

  CHECK(plank_admission_uniqueid_matches(k_host, k_host), "client-uniqueid-match");
  CHECK(plank_admission_uniqueid_matches("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                                         "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        "client-uniqueid-case");
  CHECK(!plank_admission_uniqueid_matches(k_host, k_other), "client-wrong-host-stops");
  CHECK(!plank_admission_uniqueid_matches("not-a-uuid", "not-a-uuid"), "client-uniqueid-shape");

  EVP_PKEY_free(old_key);
  EVP_PKEY_free(new_key);
  rm_tree(consume_dir);
  if (failures) {
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  printf("all passed\n");
  return 0;
}
