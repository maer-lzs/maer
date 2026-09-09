# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""Who is asking, and whether they may.

The requirements set this apart on purpose: "to be treated separately and
accepted separately. If there is a mistake here, other people's listening
stands are open, and that is the one kind of mistake you do not repair with
an update." So the decision lives as a unit with its own cases, and the
handler only carries it out.

Three things this file is built around, and each of them is a mistake that
is easy to make and expensive to find:

- **One answer for every failure.** A missing account and a wrong secret
  give the same status and the same sentence. Anything else turns the
  endpoint into a list of who has an account here.
- **Constant-time comparison.** A comparison that returns early on the
  first wrong byte tells a patient caller the secret one byte at a time.
  `hmac.compare_digest` is the stdlib's answer and it is used everywhere a
  secret is compared.
- **A token is not a name.** A caller presents a token; the OWNER comes
  from the store's answer, never from anything the caller said. A handler
  that read an account name out of the request would be one typo away from
  serving anyone as anyone.
"""

import hashlib
import hmac
from dataclasses import dataclass

# The one thing a rejected caller ever hears. It says nothing about which
# half was wrong, and it is the same for every rejection so no caller can
# tell "no such account" from "wrong secret".
DENIED = "not authorized"

# scrypt, from the standard library, at parameters that are deliberate
# rather than inherited. n=2**15 with r=8 costs 128 * n * r = 32 MiB and
# roughly a tenth of a second per check: enough that guessing is not a
# strategy, small enough that a phone syncing every few minutes never
# notices.
SCRYPT_N = 2 ** 15
SCRYPT_R = 8
SCRYPT_P = 1
SALT_BYTES = 16
KEY_BYTES = 32


def _memory_for(n, r, p):
    """How much scrypt is allowed to take for these parameters.

    OpenSSL's own default is 32 MiB, which the parameters above meet
    EXACTLY and therefore tip past — measured, not guessed: the first run
    of these cases failed with "memory limit exceeded". So the limit is
    computed from the parameters instead of inherited.

    It is computed on the VERIFY path too, and that matters more than it
    looks: `secret_matches` turns a failure into "no". If verification
    inherited a fixed ceiling, raising the parameters later would not
    raise an error — every stored secret would quietly stop matching and
    everyone would be locked out of their own service.
    """
    return 128 * n * r * p + 1024 * 1024


@dataclass(frozen=True)
class Caller:
    """Who the request is from, or nobody."""

    owner: str | None
    reason: str

    @property
    def authorized(self):
        return self.owner is not None


def hash_secret(secret, salt=None):
    """A stored form of `secret`: algorithm, parameters, salt and key, so
    that the parameters can be raised later without invalidating what is
    already stored."""
    if not secret:
        raise ValueError("an empty secret is not a secret")
    salt = salt if salt is not None else _random(SALT_BYTES)
    key = hashlib.scrypt(secret.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R,
                         p=SCRYPT_P, dklen=KEY_BYTES,
                         maxmem=_memory_for(SCRYPT_N, SCRYPT_R, SCRYPT_P))
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${salt.hex()}${key.hex()}"


def secret_matches(stored, offered):
    """Whether `offered` is the secret behind `stored`.

    An unreadable stored form is False, never an exception that a handler
    might turn into a different answer than a wrong secret — the shape of
    the failure must not vary either.
    """
    if not stored or not offered:
        return False
    parts = stored.split("$")
    if len(parts) != 6 or parts[0] != "scrypt":
        # An unknown algorithm is a refusal, not a fallback to a weaker
        # one. A store carrying a form this build cannot read means the
        # operator rolled back, and the answer is "no", not "let them in".
        return False
    try:
        n, r, p = int(parts[1]), int(parts[2]), int(parts[3])
        salt, key = bytes.fromhex(parts[4]), bytes.fromhex(parts[5])
    except ValueError:
        return False
    try:
        computed = hashlib.scrypt(offered.encode(), salt=salt, n=n, r=r, p=p,
                                  dklen=len(key), maxmem=_memory_for(n, r, p))
    except ValueError:
        return False
    return hmac.compare_digest(computed, key)


def token_digest(token):
    """What is stored for a token. A token is high-entropy already, so a
    plain digest is enough and a slow hash on every single request would
    be a self-inflicted denial of service — the opposite trade to the one
    a password needs."""
    return hashlib.sha256(token.encode()).hexdigest()


def caller_for(header, owner_of_token):
    """Turn an `Authorization` header into a caller.

    `owner_of_token` takes a token digest and answers with the owner it
    belongs to, or None. The OWNER comes from there and from nowhere else:
    nothing the caller wrote is ever taken as an identity.
    """
    if not header:
        return Caller(None, DENIED)
    parts = header.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].strip():
        return Caller(None, DENIED)

    owner = owner_of_token(token_digest(parts[1].strip()))
    if not owner:
        return Caller(None, DENIED)
    return Caller(owner, "authorized")


def new_token():
    """A fresh device token. Long enough that guessing is not a strategy,
    and from the system's own source of randomness rather than anything
    seeded or predictable."""
    return _random(32).hex()


def _random(count):
    import secrets

    return secrets.token_bytes(count)
