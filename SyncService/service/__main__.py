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

import os
import sys

from .app import make
from .store import Store


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


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "account":
        return add_account(sys.argv[2] if len(sys.argv) > 2 else "")

    application = make()
    try:
        import uvicorn
    except ImportError:
        print("no application server installed. This service needs one that speaks ASGI "
              "and carries WebSockets; uvicorn is the reference. Install it pinned, with "
              "its hash checked, as a deliberate step.", file=sys.stderr)
        return 3

    uvicorn.run(application,
                host=os.environ.get("MAER_SYNC_HOST", "127.0.0.1"),
                port=int(os.environ.get("MAER_SYNC_PORT", "8099")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
