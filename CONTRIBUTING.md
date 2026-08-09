# Contributing to Mär

Thanks for looking. Mär is a focused app — an audio player for self-hosted and
open audio sources — and contributions are welcome.

## Building

**Mär builds without any API keys.** There is nothing to register, request or
paste before you can run it. Two optional app keys (Jamendo, PodcastIndex) are
read from `Config/AppKeys.local.xcconfig` if that file exists; without it the
Jamendo row and the PodcastIndex path simply stay away and everything else
works. You can also enter your own keys in the app under Settings → Network
services.

There are **no third-party dependencies** — no package manager step, nothing to
resolve. Open `Maer.xcodeproj`, pick the `ABSPlayer` scheme, run.

- Xcode with an iOS 26 SDK
- Deployment target iOS/iPadOS 26.5
- Tests: scheme `ABSPlayerTests` (unit tests) · scheme `ABSPlayer` (UI journeys)

## Where

Pull requests and issues go to **<https://codeberg.org/LzS/maer>**.

Open pull requests against **`dev`**, not `main`. `main` carries released
versions only.

## What happens after you open a pull request

There is no automated build here: the test suites run on real hardware, by
hand, so a first response can take a few days. Nothing is wrong if it is quiet
for a while. You can run the same checks yourself if you have a Mac — the two
schemes named under Building are exactly what a maintainer runs.

Merging happens on the project's own Forgejo instance and reaches Codeberg
through the mirror, so your commits arrive with your authorship intact — the
pull request itself is then closed with a link to the merge commit.

## Commits say what they answer

Every commit names the thing it responds to — an issue, a reported defect, or
the change request it implements — so the history can be read backwards from
the code to the reason. Reference issues in the qualified form `LzS/maer#12`,
not as a bare `#12`: this project is served from two forges with independent
issue numbering, and a bare number can resolve to the wrong one.

## Licence

By contributing you agree that your contribution is licensed under GPL-3.0 and
that the project's copyright holder may grant the app-store additional
permission described in LICENSE-ADDITIONAL-TERMS for it as well.

The same file reserves the name "Mär" and the app icon (Part 2); that
reservation is not affected by contributing, and it does not restrict forks —
they just carry their own name.

## What a contribution is measured against

These are the standards the project already holds itself to. They are here so
you can read them before writing code, not after review.

- **One shared component instead of a copy.** If the same thing gets built a
  second time, that is a finding, not a merge.
- **No silent failure.** What goes wrong becomes visible — an empty list is not
  an error message.
- **No control without a destination.** A row heading that leads nowhere, a
  button that does nothing on some path: not shipped.
- **Behaviour changes apply everywhere,** not only on the surface where the
  problem showed up.
- **Claims are measured, not argued.** If you name a cause, show it — a log
  line, a count, a probe. "Probably" is a reason to go and look.

Small fixes do not need a design discussion. For larger changes, open an issue
first so we can agree on the shape before you spend the evening.

## Security

Please do not open a public issue for a security problem. Write to
`<KONTAKTADRESSE — noch einzutragen>` instead.
