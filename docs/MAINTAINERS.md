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
is announced, add an Image-releases entry with its Action-required line and
update the Compatibility table.

Concretely:

1. Bump the [`VERSION`](../VERSION) file.
2. Add a new `## [x.y.z] — YYYY-MM-DD` entry at the top of the
   **Launcher releases** section describing what shipped. (There is no
   "Unreleased" section by design — the changelog lists released versions only;
   upcoming work is not advertised here or in the README.)
3. (Optional but recommended once a release is "real") tag the release commit:
   `git tag -a vX.Y.Z -m "Launcher vX.Y.Z" && git push --tags`.
