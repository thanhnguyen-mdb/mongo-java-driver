#!/usr/bin/env bash
set -euo pipefail

# generate-sbom.sh
# Purpose: Produce a CycloneDX SBOM for the MongoDB Java Driver via cdxgen and enrich it with Parlay.
# Usage: bash .evergreen/generate-sbom.sh [--quiet]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
  esac
done

log() { [ "$QUIET" -eq 1 ] || echo "$*" >&2; }
err() { echo "ERROR: $*" >&2; }

require_cmd() {
  local c="$1"; shift || true
  if ! command -v "$c" >/dev/null 2>&1; then
    err "Missing required command: $c. $*"; exit 1;
  fi
}

log "Checking prerequisites"
if command -v node >/dev/null 2>&1; then
  NODE_VER_RAW="$(node -v 2>/dev/null || echo v0.0.0)"
  NODE_MAJOR="${NODE_VER_RAW#v}"
  NODE_MAJOR="${NODE_MAJOR%%.*}"
else
  NODE_MAJOR="0"
fi

# Evergreen distro images may have an older Node; bootstrap a local Node 20+ into .evergreen/node if needed.
if [ "$NODE_MAJOR" -lt 20 ]; then
  log "Bootstrapping Node.js 20 (current: ${NODE_VER_RAW:-none})"
  NODE_DIR="$SCRIPT_DIR/node"
  mkdir -p "$NODE_DIR"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    *) err "Unsupported architecture for Node bootstrap: $ARCH"; exit 1;;
  esac
  NODE_TGZ="node-v20.11.1-linux-${NODE_ARCH}.tar.xz"
  NODE_URL="https://nodejs.org/dist/v20.11.1/${NODE_TGZ}"
  wget -q -O "$NODE_DIR/${NODE_TGZ}" "$NODE_URL" || { err "Failed to download Node.js $NODE_URL"; exit 1; }
  tar -xf "$NODE_DIR/${NODE_TGZ}" -C "$NODE_DIR" || { err "Failed to extract Node.js"; exit 1; }
  export PATH="$NODE_DIR/node-v20.11.1-linux-${NODE_ARCH}/bin:$PATH"
  hash -r || true
  log "Using bootstrapped Node: $(node -v)"
fi

require_cmd node "Install Node.js >= 20 (https://nodejs.org/) or allow bootstrap"
require_cmd npm "Install Node.js/npm"
require_cmd wget "Install wget (e.g., sudo apt-get install -y wget)"
require_cmd jq "Install jq (e.g., sudo apt-get install -y jq)"
require_cmd tar "Install tar (e.g., sudo apt-get install -y tar)"

# Ensure we have a Java runtime >=17 for Gradle plugins used during dependency resolution.
JAVA_MAJOR=0
if command -v java >/dev/null 2>&1; then
  # java -version outputs 'openjdk version "21.0.2"' etc.
  JAVA_VERSION_LINE="$(java -version 2>&1 | head -n1)"
  # Extract first numeric token in quotes if present.
  JAVA_MAJOR="$(echo "$JAVA_VERSION_LINE" | sed -E 's/.*version "([0-9]+).*".*/\1/' || echo 0)"
fi

pick_env_jdk() {
  for CAND in "$JDK21" "$JDK17"; do
    if [ -n "$CAND" ] && [ -x "$CAND/bin/java" ]; then
      export JAVA_HOME="$CAND"
      export PATH="$JAVA_HOME/bin:$PATH"
      return 0
    fi
  done
  return 1
}

if [ "$JAVA_MAJOR" -lt 17 ]; then
  log "Current Java version <17 (detected: ${JAVA_MAJOR:-none}); attempting to select provided JDK environment variables"
  if ! pick_env_jdk; then
    log "No suitable JDK from env vars; bootstrapping Temurin JDK 21 locally"
    JDK_DIR="$SCRIPT_DIR/jdk"
    mkdir -p "$JDK_DIR"
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64|amd64) JDK_ARCH="x64" ;;
      aarch64|arm64) JDK_ARCH="aarch64" ;;
      *) err "Unsupported architecture for JDK bootstrap: $ARCH"; exit 1;;
    esac
    JDK_TAR="OpenJDK21U-jdk_${JDK_ARCH}_linux_hotspot.tar.gz"
    JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/latest/download/${JDK_TAR}"
    wget -q -O "$JDK_DIR/$JDK_TAR" "$JDK_URL" || { err "Failed to download JDK ($JDK_URL)"; exit 1; }
    tar -xzf "$JDK_DIR/$JDK_TAR" -C "$JDK_DIR" || { err "Failed to extract JDK"; exit 1; }
    EXTRACTED="$(find "$JDK_DIR" -maxdepth 1 -type d -name 'jdk-21*' | head -n1)"
    if [ -z "$EXTRACTED" ]; then
      err "Could not locate extracted JDK directory"; exit 1;
    fi
    export JAVA_HOME="$EXTRACTED"
    export PATH="$JAVA_HOME/bin:$PATH"
  fi
  JAVA_VERSION_LINE="$(java -version 2>&1 | head -n1)"
  log "Using Java runtime: $JAVA_VERSION_LINE"
fi

require_cmd java "Install JDK >=17 or allow bootstrap"

if ! npx --no-install cdxgen --version >/dev/null 2>&1; then
  log "Installing @cyclonedx/cdxgen"
  npm install @cyclonedx/cdxgen >/dev/null 2>&1 || { err "Failed to install cdxgen"; exit 1; }
fi

if ! command -v parlay >/dev/null 2>&1; then
  log "Installing Parlay"
  ARCH="$(uname -m)"; OS="$(uname -s)"
  case "$ARCH" in
    x86_64|amd64) ARCH_DL="x86_64" ;;
    aarch64|arm64) ARCH_DL="aarch64" ;;
    *) err "Unsupported architecture for parlay: $ARCH"; exit 1;;
  esac
  if [ "$OS" != "Linux" ]; then
    err "Parlay install script currently supports Linux only"; exit 1;
  fi
  PARLAY_TAR="parlay_Linux_${ARCH_DL}.tar.gz"
  wget -q "https://github.com/snyk/parlay/releases/latest/download/${PARLAY_TAR}" || { err "Failed to download Parlay"; exit 1; }
  tar -xzf "$PARLAY_TAR"
  chmod +x parlay || true
  mv parlay "$SCRIPT_DIR/parlay-bin" || true
  export PATH="$SCRIPT_DIR:$PATH"
fi

SBOM_FILE="sbom.cdx.json"
ENRICHED_SBOM_FILE="sbom.cdx.parlay.json"

log "Generating SBOM: $SBOM_FILE"
(cd "$REPO_ROOT" && npx cdxgen --type gradle --output "$SBOM_FILE" >/dev/null) || { err "cdxgen failed"; exit 1; }
mv "$SBOM_FILE" "$SBOM_FILE.raw"
jq . "$SBOM_FILE.raw" > "$SBOM_FILE" || { err "Failed to pretty-print SBOM"; exit 1; }
rm -f "$SBOM_FILE.raw"

grep -q 'CycloneDX' "$SBOM_FILE" || { err "CycloneDX marker missing in $SBOM_FILE"; exit 1; }
test $(stat -c%s "$SBOM_FILE") -gt 1000 || { err "SBOM file too small (<1000 bytes)"; exit 1; }

log "Enriching SBOM: $ENRICHED_SBOM_FILE"
parlay ecosystems enrich "$SBOM_FILE" > "$ENRICHED_SBOM_FILE.raw" || { err "Parlay enrichment failed"; exit 1; }
jq . "$ENRICHED_SBOM_FILE.raw" > "$ENRICHED_SBOM_FILE" || { err "Failed to pretty-print enriched SBOM"; exit 1; }
rm -f "$ENRICHED_SBOM_FILE.raw"

log "Done"
echo "SBOM: $SBOM_FILE"
echo "SBOM (enriched): $ENRICHED_SBOM_FILE"
