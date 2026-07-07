# shellcheck shell=bash
#
# lib/manifest.sh — image self-description: manifest.json / CHANGELOG.md /
# OCI version label, and the drift check against this launcher's .env.example
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.
#
# Newer images ship /etc/opencode/manifest.json, /etc/opencode/CHANGELOG.md,
# and an org.opencontainers.image.version OCI label; older images have none of
# it. Every function here is best-effort and image-not-present/no-manifest
# safe: on an old image (or one that hasn't been pulled yet) they simply echo
# nothing, so callers never need to special-case "old image" themselves —
# they just get empty output and skip whatever they were going to print.

# image_manifest IMAGE — echo the contents of /etc/opencode/manifest.json
# from IMAGE, or nothing. Only attempts the read when IMAGE already exists
# locally (`docker image inspect`), so this never triggers a pull. Never
# fails the caller: any error (old image with no manifest, `docker run`
# unavailable, etc.) just yields empty output.
image_manifest() {
  local image="$1" out
  docker image inspect "$image" >/dev/null 2>&1 || return 1
  out="$(docker run --rm --entrypoint cat "$image" /etc/opencode/manifest.json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# manifest_env_keys [MANIFEST_JSON] — echo each env_keys[].key name from a
# manifest.json payload, one per line, in document order. Reads MANIFEST_JSON
# from $1 if given, else from stdin (mirrors image_manifest's typical
# `image_manifest "$IMAGE" | manifest_env_keys` pipeline).
#
# No jq dependency (deliberate repo convention — see compose_ls_pairs in
# lib/commands.sh for the precedent). This is a `grep -oE` + `sed` extraction
# for the KNOWN manifest shape (`{"key": "NAME", ...}` objects inside
# env_keys[]) — it is NOT a general JSON parser. It doesn't track array
# boundaries, but "key" only ever appears inside env_keys[] objects in this
# contract, so that's not needed; `grep -o` (rather than a single `sed`
# substitution) is what lets it find EVERY match per line, since the
# contract's own manifest.json shows the whole env_keys array collapsed onto
# one line.
manifest_env_keys() {
  local input
  if [ $# -gt 0 ]; then
    input="$1"
  else
    input="$(cat)"
  fi
  printf '%s\n' "$input" \
    | grep -oE '"key"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/^.*"([^"]*)"$/\1/'
}

# manifest_missing_keys MANIFEST_JSON — echo every manifest env key NOT
# present in this launcher's own $ENV_EXAMPLE (one per line). This is the
# drift signal: the image consumes an env key this launcher version doesn't
# know about, so the user needs a newer launcher (`git pull`). Reuses
# env_example_keys (lib/digest.sh) as the launcher's own set of known keys.
manifest_missing_keys() {
  local manifest_json="$1" known key
  known="$(env_example_keys)"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! printf '%s\n' "$known" | grep -qxF "$key"; then
      printf '%s\n' "$key"
    fi
  done < <(manifest_env_keys "$manifest_json")
}

# image_version_label IMAGE — echo the org.opencontainers.image.version OCI
# label of IMAGE, or nothing (old image with no label, image not present
# locally, `docker` error, etc. all degrade to empty output).
image_version_label() {
  local image="$1" out
  out="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image" 2>/dev/null)" || return 1
  case "$out" in
    ''|'<no value>'|'<nil>') return 1 ;;
  esac
  printf '%s' "$out"
}

# image_changelog_section IMAGE VERSION — echo the VERSION section of
# IMAGE's /etc/opencode/CHANGELOG.md (a `## [VERSION] — ...` heading through
# to, but not including, the next `## ` heading), capped to the first 25
# lines. Best-effort: empty on any failure (old image with no CHANGELOG.md,
# VERSION not found in it, etc).
image_changelog_section() {
  local image="$1" version="$2" out
  out="$(docker run --rm --entrypoint sed "$image" \
    -n "/^## \[${version}\]/,/^## /p" /etc/opencode/CHANGELOG.md 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  # The range match above intentionally includes the NEXT section's heading
  # as its end marker (sed ranges are inclusive); trim it back off if present
  # so only VERSION's own section is echoed. A VERSION with no successor (the
  # newest entry) has no trailing heading to trim, so this is a no-op there.
  printf '%s\n' "$out" | sed '$ { /^## / d }' | head -n 25
}
