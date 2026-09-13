/*
 * Minimal replacement for OpenSSH's build-time "includes.h", supplying just the
 * standard headers and HAVE_* feature macros that the vendored bcrypt_pbkdf.c and
 * blowfish.c expect. We deliberately do NOT define HAVE_BCRYPT_PBKDF /
 * HAVE_BLOWFISH_INITSTATE / HAVE_BLOWFISH_EXPAND0STATE / HAVE_BLF_ENC, so the
 * reference implementations in those files are compiled (rather than skipped).
 */
#ifndef SSHCM_BCRYPT_INCLUDES_H
#define SSHCM_BCRYPT_INCLUDES_H

#include <sys/types.h>   /* u_int8_t / u_int16_t / u_int32_t (BSD types on Darwin) */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define HAVE_STDLIB_H 1
#define HAVE_BLF_H 1

/*
 * OpenBSD hygiene helpers the reference code uses but that the macOS SDK does not
 * declare. Provided as file-local shims (this header is included only by our two
 * vendored .c files, and the SDK declares neither name, so there's nothing to
 * collide with).
 */
static inline void sshcm_explicit_bzero(void *b, size_t len) {
    memset(b, 0, len);
    __asm__ __volatile__("" : : "r"(b) : "memory");  /* defeat dead-store elimination */
}
static inline void sshcm_freezero(void *b, size_t len) {
    if (b != NULL) { sshcm_explicit_bzero(b, len); free(b); }
}
#define explicit_bzero(b, len) sshcm_explicit_bzero((b), (len))
#define freezero(b, len) sshcm_freezero((b), (len))

#endif /* SSHCM_BCRYPT_INCLUDES_H */
