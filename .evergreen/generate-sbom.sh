#!/usr/bin/env bash
set -euo pipefail

# Ephemeral SBOM generator (Gradle/Java) using mise + cdxgen.
# Design goals:
#  - Zero persistent global toolchain changes (no `mise use -g`, no global npm installs)
#  - Re-download only if versions not yet cached in mise store
#  - Temporary npm cache isolated per run
#  - Fail fast on errors (non-zero exit if SBOM generation fails)
#
# Environment overrides:
#  MISE_NODE_VERSION   Node version (default 20.11.1)
#  MISE_JAVA_VERSION   Java (Temurin) major version (default 21)
#  CDXGEN_VERSION      cdxgen version or 'latest'
#  SBOM_OUT            Output filename (default sbom.cdx.json)
#
# Usage: bash .evergreen/generate-sbom.sh

NODE_VERSION="${MISE_NODE_VERSION:-20.11.1}"
JAVA_VERSION="${MISE_JAVA_VERSION:-21}"
CDXGEN_VERSION="${CDXGEN_VERSION:-latest}" # or pin like 10.11.0
OUT_JSON="${SBOM_OUT:-sbom.cdx.json}"

log() { printf '\n[sbom] %s\n' "$*"; }

# Ensure mise is available (installed locally in $HOME) and PATH includes shims.

ensure_mise() {
  # Installer places binary in ~/.local/bin/mise by default.
  if ! command -v mise >/dev/null 2>&1; then
    log "Installing mise"
    curl -fsSL https://mise.run | bash >/dev/null 2>&1 || { log "mise install script failed"; exit 1; }
  fi
  # Ensure ~/.local/bin precedes so 'mise' is found even if shims absent.
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.local/share/mise/bin:$PATH"
  if ! command -v mise >/dev/null 2>&1; then
    log "mise not found on PATH after install"; ls -al "$HOME/.local/bin" || true; exit 1
  fi
}

## resolve_toolchain_flags
# Returns space-separated tool@version specs required for SBOM generation.
resolve_toolchain_flags() {
  printf 'node@%s java@temurin-%s' "$NODE_VERSION" "$JAVA_VERSION"
}

## prepare_exec_prefix
# Builds the mise exec prefix for ephemeral command runs.
prepare_exec_prefix() {
  local tools
  tools="$(resolve_toolchain_flags)"
  echo "mise exec $tools --"
}

## prepare_cdxgen_cmd
# Chooses latest or pinned cdxgen via npx (no global install).
prepare_cdxgen_cmd() {
  if [[ "$CDXGEN_VERSION" == "latest" ]]; then
    printf 'npx --yes @cyclonedx/cdxgen'
  else
    printf 'npx --yes @cyclonedx/cdxgen@%s' "$CDXGEN_VERSION"
  fi
}

## generate_sbom
# Executes cdxgen with isolated npm cache, cleans up temp directory.
generate_sbom() {
  log "Generating SBOM"
  local cdxgen_cmd exec_prefix npm_tmp
  cdxgen_cmd="$(prepare_cdxgen_cmd)"
  exec_prefix="$(prepare_exec_prefix)"
  npm_tmp="$(mktemp -d)"
  MISE_NPM_CACHE="$npm_tmp" $exec_prefix bash -c "NPM_CONFIG_CACHE=$npm_tmp $cdxgen_cmd --type gradle --output '$OUT_JSON' ." || {
    log "SBOM generation failed"; rm -rf "$npm_tmp" || true; exit 1; }
  rm -rf "$npm_tmp" || true
  log "SBOM generated"
}

## install_toolchains
# Installs required runtime versions into the local mise cache unconditionally.
# (mise skips download if already present.)
install_toolchains() {
  local tools
  tools="$(resolve_toolchain_flags)"
  log "Installing toolchains: $tools"
  mise install $tools >/dev/null
}

main() {
  ensure_mise
  install_toolchains
  generate_sbom
}

main "$@"