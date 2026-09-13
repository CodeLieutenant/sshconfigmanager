/*
 * Minimal SUPERCOP-style crypto_api.h for the vendored bcrypt_pbkdf.c, which pulls
 * its SHA-512 through `crypto_hash_sha512`. Implemented in sha512.c, which bundles
 * the hash so the target needs no platform crypto library.
 */
#ifndef SSHCM_CRYPTO_API_H
#define SSHCM_CRYPTO_API_H

#include <stddef.h>

#include "bcrypt_pbkdf.h"   /* crypto_hash_sha512 */

#define crypto_hash_sha512_BYTES SSHCM_SHA512_DIGEST_LENGTH

#endif /* SSHCM_CRYPTO_API_H */
