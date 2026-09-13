/*
 * Public interface of the CBcryptPBKDF module: OpenSSH's bcrypt_pbkdf KDF.
 * The implementation is the verbatim OpenBSD/OpenSSH reference (bcrypt_pbkdf.c +
 * blowfish.c) over an in-tree SHA-512 (sha512.c). No platform crypto library is
 * used, so the module builds and links the same way on every platform.
 */
#ifndef SSHCM_BCRYPT_PBKDF_PUBLIC_H
#define SSHCM_BCRYPT_PBKDF_PUBLIC_H

#include <stddef.h>
#include <stdint.h>

#define SSHCM_SHA512_DIGEST_LENGTH 64U

/*
 * One-shot SHA-512 of `in` (`inlen` bytes) into the 64-byte buffer `out`.
 * Returns 0 on success, -1 if `in` is NULL with a non-zero length. Exported so
 * the hash can be tested on its own, not only through bcrypt_pbkdf.
 */
int crypto_hash_sha512(unsigned char *out, const unsigned char *in,
                       unsigned long long inlen);

/*
 * Derive `keylen` bytes of key material into `key` from `pass`/`salt` using
 * `rounds` iterations of OpenSSH's bcrypt_pbkdf. Returns 0 on success, -1 on
 * invalid arguments.
 */
int bcrypt_pbkdf(const char *pass, size_t passlen,
                 const uint8_t *salt, size_t saltlen,
                 uint8_t *key, size_t keylen, unsigned int rounds);

#endif /* SSHCM_BCRYPT_PBKDF_PUBLIC_H */
