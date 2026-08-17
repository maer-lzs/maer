# Migrating device playlist entries — the rescue-copy trap

Device playlists (`MaerPlaylists`) reconcile across a person's devices **per
list, newest wins**, and the losing version is kept as a rescue copy rather
than dropped. That combination makes any migration that REWRITES entry ids a
special case, and the trap is silent: it does not lose data, it multiplies it.

This note exists because the case was measured and then not built (the one
person affected had deleted the affected lists). It applies to **every** future
migration of playlist entries, not just that one.

## The trap

Say a migration expands an album entry into its tracks —
`[sub:album:1]` becomes `[sub:song:a, sub:song:b]`.

1. Device A migrates and bumps `updatedAt`.
2. Device B has not migrated yet (older build, offline, not launched).
3. A's version wins the merge. The loser is B's version.
4. `MaerPlaylistMerge.merge` compares `loser.itemIds != winner.itemIds`. The
   two sets are **disjoint by construction**, so it reads as divergence.
5. `needsRescue` compares by content and finds nothing equal.

⇒ A rescue copy `"<name> (as of …)"` is created — on A, and again on B when it
pulls A's version. **After the update every list stands twice on every device.**

## The shape that works

Not a done-flag and not a pre-state array. A **set of superseded container
ids**, per list, appended to as migrations run:

- Field `superseded: [String]` on `MaerPlaylists.Playlist` **and** on
  `MaerPlaylistMerge.Entry`, so it travels with the list. A build that does not
  know the field decodes without it (tolerant decoding, as with `isRescue`).
- The suppression belongs in **`merge()`**, not in `needsRescue`: `merge` holds
  winner and loser. A loser is only rescued when it carries an id that is
  neither in `winner.itemIds` nor in `winner.superseded` — which is exactly the
  "knowledge only one side has" semantics the rescue exists for. A loser whose
  every entry lives on, either as itself or as an expanded container, has
  nothing to rescue.
- A set, not the previous state: generation 2 of a migration would otherwise
  forget generation 0, and a device that was away for two of them produces a
  rescue copy after all.

## Things that are NOT optional

- **`updatedAt` must be bumped** when the healing changed something. Without
  it, two devices tie, `merge` prefers the local side on a tie, and they push
  their versions at each other forever.
- **Accept and state the edge:** a healing bump can overtake a fresh tombstone
  from another device, so a list deleted seconds earlier can come back once.
  The window is the upgrade moment; without knowledge of the other device it
  cannot be closed. Say it out loud rather than pretending it does not exist.
- **A failed expansion is not a result.** Per entry there are three outcomes —
  expanded, rule says as-is, and *failed* (server unreachable, timeout). A
  failure leaves the entry alone and the next run tries again; treating it as
  "migrated" is the negative-cache mistake in another costume.
- **Never truncate silently at the entry limit.** An expansion can push a list
  past the cap: that entry stays a container, is logged once, and is counted in
  the report.
- **The healing is convergent, not a one-shot.** It runs at load and after every
  cloud apply; a device that arrives late heals itself. Idempotent by
  construction, because an already-expanded id expands to itself.
