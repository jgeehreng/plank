/* SPDX-License-Identifier: GPL-3.0-or-later
 * Print one test-signed PLAD v1 admission. The key exists only in this process.
 */
#include "plank_admission.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <openssl/evp.h>

static int fail(const char *message) {
  fprintf(stderr, "mint-admission: %s\n", message);
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2) return fail("usage: mint-admission <workstation-uniqueid>...");
  for (int i = 1; i < argc; ++i) {
    if (strlen(argv[i]) != 36) return fail("uniqueid must be 36 characters");
  }
  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, NULL);
  EVP_PKEY *key = NULL;
  uint8_t public_key[32];
  size_t public_len = sizeof public_key;
  if (!ctx || EVP_PKEY_keygen_init(ctx) != 1 || EVP_PKEY_keygen(ctx, &key) != 1 ||
      EVP_PKEY_get_raw_public_key(key, public_key, &public_len) != 1 || public_len != 32) {
    return fail("key generation failed");
  }
  EVP_PKEY_CTX_free(ctx);

  char public_b64[64];
  if (!plank_admission_b64url_encode(public_key, public_len, public_b64, sizeof public_b64)) return fail("encode failed");
  printf("{\"key_id\":\"broker-test\",\"issuer\":\"plank-test\",\"public_key\":\"%s\",\"tickets\":[", public_b64);
  for (int i = 1; i < argc; ++i) {
    time_t now = time(NULL);
    plank_admission_fields fields;
    memset(&fields, 0, sizeof fields);
    snprintf(fields.issuer, sizeof fields.issuer, "plank-test");
    snprintf(fields.key_id, sizeof fields.key_id, "broker-test");
    unsigned char random_id[6];
    FILE *random_file = fopen("/dev/urandom", "rb");
    if (!random_file || fread(random_id, 1, sizeof random_id, random_file) != sizeof random_id) return fail("random id failed");
    fclose(random_file);
    snprintf(fields.admission_id, sizeof fields.admission_id, "aaaaaaaa-bbbb-4ccc-8ddd-%02x%02x%02x%02x%02x%02x",
             random_id[0], random_id[1], random_id[2], random_id[3], random_id[4], random_id[5]);
    snprintf(fields.subject, sizeof fields.subject, "facility-principal");
    snprintf(fields.workstation_uniqueid, sizeof fields.workstation_uniqueid, "%s", argv[i]);
    snprintf(fields.issued_at, sizeof fields.issued_at, "%lld", (long long) now - 15);
    snprintf(fields.expires_at, sizeof fields.expires_at, "%lld", (long long) now + 120);
    snprintf(fields.audience, sizeof fields.audience, "plank-host");
    snprintf(fields.purpose, sizeof fields.purpose, "connect-attempt");
    uint8_t payload[PLANK_ADMISSION_PAYLOAD_MAX];
    size_t payload_len = 0;
    uint8_t signature[64];
    size_t signature_len = sizeof signature;
    char payload_b64[2048];
    char signature_b64[128];
    EVP_MD_CTX *digest = EVP_MD_CTX_new();
    int signed_ok = plank_admission_encode(&fields, payload, sizeof payload, &payload_len) && digest &&
        EVP_DigestSignInit(digest, NULL, NULL, NULL, key) == 1 &&
        EVP_DigestSign(digest, signature, &signature_len, payload, payload_len) == 1 && signature_len == 64 &&
        plank_admission_b64url_encode(payload, payload_len, payload_b64, sizeof payload_b64) &&
        plank_admission_b64url_encode(signature, signature_len, signature_b64, sizeof signature_b64);
    EVP_MD_CTX_free(digest);
    if (!signed_ok) return fail("encode failed");
    if (i > 1) printf(",");
    printf("{\"admission_id\":\"%s\",\"workstation_uniqueid\":\"%s\",\"v\":1,\"payload\":\"%s\",\"sig\":\"%s\"}",
           fields.admission_id, fields.workstation_uniqueid, payload_b64, signature_b64);
  }
  EVP_PKEY_free(key);
  printf("]}\n");
  return 0;
}
