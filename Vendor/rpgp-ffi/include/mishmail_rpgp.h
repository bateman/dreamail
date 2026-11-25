// C interface of Vendor/rpgp-ffi (MishMail's OpenPGP engine over rPGP).
// Hand-written to match src/lib.rs; RPGPBindingsTests checks the JSON
// contract, and the symbol list is checked by scripts/build-rpgp-xcframework.sh.
#ifndef MISHMAIL_RPGP_H
#define MISHMAIL_RPGP_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *ptr;  // NULL when len is 0; owned by the library
    size_t len;
} MMBuffer;

typedef struct {
    MMBuffer json;  // UTF-8 {"ok":true,...} or {"ok":false,"error":"..."}
    MMBuffer data;  // plaintext or signed text; empty otherwise
} MMResult;

MMResult mm_pgp_verify_detached(const uint8_t *data, size_t data_len,
                                const uint8_t *signature, size_t signature_len,
                                const uint8_t *certs, size_t certs_len,
                                int64_t now_unix);
MMResult mm_pgp_verify_cleartext(const uint8_t *message, size_t message_len,
                                 const uint8_t *certs, size_t certs_len,
                                 int64_t now_unix);
MMResult mm_pgp_decrypt(const uint8_t *message, size_t message_len,
                        const uint8_t *secret_keys, size_t secret_keys_len,
                        const uint8_t *passphrase, size_t passphrase_len,
                        const uint8_t *certs, size_t certs_len,
                        int64_t now_unix);
MMResult mm_pgp_inspect_keys(const uint8_t *data, size_t data_len, int64_t now_unix);
MMResult mm_pgp_sign(void);     // scope B: always {"ok":false,"error":"unsupported"}
MMResult mm_pgp_encrypt(void);  // scope B: always {"ok":false,"error":"unsupported"}
// Zeroes and frees both buffers. Call exactly once per result.
void mm_pgp_free(MMResult result);
const char *mm_pgp_rpgp_version(void);

#endif
