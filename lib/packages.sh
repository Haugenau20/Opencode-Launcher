# shellcheck shell=bash
#
# lib/packages.sh — optional system-package layer: parse extra-packages.txt, base image
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.

# strip_pkg_comments FILE — echo only the meaningful package lines of FILE
# (drops blank lines and '#' comment lines). Missing file => no output. Mirrors
# the filter baked into Dockerfile.user-packages so detection and the build agree.
strip_pkg_comments() {
  local f="${1:-$EXTRA_PACKAGES_FILE}"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

# extra_packages_active [FILE] — exit 0 iff FILE lists at least one package
# (after stripping comments/blanks). Empty or absent => non-zero (feature off).
extra_packages_active() {
  [ -n "$(strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}")" ]
}

# extra_apt_packages [FILE] / extra_pip_packages [FILE] — split the meaningful
# lines into the apt and pip buckets, mirroring the classification baked into
# Dockerfile.user-packages. apt = lines without a `pip:` prefix (the optional
# `apt:` prefix is stripped); pip = `pip:`-prefixed lines (prefix stripped).
# Used only to report what's being baked; the build does its own parsing.
extra_apt_packages() {
  strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}" \
    | grep -vE '^[[:space:]]*pip:' \
    | sed -E 's/^[[:space:]]*apt:[[:space:]]*//;s/^[[:space:]]+//;s/[[:space:]]+$//' || true
}
extra_pip_packages() {
  strip_pkg_comments "${1:-$EXTRA_PACKAGES_FILE}" \
    | grep -E '^[[:space:]]*pip:' \
    | sed -E 's/^[[:space:]]*pip:[[:space:]]*//' || true
}

# compute_base_image REGISTRY TAG — echo the registry image start.sh runs for
# `opencode` (REGISTRY:TAG, where TAG comes from IMAGE_TAG in .env). Used both as
# the access-check target and as BASE_IMAGE for the package overlay's build.
# TAG is normally a moving/pinned tag name (joined with ':', e.g. 'latest',
# '0.0.2'). For full reproducibility TAG may instead be a digest — accepted as
# either 'sha256:...' or '@sha256:...' — in which case it's joined with '@'
# instead, producing Docker's own digest-reference syntax
# (registry/image@sha256:...) rather than the invalid registry:@sha256:...
compute_base_image() {
  local registry="$1" tag="$2"
  case "$tag" in
    @sha256:*) printf '%s%s' "$registry" "$tag" ;;
    sha256:*)  printf '%s@%s' "$registry" "$tag" ;;
    *)         printf '%s:%s' "$registry" "$tag" ;;
  esac
}
