/* SPDX-License-Identifier: GPL-3.0-or-later
 * Mint one ephemeral qualification admission. The private key stays in this
 * process. Nothing printed is a ticket, signature, or workstation id.
 */
#include "plank_admission.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <openssl/evp.h>

/* Synthetic probe workstation. Same value as probes/macos/https-auth.m. */
static const char k_workstation[] = "f92140f5-8740-4b3b-82f7-74db5353de27";
static const char k_other[] = "22222222-2222-4222-8222-222222222222";

static int fail(void) {
  fputs("mint_admission=fail\n", stderr);
  return 1;
}

static int random_uuid(char out[37]) {
  unsigned char bytes[16];
  int fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0 || read(fd, bytes, sizeof bytes) != (ssize_t) sizeof bytes) {
    if (fd >= 0) close(fd);
    return 0;
  }
  close(fd);
  bytes[6] = (unsigned char) ((bytes[6] & 0x0f) | 0x40);
  bytes[8] = (unsigned char) ((bytes[8] & 0x3f) | 0x80);
  snprintf(out, 37,
           "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
           bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
  return 1;
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

static void upper_uuid(char out[37], const char *uuid) {
  for (int i = 0; i < 36; ++i) {
    char c = uuid[i];
    if (c >= 'a' && c <= 'f') c = (char) (c - 'a' + 'A');
    out[i] = c;
  }
  out[36] = 0;
}

static int lowercase_workstation(const char *uuid) {
  static const int hyphens[] = {8, 13, 18, 23};
  if (!uuid) return 0;
  for (int i = 0; i < 36; ++i) {
    int hyphen = 0;
    for (int h = 0; h < 4; ++h) hyphen |= (i == hyphens[h]);
    if (hyphen) {
      if (uuid[i] != '-') return 0;
    } else if (!((uuid[i] >= '0' && uuid[i] <= '9') || (uuid[i] >= 'a' && uuid[i] <= 'f'))) {
      return 0;
    }
  }
  return uuid[36] == 0;
}

static int contains_bytes(const uint8_t *raw, size_t len, const char *text) {
  size_t n = strlen(text);
  if (n > len) return 0;
  for (size_t i = 0; i + n <= len; ++i) {
    if (memcmp(raw + i, text, n) == 0) return 1;
  }
  return 0;
}

static int write_private(const char *path, const char *text) {
  int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return 0;
  size_t len = strlen(text);
  int ok = write(fd, text, len) == (ssize_t) len;
  if (ok) ok = fsync(fd) == 0;
  if (close(fd) != 0) ok = 0;
  if (!ok) unlink(path);
  return ok;
}

static int sign_bundle(EVP_PKEY *key, const char *uniqueid, char *payload, size_t payload_cap,
                       char *signature, size_t signature_cap) {
  plank_admission_fields fields;
  memset(&fields, 0, sizeof fields);
  snprintf(fields.issuer, sizeof fields.issuer, "plank-broker");
  snprintf(fields.key_id, sizeof fields.key_id, "broker-2026-01");
  if (!random_uuid(fields.admission_id)) return 0;
  snprintf(fields.subject, sizeof fields.subject, "facility-principal");
  if (!lowercase_workstation(uniqueid)) return 0;
  snprintf(fields.workstation_uniqueid, sizeof fields.workstation_uniqueid, "%s", uniqueid);
  time_t now = time(NULL);
  if (now < 10) return 0;
  snprintf(fields.issued_at, sizeof fields.issued_at, "%lld", (long long) now - 10);
  snprintf(fields.expires_at, sizeof fields.expires_at, "%lld", (long long) now + 300);
  snprintf(fields.audience, sizeof fields.audience, "plank-host");
  snprintf(fields.purpose, sizeof fields.purpose, "connect-attempt");
  uint8_t raw[PLANK_ADMISSION_PAYLOAD_MAX];
  size_t raw_len = 0;
  uint8_t sig[64];
  if (!plank_admission_encode(&fields, raw, sizeof raw, &raw_len) ||
      !contains_bytes(raw, raw_len, uniqueid)) return 0;
  if (!sign_bytes(key, raw, raw_len, sig)) return 0;
  return plank_admission_b64url_encode(raw, raw_len, payload, payload_cap) &&
      plank_admission_b64url_encode(sig, 64, signature, signature_cap);
}

static int write_bundle(const char *path, const char *payload, const char *signature, const char *uniqueid) {
  char body[4096];
  int n = snprintf(body, sizeof body,
                   "{\"admission\":{\"v\":1,\"payload\":\"%s\",\"sig\":\"%s\"},\"workstation_uniqueid\":\"%s\"}\n",
                   payload, signature, uniqueid);
  if (n < 0 || (size_t) n >= sizeof body) return 0;
  return write_private(path, body);
}

static int safe_directory(const char *path) {
  if (!path || path[0] != '/' || strstr(path, "..") || strchr(path, '&') || strchr(path, '<') ||
      strchr(path, '>') || strchr(path, '"') || strchr(path, '\'')) return 0;
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

int main(int argc, char **argv) {
  if (argc != 2 || !safe_directory(argv[1])) return fail();
  char consume[512];
  char plist_path[512];
  char match_path[512];
  char case_path[512];
  char other_path[512];
  if (snprintf(consume, sizeof consume, "%s/consumed", argv[1]) >= (int) sizeof consume ||
      snprintf(plist_path, sizeof plist_path, "%s/admission.plist", argv[1]) >= (int) sizeof plist_path ||
      snprintf(match_path, sizeof match_path, "%s/bundle.json", argv[1]) >= (int) sizeof match_path ||
      snprintf(case_path, sizeof case_path, "%s/bundle-case.json", argv[1]) >= (int) sizeof case_path ||
      snprintf(other_path, sizeof other_path, "%s/bundle-other.json", argv[1]) >= (int) sizeof other_path) {
    return fail();
  }

  EVP_PKEY *key = NULL;
  uint8_t public_key[32];
  if (!generate_key(&key, public_key)) return fail();
  char public_b64[64];
  char match_payload[2048];
  char match_sig[128];
  char case_payload[2048];
  char case_sig[128];
  char other_payload[2048];
  char other_sig[128];
  char upper[37];
  upper_uuid(upper, k_workstation);
  int ok = plank_admission_b64url_encode(public_key, 32, public_b64, sizeof public_b64) &&
      sign_bundle(key, k_workstation, match_payload, sizeof match_payload, match_sig, sizeof match_sig) &&
      sign_bundle(key, k_workstation, case_payload, sizeof case_payload, case_sig, sizeof case_sig) &&
      sign_bundle(key, k_other, other_payload, sizeof other_payload, other_sig, sizeof other_sig);
  EVP_PKEY_free(key);
  if (!ok) return fail();

  char plist[2048];
  int n = snprintf(plist, sizeof plist,
                   "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                   "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                   "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                   "<plist version=\"1.0\"><dict>\n"
                   "<key>RequireAdmission</key><true/>\n"
                   "<key>MaxTTL</key><integer>900</integer>\n"
                   "<key>ClockSkew</key><integer>60</integer>\n"
                   "<key>ConsumeDirectory</key><string>%s</string>\n"
                   "<key>Trust</key><array><dict>\n"
                   "<key>KeyID</key><string>broker-2026-01</string>\n"
                   "<key>Issuer</key><string>plank-broker</string>\n"
                   "<key>PublicKey</key><string>%s</string>\n"
                   "</dict></array></dict></plist>\n",
                   consume, public_b64);
  if (n < 0 || (size_t) n >= sizeof plist) return fail();
  if (!write_private(plist_path, plist) ||
      !write_bundle(match_path, match_payload, match_sig, k_workstation) ||
      !write_bundle(case_path, case_payload, case_sig, upper) ||
      !write_bundle(other_path, other_payload, other_sig, k_other)) return fail();
  fputs("mint_admission=pass\n", stdout);
  return 0;
}
