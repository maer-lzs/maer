# Mär: sync and sign-in

Back to the [README](../README.md) · [Deutsch](sync-and-sign-in.de.md)

## Core sync rule

This is the heart of the app. A user-triggered seek action (scrubber, chapter jump, skip buttons, or lock screen control) is treated as intentional and synced immediately, even backwards. A warning dialog only appears if progress drops by more than 120 seconds **without user action**, for example due to a faulty client reset. If the user cancels, playback jumps back to the last stored position. The lock screen has no palm detection, so a series of more than five skips within four seconds there is not carried out further: the app asks once whether the whole series was meant.

When switching devices, the app checks the server before each playback start and waits up to 1.5 seconds for its answer; a server that does not answer in time does not hold the player, and the start goes ahead from the position on the device. The entry with the newer timestamp wins: if another device wrote last, its position is adopted, even if it is **further back** (e.g. after deliberately rewinding there). On older servers without a timestamp, only a further-ahead server position is adopted. True simultaneous listening on two devices is not covered; in that case, the last writer wins.

Every progress write sends the current time and the finished status together, and the duration and progress whenever the duration is known, rather than a partial update; a partial update leaves the server to guess what to do with the fields it wasn't given, which previously caused real progress loss when only the finished flag was toggled. Without a known duration (a multi-file book the server gave none for) the app leaves duration and progress out, because a progress of 0 would overwrite the server's.

## Sign-in options

The app signs in either with your Audiobookshelf **username and password** (the default: it exchanges them for a token via `/login` and stores only the token in the keychain) or directly with an **API token**. The password sign-in asks the server for its tokens in the answer and runs in a session of its own, so no cookie of the sign-in stays in the app.

When the server offers **single sign-on** (OpenID Connect, set up in Audiobookshelf), the sign-in form shows a button for it under Connect. It opens your provider's page in the system's sign-in window and returns to Mär with the server's token; the server must admit the return address `audiobookshelf://oauth`, which Audiobookshelf does by default.

Note for servers on the new JWT authentication (v2.26.0+): the password login receives a short-lived access token there, so the session can expire. The app keeps the token, shows the state at the Audiobookshelf source and checks again by itself; only when the server still refuses it does the app offer a new sign-in, prefilled, and it deletes nothing on its own. On such servers an API key is the more durable choice.

How to find your token:

- **Older server versions:** Web interface → Settings → Users → select your account → the token is displayed.
- **Newer server versions:** Web interface → Settings → API Keys → create a new key.

If you are not sure which variant your server uses, try both. One of these paths will exist.
