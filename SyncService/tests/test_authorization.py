# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""The one kind of mistake an update does not repair."""

import unittest

from core.authorization import (DENIED, Caller, caller_for, hash_secret, new_token,
                                secret_matches, token_digest)


class StoringASecret(unittest.TestCase):
    def test_the_right_secret_matches(self):
        stored = hash_secret("a passphrase with some length")
        self.assertTrue(secret_matches(stored, "a passphrase with some length"))

    def test_a_wrong_secret_does_not(self):
        stored = hash_secret("a passphrase with some length")
        self.assertFalse(secret_matches(stored, "a passphrase with some lengtH"))
        self.assertFalse(secret_matches(stored, ""))
        self.assertFalse(secret_matches(stored, "a passphrase with some length "))

    def test_the_same_secret_stores_differently_every_time(self):
        # Without a per-secret salt, two people with the same passphrase
        # have the same stored form, and one stolen store cracks both.
        self.assertNotEqual(hash_secret("same"), hash_secret("same"))

    def test_an_empty_secret_is_refused_at_the_door(self):
        with self.assertRaises(ValueError):
            hash_secret("")

    def test_the_stored_form_carries_its_parameters(self):
        # So they can be raised later without invalidating what is stored.
        stored = hash_secret("x" * 20)
        algorithm, n, r, p, salt, key = stored.split("$")
        self.assertEqual(algorithm, "scrypt")
        self.assertTrue(int(n) >= 2 ** 14)
        self.assertEqual(len(bytes.fromhex(salt)), 16)
        self.assertEqual(len(bytes.fromhex(key)), 32)

    def test_the_stored_form_holds_no_secret(self):
        stored = hash_secret("hunter2 and then some more")
        self.assertNotIn("hunter2", stored)


class RaisingTheParametersDoesNotLockAnybodyOut(unittest.TestCase):
    """The trap this file was written around, found while building it.

    `secret_matches` turns every failure into "no". scrypt refuses to run
    past a memory ceiling, and OpenSSL's own default is 32 MiB — which the
    chosen parameters meet exactly and tip past. If the ceiling were a
    fixed number rather than one computed from the parameters, then the
    day someone raises them, verification would not error: every stored
    secret would quietly stop matching and everyone would be locked out of
    their own service.

    So: a form stored at OTHER parameters than the ones this module uses
    today must still verify."""

    def test_a_secret_stored_at_smaller_parameters_still_verifies(self):
        import hashlib

        salt = b"\x01" * 16
        key = hashlib.scrypt(b"the passphrase", salt=salt, n=2 ** 14, r=8, p=1, dklen=32,
                             maxmem=128 * (2 ** 14) * 8 + 1024 * 1024)
        stored = f"scrypt${2 ** 14}$8$1${salt.hex()}${key.hex()}"
        self.assertTrue(secret_matches(stored, "the passphrase"))
        self.assertFalse(secret_matches(stored, "the wrong passphrase"))

    def test_a_secret_stored_at_larger_parameters_still_verifies(self):
        import hashlib

        salt = b"\x02" * 16
        n = 2 ** 16
        key = hashlib.scrypt(b"the passphrase", salt=salt, n=n, r=8, p=1, dklen=32,
                             maxmem=128 * n * 8 + 1024 * 1024)
        stored = f"scrypt${n}$8$1${salt.hex()}${key.hex()}"
        self.assertTrue(secret_matches(stored, "the passphrase"))


class AStoredFormThisBuildCannotRead(unittest.TestCase):
    """A refusal, never a fallback to something weaker. A store carrying a
    form this build does not know means someone rolled the service back,
    and the answer is "no"."""

    def test_an_unknown_algorithm_is_no(self):
        self.assertFalse(secret_matches("argon2id$whatever$x$y", "x"))

    def test_a_mangled_form_is_no_and_does_not_raise(self):
        # It must FAIL the same shape as a wrong secret. An exception here
        # would let a handler answer differently and leak the difference.
        for broken in ("", "scrypt", "scrypt$$$$$", "scrypt$a$b$c$d$e",
                       "scrypt$32768$8$1$nothex$nothex", None):
            self.assertFalse(secret_matches(broken, "x"))

    def test_an_absurd_parameter_is_no_rather_than_a_crash(self):
        # scrypt refuses some parameter combinations outright; that must
        # come back as "no", not as a 500 that tells the caller they found
        # a real account.
        self.assertFalse(secret_matches("scrypt$3$8$1$00$00", "x"))


class ReadingTheAuthorizationHeader(unittest.TestCase):
    def setUp(self):
        self.token = new_token()
        self.owners = {token_digest(self.token): "the-owner"}

    def look_up(self, digest):
        return self.owners.get(digest)

    def test_a_good_token_names_its_owner(self):
        caller = caller_for(f"Bearer {self.token}", self.look_up)
        self.assertTrue(caller.authorized)
        self.assertEqual(caller.owner, "the-owner")

    def test_the_scheme_is_read_case_insensitively(self):
        self.assertTrue(caller_for(f"bearer {self.token}", self.look_up).authorized)
        self.assertTrue(caller_for(f"BEARER {self.token}", self.look_up).authorized)

    def test_a_bad_or_missing_header_is_nobody(self):
        for header in (None, "", "Bearer", "Bearer ", "Basic abc",
                       self.token, f"Token {self.token}"):
            caller = caller_for(header, self.look_up)
            self.assertFalse(caller.authorized, repr(header))

    def test_an_unknown_token_is_nobody(self):
        self.assertFalse(caller_for(f"Bearer {new_token()}", self.look_up).authorized)


class EveryRefusalSoundsTheSame(unittest.TestCase):
    """Otherwise the endpoint is a list of who has an account here."""

    def test_no_account_and_wrong_token_give_the_same_sentence(self):
        empty = caller_for("Bearer " + new_token(), lambda digest: None)
        malformed = caller_for("Basic whatever", lambda digest: None)
        missing = caller_for(None, lambda digest: None)
        for caller in (empty, malformed, missing):
            self.assertEqual(caller.reason, DENIED)

    def test_the_refusal_repeats_nothing_the_caller_sent(self):
        # A refusal that echoes the token puts it in every log between
        # here and the client.
        token = new_token()
        caller = caller_for(f"Bearer {token}", lambda digest: None)
        self.assertNotIn(token, caller.reason)


class ATokenIsNotAName(unittest.TestCase):
    """The owner comes from the store's answer and from nowhere else."""

    def test_the_owner_is_whatever_the_lookup_says(self):
        caller = caller_for("Bearer anything-at-all", lambda digest: "someone-else")
        self.assertEqual(caller.owner, "someone-else")

    def test_the_lookup_never_sees_the_raw_token(self):
        # What is stored is a digest. A store that held raw tokens would
        # hand out live credentials the moment it leaked.
        seen = []
        token = new_token()
        caller_for(f"Bearer {token}", lambda digest: seen.append(digest))
        self.assertEqual(seen, [token_digest(token)])
        self.assertNotIn(token, seen)

    def test_two_tokens_do_not_share_a_digest(self):
        self.assertNotEqual(token_digest(new_token()), token_digest(new_token()))


class TokensAreWorthGuessingAt(unittest.TestCase):
    def test_a_token_is_long_and_never_repeats(self):
        tokens = {new_token() for _ in range(50)}
        self.assertEqual(len(tokens), 50)
        self.assertTrue(all(len(t) >= 64 for t in tokens))


class SecretsAreComparedInConstantTime(unittest.TestCase):
    """A fence, because no behavioural case can see this.

    `==` and `hmac.compare_digest` give the SAME answers; the difference is
    only in how long the wrong answer takes. A probe that swapped one for
    the other left every case above green — proof that they were testing
    something else. What is left is to count the comparisons in the source
    and let the stock only fall.

    An early-return comparison tells a patient caller the secret one byte
    at a time. That is not a theoretical attack against a service someone
    can reach over their own network for as long as they like.
    """

    def source(self):
        import os

        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(here, "core", "authorization.py"), encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        # A source fence strips what is not code first, or it measures the
        # prose around the code.
        return "\n".join(line for line in lines
                         if not line.strip().startswith("#") and '"""' not in line)

    def test_the_constant_time_comparison_is_the_one_that_is_used(self):
        self.assertIn("hmac.compare_digest", self.source())

    def test_no_secret_material_is_compared_with_an_operator(self):
        code = self.source()
        offenders = [name for name in ("key", "computed", "digest", "secret", "token")
                     if f"== {name}" in code or f"{name} ==" in code
                     or f"!= {name}" in code or f"{name} !=" in code]
        self.assertEqual(offenders, [],
                         f"a secret is compared with an operator: {offenders}")


class TheCallerTypeDoesNotLie(unittest.TestCase):
    def test_authorized_is_exactly_having_an_owner(self):
        self.assertFalse(Caller(None, DENIED).authorized)
        self.assertTrue(Caller("the-owner", "authorized").authorized)


if __name__ == "__main__":
    unittest.main()
