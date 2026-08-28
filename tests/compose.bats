#!/usr/bin/env bats
#
# Compose topology invariants — the egress model, asserted against
# docker/docker-compose.yml itself.
#
# These are static YAML assertions, not a booted stack: the suite's `docker` is
# a stub, so there is no real `docker compose config` to render. That is fine
# for what matters here, because the property being protected is structural —
# WHICH networks exist and WHICH services are on them — and that is fully
# determined by the file.
#
# The one invariant worth a permanent test: the agent container must never sit
# on a network that reaches off-host. Everything else about this stack's
# sandboxing (the Squid allowlist, the proxy env vars) is defence layered on
# top of that; if opencode gains a route that bypasses squid, none of it
# matters. A network is cheap to add and the mistake is invisible in review,
# so it is pinned here rather than left to care.

setup() {
  load common
  command -v python3 >/dev/null 2>&1 || skip "python3 required to parse compose YAML"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML required to parse compose YAML"
  COMPOSE_YML="$REPO_ROOT/docker/docker-compose.yml"
}

# compose_q EXPR — evaluate a small python expression against the parsed
# compose file, with `c` bound to the whole document. Keeps each test to one
# readable line instead of a heredoc apiece.
compose_q() {
  python3 -c '
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))
' "$COMPOSE_YML" "$1"
}

# --- the egress invariant ---------------------------------------------------

@test "compose: no agent container is on a non-internal network" {
  # THE test. opencode must reach off-host only via squid, which means it must
  # not be attached to any network lacking internal: true.
  run compose_q '" ".join(n for n in c["services"]["opencode"]["networks"] if not c["networks"][n].get("internal")) or "NONE"'
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "compose: opencode sits on exactly one network, and it is internal" {
  run compose_q '" ".join(c["services"]["opencode"]["networks"])'
  [ "$output" = "oc_proxy" ]
  run compose_q 'c["networks"]["oc_proxy"].get("internal") is True'
  [ "$output" = "True" ]
}

@test "compose: squid is the only service on a non-internal network" {
  # oc-publish is there too — it needs the host for its published ports — so
  # the assertion is that no OTHER service is, and that squid is.
  run compose_q '" ".join(sorted(s for s,v in c["services"].items() if any(not c["networks"][n].get("internal") for n in v.get("networks",[]))))'
  [ "$output" = "oc-publish squid" ]
}

# --- the network budget -----------------------------------------------------

@test "compose: the stack defines exactly two networks" {
  # Each bridge network costs a subnet from dockerd's address pools (~32 on a
  # stock daemon, shared with every other stack on the host). Adding a third
  # network here is a real cost, so it should be a deliberate decision that
  # trips this test — and OCL_NETS_PER_STACK in lib/project.sh must move with
  # it, since the boot-time advice and the --doctor headroom math quote it.
  run compose_q 'len(c["networks"])'
  [ "$output" = "2" ]
}

@test "compose: OCL_NETS_PER_STACK matches the compose file's network count" {
  # The constant drives the exhaustion message and --doctor's arithmetic; a
  # drift here makes both quietly wrong.
  local declared actual
  declared="$(sed -n 's|^: "${OCL_NETS_PER_STACK:=\([0-9]*\)}"|\1|p' "$REPO_ROOT/lib/project.sh")"
  actual="$(compose_q 'len(c["networks"])')"
  [ -n "$declared" ]
  [ "$declared" = "$actual" ]
}

@test "compose: exactly one network reaches off-host" {
  run compose_q 'len([n for n,v in c["networks"].items() if not v.get("internal")])'
  [ "$output" = "1" ]
}

# --- port publishing still works --------------------------------------------

@test "compose: oc-publish is on the external network, so its ports mapping can bind" {
  # A container on internal-only networks cannot serve published ports. This is
  # why the external network exists at all beyond squid's egress.
  run compose_q 'any(not c["networks"][n].get("internal") for n in c["services"]["oc-publish"]["networks"])'
  [ "$output" = "True" ]
}
