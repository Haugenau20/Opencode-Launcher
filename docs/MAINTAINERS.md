# Maintainer notes

Short operational notes for whoever cuts launcher releases and tracks image
announcements. For keeping the compose stack in sync with the image repo, see
[`SYNC.md`](SYNC.md).

## Versioning

- The launcher uses a SemVer-ish `MAJOR.MINOR.PATCH` while in early `0.x`
  development. The **current version lives in the root [`VERSION`](../VERSION)
  file** (printed by `./start.sh --version`); the full history is in
  [`../CHANGELOG.md`](../CHANGELOG.md).
- The launcher and the image are versioned **independently** — never assume a
  launcher bump implies an image bump or vice versa.

## Cutting a release

When cutting a launcher release, add a Launcher-releases entry. When a new image
is announced, add an Image-releases entry with its Action-required line — and if
that image needs a newer launcher, say so on that line as `update launcher
(≥ x.y.z)`.

There is **no** version-compatibility matrix to maintain: the supported pairing
is simply the latest launcher with the latest image. Only call out a minimum
launcher version when an image genuinely needs one (e.g. it adds `.env` fields
the older launcher's setup/doctor/`.env.example` don't know about). An image
that just adds a plain env var the entrypoint reads needs no such note.

Concretely:

1. Bump the [`VERSION`](../VERSION) file.
2. Add a new `## [x.y.z] — YYYY-MM-DD` entry at the top of the
   **Launcher releases** section describing what shipped. (There is no
   "Unreleased" section by design — the changelog lists released versions only;
   upcoming work is not advertised here or in the README.)
3. (Optional but recommended once a release is "real") tag the release commit:
   `git tag -a vX.Y.Z -m "Launcher vX.Y.Z" && git push --tags`.
