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
2. Move the `[Unreleased]` items in `CHANGELOG.md` under a new
   `## [x.y.z] — YYYY-MM-DD` heading in the **Launcher releases** section.
3. (Optional but recommended once a release is "real") tag the release commit:
   `git tag -a vX.Y.Z -m "Launcher vX.Y.Z" && git push --tags`.
