# Mär — an audio player for self-hosted open ecosystems
# Copyright (C) 2026 Laurenz Schröder
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms apply — see LICENSE-ADDITIONAL-TERMS

"""Starting the service behind an application server.

The application in `app.py` is a plain ASGI callable, so this file only
binds it to a server. That separation is the point of picking ASGI over
anything with its own server built in: the application is finished and
tested without one, and the server stays a choice the operator can revisit.

uvicorn is the reference, not a requirement. Anything that speaks ASGI and
carries WebSockets will do, and swapping it changes this file alone.

NOT YET MEASURED: nothing here has been run against a live server. The
application is driven directly by the suite; this binding is written and
unexercised, and it says so rather than letting a reader assume otherwise.
"""

import argparse
import logging
import os
import sys

from .app import make
from .rehearsal import backup_and_rehearse
from .store import Store


def backup(path):
    """Copy the live store to `path` and rehearse the restore in the same
    run. Exit 0 only when the copy came back fitting; the operator's
    schedule alarms on anything else."""
    if not path:
        print("usage: python3 -m service backup <copy.sqlite>", file=sys.stderr)
        return 2
    store = Store(os.environ.get("MAER_SYNC_DB", "maer-sync.sqlite"))
    try:
        verdict = backup_and_rehearse(store, path)
    finally:
        store.close()
    print(f"{verdict.outcome}: {verdict.reason}")
    return 0 if verdict.passed else 1


def add_account(owner):
    """Lay down an account. The secret is read from standard input and
    never from the command line: an argument is visible in the process
    list to everyone on the machine and lands in the shell's history."""
    if not owner:
        print("usage: python3 -m service account <owner>   (secret on stdin)", file=sys.stderr)
        return 2

    if sys.stdin.isatty():
        import getpass

        secret = getpass.getpass(f"secret for {owner}: ")
    else:
        secret = sys.stdin.readline().rstrip("\n")

    if not secret:
        print("no secret given", file=sys.stderr)
        return 2

    store = Store(os.environ.get("MAER_SYNC_DB", "maer-sync.sqlite"))
    try:
        store.create_account(owner, secret)
    except ValueError as refusal:
        print(f"refused: {refusal}", file=sys.stderr)
        return 1
    finally:
        store.close()
    print(f"account {owner} laid down")
    return 0


def remove_account(owner):
    """Take an account and everything under it away. Removing one that is
    not here is not an error; the line says what was there."""
    store = Store(os.environ.get("MAER_SYNC_DB", "maer-sync.sqlite"))
    try:
        accounts, documents = store.remove_account(owner)
    finally:
        store.close()
    if accounts == 0:
        print(f"no account named {owner!r}")
    else:
        print(f"account {owner} removed, documents dropped: {documents} (its tokens fell with it)")
    return 0


def serve():
    # The lines go to stderr, where the container runtime collects them.
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    application = make()
    try:
        import uvicorn
    except ImportError:
        print("no application server installed. This service needs one that speaks ASGI "
              "and carries WebSockets; uvicorn is the reference plus a WebSocket library "
              "(websockets or wsproto). Install them pinned, with hashes checked, as a "
              "deliberate step.", file=sys.stderr)
        return 3

    uvicorn.run(application,
                host=os.environ.get("MAER_SYNC_HOST", "127.0.0.1"),
                port=int(os.environ.get("MAER_SYNC_PORT", "8099")))
    return 0


def parser():
    """The commands, so that `--help` prints help and never starts the
    server, and so an unknown command is refused rather than silently
    serving. No subcommand runs the server, the common case."""
    p = argparse.ArgumentParser(prog="python3 -m service",
                                description="The Mär sync service and its operator commands.")
    subs = p.add_subparsers(dest="command")
    subs.add_parser("serve", help="run the service (the default with no command)")
    b = subs.add_parser("backup", help="copy the store and rehearse the restore")
    b.add_argument("path", help="where to write the copy")
    a = subs.add_parser("account", help="lay down an account (secret on stdin)")
    a.add_argument("owner")
    r = subs.add_parser("account-remove", help="take an account and its documents away")
    r.add_argument("owner")
    return p


def main(argv=None):
    args = parser().parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "backup":
        return backup(args.path)
    if args.command == "account":
        return add_account(args.owner)
    if args.command == "account-remove":
        return remove_account(args.owner)
    return serve()


if __name__ == "__main__":
    raise SystemExit(main())
