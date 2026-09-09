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

from .app import Insecure, make


def main():
    try:
        application = make()
    except Insecure as refusal:
        print(f"refusing to start: {refusal}", file=sys.stderr)
        return 2

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
