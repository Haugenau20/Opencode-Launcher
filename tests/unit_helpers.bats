#!/usr/bin/env bats
#
# Unit tests for the pure helpers in start.sh. These source the script (which is
# side-effect-free thanks to the main() source-guard) and call functions
# directly.

setup() {
  load common
  # ENV_FILE is read at source time; point it at a per-test scratch file.
  export ENV_FILE="$BATS_TEST_TMPDIR/.env"
  source "$REPO_ROOT/start.sh"
}

# --- derive_slug ------------------------------------------------------------

@test "derive_slug: lowercases and replaces spaces/punctuation with dashes" {
  run derive_slug "/home/u/My Cool Repo!!"
  [ "$status" -eq 0 ]
  [ "$output" = "my-cool-repo" ]
}

@test "derive_slug: collapses runs of dashes and trims leading/trailing" {
  run derive_slug "/x/--a..b--"
  [ "$output" = "a-b" ]
}

@test "derive_slug: keeps underscores and digits" {
  run derive_slug "/x/My_Repo_2"
  [ "$output" = "my_repo_2" ]
}

@test "derive_slug: falls back to 'project' when nothing survives" {
  run derive_slug "/x/!!!"
  [ "$output" = "project" ]
}

# --- sed_escape / set_env / get_env round-trip ------------------------------

@test "sed_escape: escapes backslash, ampersand and pipe" {
  run sed_escape 'a\b&c|d'
  [ "$output" = 'a\\b\&c\|d' ]
}

@test "set_env/get_env: round-trips a value with sed-special characters" {
  printf 'LLM_API_KEY=\n' > "$ENV_FILE"
  set_env LLM_API_KEY 'p@ss|w&rd\x'
  run get_env LLM_API_KEY
  [ "$output" = 'p@ss|w&rd\x' ]
}

@test "get_env: preserves '=' and '/' inside the value" {
  printf 'LLM_API_BASE=https://h/v1?a=b&c=d\n' > "$ENV_FILE"
  run get_env LLM_API_BASE
  [ "$output" = 'https://h/v1?a=b&c=d' ]
}

@test "set_env: only rewrites the anchored key, not a same-prefixed one" {
  printf 'HOST_UID=1\nHOST_GID=2\n' > "$ENV_FILE"
  set_env HOST_UID 1000
  [ "$(get_env HOST_UID)" = "1000" ]
  [ "$(get_env HOST_GID)" = "2" ]
}

@test "get_env: returns empty for a missing key" {
  printf 'FOO=bar\n' > "$ENV_FILE"
  run get_env NOPE
  [ "$output" = "" ]
}

# --- find_free_port (port_in_use stubbed) -----------------------------------

@test "find_free_port: returns START when it is free" {
  port_in_use() { return 1; }   # nothing is in use
  run find_free_port 4097 4196
  [ "$output" = "4097" ]
}

@test "find_free_port: skips busy ports and returns the first free one" {
  # 4097 and 4098 busy, 4099 free.
  port_in_use() { case "$1" in 4097|4098) return 0 ;; *) return 1 ;; esac; }
  run find_free_port 4097 4196
  [ "$output" = "4099" ]
}

@test "find_free_port: stops at LIMIT even if everything is busy" {
  port_in_use() { return 0; }   # everything busy
  run find_free_port 4097 4100
  [ "$output" = "4100" ]
}

# --- extra_packages_active / strip_pkg_comments -----------------------------

@test "extra_packages_active: false when the file is absent" {
  run extra_packages_active "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -ne 0 ]
}

@test "extra_packages_active: false when only comments and blank lines" {
  local f="$BATS_TEST_TMPDIR/pk.txt"
  printf '%s\n' '# a comment' '' '   ' '# cmake' > "$f"
  run extra_packages_active "$f"
  [ "$status" -ne 0 ]
}

@test "extra_packages_active: true when a real package line is present" {
  local f="$BATS_TEST_TMPDIR/pk.txt"
  printf '%s\n' '# pick your tools' '' 'cmake' > "$f"
  run extra_packages_active "$f"
  [ "$status" -eq 0 ]
}

@test "strip_pkg_comments: drops comments/blanks, keeps package lines" {
  local f="$BATS_TEST_TMPDIR/pk.txt"
  printf '%s\n' '# header' '' 'cmake' '  ' 'ripgrep' > "$f"
  run strip_pkg_comments "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'cmake\nripgrep')" ]
}

# --- compute_base_image -----------------------------------------------------

@test "compute_base_image: default mode uses REGISTRY:TAG" {
  run compute_base_image reg.test.local/opencode local 0
  [ "$output" = "reg.test.local/opencode:local" ]
}

@test "compute_base_image: --prod pins :prod regardless of IMAGE_TAG" {
  run compute_base_image reg.test.local/opencode local 1
  [ "$output" = "reg.test.local/opencode:prod" ]
}
