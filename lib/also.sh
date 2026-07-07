# shellcheck shell=bash
#
# lib/also.sh — `--also <path>[:rw]` extra repo/folder mounts: parsing,
# validation, and the generated per-project overlay (.envs/<slug>.also.yml)
#
# Sourced by start.sh (not run standalone); see the source-order contract
# there. Pure function definitions, no top-level side effects, so the file
# is safe to source for unit tests.
#
# Design: --also is repeatable ("--also PATH" or "--also PATH:rw"), default
# read-only. Each resolves to a bind mount at /workspace-extra/<name> inside
# the container, where <name> = derive_slug(basename(PATH)) (lib/project.sh),
# with -2/-3/... suffixing on a name collision between two --also paths. The
# base compose file set is static, so a small per-project overlay is
# generated at boot (.envs/<slug>.also.yml, appended LAST in COMPOSE_FILES)
# rather than the base docker-compose.yml trying to carry a variable number of
# bind mounts. A path containing ':' beyond the optional trailing ':rw' is not
# supported (matches Docker's own short bind-mount syntax limitation) — that's
# documented, not detected/rejected here.

# also_overlay_file SLUG — echo the path to SLUG's generated --also overlay
# (whether or not it currently exists on disk).
also_overlay_file() {
  printf '%s/%s.also.yml' "$ENVS_DIR" "$1"
}

# also_context_file SLUG — echo the host path of SLUG's generated breadcrumb
# markdown (whether or not it currently exists). This is the file mounted
# read-only into the container and named to opencode via
# OPENCODE_EXTRA_INSTRUCTIONS; a sibling of the overlay under $ENVS_DIR.
also_context_file() {
  printf '%s/%s.also-context.md' "$ENVS_DIR" "$1"
}

# ALSO_CONTEXT_CONTAINER_PATH — where the breadcrumb is mounted inside the
# container, and the value OPENCODE_EXTRA_INSTRUCTIONS points at. Deliberately
# NOT under /workspace-extra/ (so it never shows up among the user's own mounts
# nor in --status' overlay parse) and NOT under /workspace or the config dir
# (so it neither pollutes the repo nor collides with the image entrypoint's
# chown of ~/.config/opencode). /etc/opencode is opencode's own read-only
# config area, which the entrypoint reads but never rewrites. The image treats
# this as an opaque path handed to it via the env var — it has no /etc/opencode
# or --also knowledge of its own.
ALSO_CONTEXT_CONTAINER_PATH="/etc/opencode/also-context.md"

# resolve_also_mounts REPO_PATH SPEC... — validate and resolve each --also
# SPEC ("path" or "path:rw", in the order given on the command line) against
# REPO_PATH (the main repo's own resolved absolute path). Echoes one
# "abs_path<TAB>ro|rw<TAB>name" line per SPEC, in argument order. Dies
# (die(), i.e. exit 1) when:
#   - the path doesn't exist or isn't a directory
#   - the path resolves to REPO_PATH itself (already mounted at /workspace)
resolve_also_mounts() {
  local repo_path="$1"; shift
  local spec path mode abs name base
  local -A seen=()
  for spec in "$@"; do
    case "$spec" in
      *:rw) path="${spec%:rw}"; mode="rw" ;;
      *)    path="$spec";       mode="ro" ;;
    esac
    [ -e "$path" ] || die "--also path does not exist: $path"
    [ -d "$path" ] || die "--also path is not a directory: $path"
    abs="$(cd -- "$path" >/dev/null 2>&1 && pwd)" || die "could not resolve --also path: $path"
    [ "$abs" != "$repo_path" ] || die "--also path duplicates the main repo path (already mounted at /workspace): $abs"

    base="$(derive_slug "$(basename -- "$abs")")"
    if [ -n "${seen[$base]:-}" ]; then
      seen[$base]=$(( seen[$base] + 1 ))
      name="${base}-${seen[$base]}"
    else
      seen[$base]=1
      name="$base"
    fi
    printf '%s\t%s\t%s\n' "$abs" "$mode" "$name"
  done
}

# also_mount_lines MOUNTS_TSV — print one boot/status report line per mount
# ("also: /abs/host/path -> /workspace-extra/<name> (read-only|read-write)"),
# reading resolve_also_mounts'/also_mounts_from_overlay's TSV shape. Emits via
# info() (lib/core.sh). No-op on empty input.
also_mount_lines() {
  local mounts="$1" abs mode name
  [ -n "$mounts" ] || return 0
  while IFS=$'\t' read -r abs mode name; do
    [ -n "$abs" ] || continue
    if [ "$mode" = "rw" ]; then
      info "also: $abs -> /workspace-extra/${name} (read-write)"
    else
      info "also: $abs -> /workspace-extra/${name} (read-only)"
    fi
  done <<< "$mounts"
}

# write_also_context SLUG MOUNTS_TSV — (re)generate SLUG's breadcrumb markdown
# from resolve_also_mounts' TSV. It names each --also mount, its absolute
# container path (/workspace-extra/<name>), and whether it is read-only or
# read-write, plus a one-line instruction. This is the file the image loads as
# global instructions (via OPENCODE_EXTRA_INSTRUCTIONS -> opencode.json's
# `instructions`), which is how the agent discovers folders that live outside
# its /workspace project root — an open-ended search never leaves /workspace on
# its own. Owning the wording HERE (not in the image) is the point: the image
# stays a generic instruction loader; --also and its presentation live in the
# launcher. Caller only invokes this when there is >= 1 mount.
write_also_context() {
  local slug="$1" mounts="$2" file abs mode name label
  file="$(also_context_file "$slug")"
  mkdir -p "$ENVS_DIR"
  {
    echo '# Extra context folders (outside the project root)'
    echo
    echo 'These folders are mounted into this container as extra context, as'
    echo 'siblings of the project root at `/workspace`. They live OUTSIDE the'
    echo 'project root, so an open-ended file search from `/workspace` will not'
    echo 'find them. When a request refers to one of these by name, read it'
    echo 'directly at the absolute path listed below.'
    echo
    while IFS=$'\t' read -r abs mode name; do
      [ -n "$abs" ] || continue
      if [ "$mode" = "rw" ]; then label="read-write"; else label="read-only"; fi
      printf -- '- **%s** — `/workspace-extra/%s` (%s)\n' "$name" "$name" "$label"
    done <<< "$mounts"
  } > "$file"
}

# write_also_overlay SLUG MOUNTS_TSV — (re)generate .envs/<slug>.also.yml from
# resolve_also_mounts' TSV output: one bind-mount volume line per mount,
# `ro,z` for read-only (the default) or plain `z` for read-write (SELinux
# shared relabel either way, matching the :z convention already used on
# /workspace itself — see docs/SYNC.md). Also generates the breadcrumb
# (write_also_context), mounts it read-only, and sets OPENCODE_EXTRA_INSTRUCTIONS
# so the image loads it — that env var is the whole image-side contract; the
# image knows nothing about --also or /workspace-extra. Caller should only call
# this when there is at least one mount; see delete_also_overlay for the "no
# --also this run" case.
write_also_overlay() {
  local slug="$1" mounts="$2" file abs mode name flag ctx_host
  file="$(also_overlay_file "$slug")"
  ctx_host="$(also_context_file "$slug")"
  write_also_context "$slug" "$mounts"
  mkdir -p "$ENVS_DIR"
  {
    echo "# generated by start.sh --also; do not edit"
    echo "services:"
    echo "  opencode:"
    echo "    environment:"
    echo "      # Point opencode at the breadcrumb below (mounted read-only just"
    echo "      # under volumes:) so the agent discovers these out-of-project"
    echo "      # folders. The image honors this generic var; it has no --also"
    echo "      # or /workspace-extra knowledge of its own."
    echo "      OPENCODE_EXTRA_INSTRUCTIONS: ${ALSO_CONTEXT_CONTAINER_PATH}"
    echo "    volumes:"
    while IFS=$'\t' read -r abs mode name; do
      [ -n "$abs" ] || continue
      if [ "$mode" = "rw" ]; then flag="z"; else flag="ro,z"; fi
      echo "      - ${abs}:/workspace-extra/${name}:${flag}"
    done <<< "$mounts"
    echo "      - ${ctx_host}:${ALSO_CONTEXT_CONTAINER_PATH}:ro,z"
  } > "$file"
}

# delete_also_overlay SLUG — remove SLUG's generated --also overlay AND its
# breadcrumb if present. Called on every boot with NO --also flags, so a
# previous run's extra mounts (and its now-meaningless breadcrumb) don't linger
# into this one (compose up -d then recreates the container without them). A
# no-op (not an error) when the files are absent.
delete_also_overlay() {
  rm -f "$(also_overlay_file "$1")" "$(also_context_file "$1")"
}

# also_mounts_from_overlay SLUG — echo resolve_also_mounts-shaped TSV lines
# ("abs_path<TAB>ro|rw<TAB>name") parsed back out of .envs/<slug>.also.yml, or
# nothing if the file doesn't exist. Used by --status to report the mounts a
# stack was last booted with, without re-deriving anything — the file's shape
# is fully controlled by write_also_overlay above, so this is a plain,
# known-shape parse, not a general YAML reader.
also_mounts_from_overlay() {
  local file mode
  file="$(also_overlay_file "$1")"
  [ -f "$file" ] || return 0
  # Trailing `|| true`: under set -o pipefail, a well-formed-but-mountless
  # file (grep matches nothing) would otherwise make this whole pipeline —
  # and thus this function — exit non-zero as its LAST statement, which would
  # abort a set -e caller. Mirrors compose_ls_pairs' own guard in
  # lib/commands.sh.
  grep -E '^ *- .+:/workspace-extra/.+:(ro,z|z)$' "$file" | while IFS= read -r line; do
    local rest hostpath tail name flags
    rest="${line#*- }"
    hostpath="${rest%%:/workspace-extra/*}"
    tail="${rest#*:/workspace-extra/}"
    name="${tail%%:*}"
    flags="${tail##*:}"
    if [ "$flags" = "z" ]; then mode="rw"; else mode="ro"; fi
    printf '%s\t%s\t%s\n' "$hostpath" "$mode" "$name"
  done || true
}
