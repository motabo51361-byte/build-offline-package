#!/usr/bin/env bash
# build-offline-package.sh
# One-shot, resumable offline package builder for the Azure AI Translator container.
#
# Design goal: this script can be re-run any number of times (e.g. after the
# container's SAS token expires mid-download, or the process gets killed) and
# will always pick up where it left off. At the start of every step it checks
# real on-disk / docker state and skips work that is already done, instead of
# relying on a separate "progress" marker file.
#
# Steps:
#   0. Short-circuit: if a valid, hash-verified package already exists, stop here.
#   1. docker pull the container image (skipped if already present locally)
#   2. docker save -> archive/oci-azure-translator-text-translation.tar
#      (skipped if the tar already matches the currently loaded image ID)
#   3. docker compose up to download models + license. Retries automatically;
#      already-downloaded files are only re-validated by the container, not
#      re-downloaded, so interrupting/rerunning is always safe.
#   4. Parse MODELS / TRANSLATORSYSTEMCONFIG from the container's own log,
#      generate the offline run-compose file, and tar.gz everything into a
#      self-contained delivery package + SHA256SUMS.txt.
#
# Deliberately NOT done after success: the script does not delete the docker
# image, the downloaded models/license, or the image tar. Keeping them is what
# makes reruns fast and makes the "already done, skip it" checks possible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SCRIPT_START_TIME=$(date +%s)
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    -h|--help)
      echo "Usage: $0 [--force]"
      echo "  --force   Ignore all 'already done' checks and rebuild everything."
      exit 0
      ;;
  esac
done

echo "========================================"
echo "Script started at : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# ===========================
# Config / paths
# ===========================
IMAGE="mcr.microsoft.com/azure-cognitive-services/translator/text-translation:latest"
CONTAINER_NAME="azure-ai-translator"

WORK_ROOT="$SCRIPT_DIR/azure-ai-translator"
MODELS_DIR="$WORK_ROOT/models"
LOGS_DIR="$WORK_ROOT/logs"
LICENSE_DIR="$WORK_ROOT/license"
OUTPUT_DIR="$WORK_ROOT/output"
HOTFIX_DIR="$WORK_ROOT/hotfix"
ARCHIVE_DIR="$SCRIPT_DIR/archive"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
COMPOSE_LOG="$ARCHIVE_DIR/log-download-models_${TIMESTAMP}.log"

IMAGE_TAR_NAME="oci-azure-translator-text-translation.tar"
IMAGE_TAR_PATH="$ARCHIVE_DIR/$IMAGE_TAR_NAME"
IMAGE_TAR_ID_PATH="$IMAGE_TAR_PATH.imageid"

RUN_COMPOSE_NAME="run-disconnected-container-docker-compose.yaml"
DOWNLOAD_COMPOSE_FILE="$SCRIPT_DIR/download-models-docker-compose.generated.yaml"
ENV_PATH="$SCRIPT_DIR/.env"
SHA_FILE="$ARCHIVE_DIR/SHA256SUMS.txt"

MAX_DOWNLOAD_ATTEMPTS=15

mkdir -p "$ARCHIVE_DIR"

# ===========================
# Helper functions
# ===========================
fail() {
  local message="$1"
  local code="${2:-1}"
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - SCRIPT_START_TIME))
  echo "ERROR: $message"
  printf 'Elapsed time before failure: %02d:%02d:%02d\n' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60))
  exit "$code"
}

test_endpoint_reachable() {
  local uri="$1"
  if [[ "$uri" != https://* ]]; then
    echo "Endpoint must be https://"
    return 1
  fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -I "$uri" || true)
  if [[ -z "$code" || "$code" == "000" ]]; then
    echo "Endpoint unreachable"
    return 1
  fi
  echo "Reachable (HTTP $code)"
  return 0
}

human_to_bytes() {
  local val="$1" num unit
  [[ -z "$val" ]] && { echo 0; return; }
  num=$(echo "$val" | grep -oE '^[0-9.]+' || true)
  unit=$(echo "$val" | grep -oE '[a-zA-Z]+$' || true)
  [[ -z "$num" ]] && { echo 0; return; }
  case "$unit" in
    GB) awk "BEGIN{printf \"%.0f\", $num*1024*1024*1024}" ;;
    MB) awk "BEGIN{printf \"%.0f\", $num*1024*1024}" ;;
    kB) awk "BEGIN{printf \"%.0f\", $num*1024}" ;;
    B)  awk "BEGIN{printf \"%.0f\", $num}" ;;
    *)  echo 0 ;;
  esac
}

draw_bar() {
  local pct=$1 width=30
  (( pct > 100 )) && pct=100
  (( pct < 0 )) && pct=0
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar_str empty_str
  bar_str=$(printf '%*s' "$filled" '' | tr ' ' '#')
  empty_str=$(printf '%*s' "$empty" '' | tr ' ' '.')
  printf '[%s%s] %3d%%' "$bar_str" "$empty_str" "$pct"
}

# Expected file sizes (bytes) are only for the progress-bar estimate, based on
# past downloads observed in this environment - not exact API values. Purely
# cosmetic, does not affect correctness.
expected_size_for() {
  local fname="$1"
  case "$fname" in
    *contextual_translit*.tgz.encrypted) echo $((110*1024*1024)) ;;
    *translit*.tgz.encrypted)            echo $((812*1024*1024)) ;;
    *.tgz.encrypted)                     echo $((815*1024*1024)) ;;
    *) echo 0 ;;
  esac
}

# ===========================
# STEP 0: short-circuit if a valid package already exists
# ===========================
find_valid_package() {
  # Prints the newest package path whose sha256 matches SHA256SUMS.txt, or
  # nothing if none is valid. Also removes other stale/broken package files
  # once a valid one has been confirmed, so only one delivery file remains.
  [[ -f "$SHA_FILE" ]] || return 0
  local pkg best=""
  for pkg in $(ls -t "$ARCHIVE_DIR"/package-azure-ai-translator-container-*.tar.gz 2>/dev/null); do
    local name expected actual
    name="$(basename "$pkg")"
    expected="$(grep -F "  $name" "$SHA_FILE" | tail -1 | awk '{print $1}')"
    [[ -z "$expected" ]] && continue
    actual="$(sha256sum "$pkg" | awk '{print $1}')"
    if [[ "$expected" == "$actual" ]]; then
      best="$pkg"
      break
    fi
  done
  [[ -z "$best" ]] && return 0

  # Clean up any other package-*.tar.gz that isn't the confirmed-valid one.
  for pkg in "$ARCHIVE_DIR"/package-azure-ai-translator-container-*.tar.gz; do
    [[ -f "$pkg" && "$pkg" != "$best" ]] && rm -f "$pkg"
  done
  echo "$best"
}

if [[ "$FORCE" != "true" ]]; then
  EXISTING_PKG="$(find_valid_package || true)"
  if [[ -n "${EXISTING_PKG:-}" ]]; then
    HASH="$(grep -F "  $(basename "$EXISTING_PKG")" "$SHA_FILE" | tail -1 | awk '{print $1}')"
    echo ""
    echo "========================================"
    echo "ALREADY DONE - nothing to build"
    echo "========================================"
    echo "A valid delivery package already exists and its SHA256 matches"
    echo "$SHA_FILE, so there is nothing to (re)build."
    echo ""
    echo "  Package : $EXISTING_PKG"
    echo "  SHA256  : $HASH"
    echo ""
    echo "Deploy it using docs/Azure_translate_deploy-guide.md, or rerun with --force to"
    echo "rebuild from scratch."
    exit 0
  fi
fi

# ===========================
# Permission preflight (best effort)
# ===========================
# Files the container previously created while running as its default
# non-root UID (65532) cannot be chmod'd by a normal host user - only root
# can. This script pins the container to the host UID/GID for all NEW
# downloads (see STEP 3), so this class of problem cannot recur going
# forward; this preflight only warns about leftovers from older runs.
if [[ -d "$WORK_ROOT" ]]; then
  chmod -R u+rwX,go+rwX "$WORK_ROOT" 2>/dev/null || true
  STUCK="$(find "$WORK_ROOT" ! -writable -print -quit 2>/dev/null || true)"
  if [[ -n "$STUCK" ]]; then
    echo "WARN: found files not writable by the current user (leftover from an"
    echo "      older run that wrote as a different UID), e.g.: $STUCK"
    echo "      One-time fix: sudo chown -R \"\$(id -u):\$(id -g)\" \"$WORK_ROOT\""
  fi
fi

# ===========================
# Credentials
# ===========================
echo ""
echo "Please input Azure AI Translator settings:"

if [[ -z "${TRANSLATOR_KEY:-}" || -z "${TRANSLATOR_ENDPOINT_URI:-}" ]] && [[ -f "$ENV_PATH" ]]; then
  echo "INFO: found existing .env in $SCRIPT_DIR, reusing it"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_PATH"
  set +a
fi

if [[ -z "${TRANSLATOR_KEY:-}" ]]; then
  read -rsp "TRANSLATOR_KEY (will not be echoed): " TRANSLATOR_KEY
  echo ""
fi
if [[ -z "${TRANSLATOR_ENDPOINT_URI:-}" ]]; then
  read -rp "TRANSLATOR_ENDPOINT_URI (https://xxx.cognitiveservices.azure.com): " TRANSLATOR_ENDPOINT_URI
fi

[[ -z "$TRANSLATOR_KEY" ]] && fail "TRANSLATOR_KEY is empty"
[[ -z "$TRANSLATOR_ENDPOINT_URI" ]] && fail "TRANSLATOR_ENDPOINT_URI is empty"

echo ""
echo "====================="
echo "PREFLIGHT CHECK"
echo "====================="
if ! PRE_DETAIL=$(test_endpoint_reachable "$TRANSLATOR_ENDPOINT_URI"); then
  fail "Endpoint check failed: $PRE_DETAIL"
fi
echo "Endpoint check: $PRE_DETAIL"
echo "Key provided: OK"

cat > "$ENV_PATH" <<EOF
TRANSLATOR_KEY=${TRANSLATOR_KEY}
TRANSLATOR_ENDPOINT_URI=${TRANSLATOR_ENDPOINT_URI}
EOF
echo "INFO: .env ready for docker compose"

cleanup_env() { rm -f "$ENV_PATH" "$DOWNLOAD_COMPOSE_FILE"; }
trap cleanup_env EXIT

mkdir -p "$MODELS_DIR" "$LOGS_DIR" "$LICENSE_DIR" "$OUTPUT_DIR" "$HOTFIX_DIR"

# ===========================
# STEP 1: pull image (skip if already present)
# ===========================
echo ""
echo "====================="
echo "STEP 1: Pull container image"
echo "====================="
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "SKIP: image already present locally: $IMAGE"
else
  docker pull "$IMAGE" || fail "docker pull failed"
fi

CURRENT_IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}')"

# ===========================
# STEP 2: save image tar (skip if it already matches the loaded image)
# ===========================
echo ""
echo "====================="
echo "STEP 2: Save container image"
echo "====================="
if [[ -f "$IMAGE_TAR_PATH" && -f "$IMAGE_TAR_ID_PATH" ]] && \
   [[ "$(cat "$IMAGE_TAR_ID_PATH")" == "$CURRENT_IMAGE_ID" ]]; then
  echo "SKIP: $IMAGE_TAR_PATH already matches the current image ID"
else
  docker save -o "$IMAGE_TAR_NAME" "$IMAGE" || fail "docker save failed"
  mv -f "$IMAGE_TAR_NAME" "$IMAGE_TAR_PATH"
  echo "$CURRENT_IMAGE_ID" > "$IMAGE_TAR_ID_PATH"
fi

# ===========================
# STEP 3: download models & license (auto-retry on SAS expiry)
# ===========================
echo ""
echo "====================="
echo "STEP 3: Download models & license"
echo "====================="

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

cat > "$DOWNLOAD_COMPOSE_FILE" <<YAML
---
networks:
  adi-network:
    driver: bridge

services:
  azure-ai-translator:
    container_name: $CONTAINER_NAME
    image: $IMAGE
    restart: no
    user: "${HOST_UID}:${HOST_GID}"
    env_file: ".env"
    environment:
      EULA: accept
      apikey: \${TRANSLATOR_KEY}
      billing: \${TRANSLATOR_ENDPOINT_URI}
      Languages: zh-Hant,en
      MODEL_PATH: /usr/local/models
      GENERATEHOTFIXTEMPLATE: "false"
      DOWNLOADLICENSE: "true"
      Mounts:License: "/license"
      CATEGORIES: ""
      MODSENVIRONMENT: ""
      MODELS: ""
      TRANSLATORSYSTEMCONFIG: ""
      Mounts:Output: /logs
      MODELS_UPDATED: "true"
    volumes:
      - ./azure-ai-translator/models:/usr/local/models
      - ./azure-ai-translator/logs:/logs
      - ./azure-ai-translator/output:/output
      - ./azure-ai-translator/license:/license
    expose:
      - "5000"
    networks:
      - adi-network
YAML
echo "INFO: download compose generated (container pinned to host UID:GID $HOST_UID:$HOST_GID)"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

for (( attempt=1; attempt<=MAX_DOWNLOAD_ATTEMPTS; attempt++ )); do
  echo ""
  echo "--- Download attempt $attempt/$MAX_DOWNLOAD_ATTEMPTS ---"

  ATTEMPT_LOG="${COMPOSE_LOG}.attempt"
  : > "$ATTEMPT_LOG"

  docker compose -f "$DOWNLOAD_COMPOSE_FILE" up -d
  docker logs -f "$CONTAINER_NAME" >> "$ATTEMPT_LOG" 2>&1 &
  LOG_PID=$!

  PREV_RX_BYTES=0
  PREV_TIME=$(date +%s.%N)
  CUR_FILE=""
  FILE_START_RX=0

  while :; do
    RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
    [[ "$RUNNING" != "true" ]] && break

    LAST_FILE_LINE=$(grep -oE '(Downloading|Preparing) file: /usr/local/models/[^ ]+' "$ATTEMPT_LOG" 2>/dev/null | tail -1 || true)
    THIS_FILE=$(basename "${LAST_FILE_LINE##* }" 2>/dev/null || true)

    NET_IO=$(docker stats --no-stream --format '{{.NetIO}}' "$CONTAINER_NAME" 2>/dev/null || true)
    RX_HUMAN="${NET_IO%% / *}"
    RX_BYTES=$(human_to_bytes "$RX_HUMAN")

    NOW=$(date +%s.%N)
    DELTA_T=$(awk "BEGIN{print $NOW-$PREV_TIME}")
    DELTA_B=$(( RX_BYTES - PREV_RX_BYTES ))
    (( DELTA_B < 0 )) && DELTA_B=0
    RATE=$(awk "BEGIN{ if ($DELTA_T>0) printf \"%.2f\", ($DELTA_B/1024/1024)/$DELTA_T; else print \"0.00\" }")

    if [[ -n "$THIS_FILE" && "$THIS_FILE" != "$CUR_FILE" ]]; then
      CUR_FILE="$THIS_FILE"
      FILE_START_RX=$RX_BYTES
    fi

    FILE_DOWNLOADED=$(( RX_BYTES - FILE_START_RX ))
    (( FILE_DOWNLOADED < 0 )) && FILE_DOWNLOADED=0
    EXP=$(expected_size_for "$CUR_FILE")
    PCT=0
    [[ "$EXP" -gt 0 ]] && PCT=$(awk "BEGIN{p=($FILE_DOWNLOADED/$EXP)*100; if(p>100)p=100; if(p<0)p=0; printf \"%.0f\", p}")

    BAR=$(draw_bar "$PCT")
    TOTAL_MB=$(( RX_BYTES / 1024 / 1024 ))
    printf '\r%-55s %s  %6s MB/s  (received: %5d MB)   ' "${CUR_FILE:-waiting...}" "$BAR" "$RATE" "$TOTAL_MB"

    PREV_RX_BYTES=$RX_BYTES
    PREV_TIME=$NOW
    sleep 2
  done
  echo ""

  kill "$LOG_PID" 2>/dev/null || true
  wait "$LOG_PID" 2>/dev/null || true

  ATTEMPT_EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo 1)
  docker compose -f "$DOWNLOAD_COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true

  cat "$ATTEMPT_LOG" >> "$COMPOSE_LOG"

  # Exit code 0 = clean success. A non-zero exit that says "a valid license
  # has been found" is ALSO success: it means every model validated fine and
  # the only reason the container stopped is that DOWNLOADLICENSE=true
  # refused to re-fetch a license that is already present and valid.
  if [[ "$ATTEMPT_EXIT" -eq 0 ]] || grep -q 'a valid license has been found' "$ATTEMPT_LOG"; then
    rm -f "$ATTEMPT_LOG"
    echo "INFO: Download attempt $attempt completed successfully"
    break
  fi

  rm -f "$ATTEMPT_LOG"
  echo "WARN: Attempt $attempt exited with code $ATTEMPT_EXIT (likely SAS token expiry or transient network error)"
  if [[ $attempt -eq $MAX_DOWNLOAD_ATTEMPTS ]]; then
    echo "       Log tail (last 30 lines):"
    tail -n 30 "$COMPOSE_LOG"
    fail "docker compose failed after $MAX_DOWNLOAD_ATTEMPTS attempts. See log: $COMPOSE_LOG. Just rerun this script - already-downloaded files are kept."
  fi
  echo "       Retrying (already-downloaded files are only re-validated, not re-downloaded)..."
done

rm -f "$ENV_PATH"
echo "INFO: .env removed"

# ===========================
# Parse MODELS / TRANSLATORSYSTEMCONFIG from log
# ===========================
MODELS=$(grep -oP -- '-e MODELS=\K[^\s]+' "$COMPOSE_LOG" | tail -1 || true)
TRANSLATORSYSTEMCONFIG=$(grep -oP -- '-e TRANSLATORSYSTEMCONFIG=\K[^\s]+' "$COMPOSE_LOG" | tail -1 || true)

if [[ -z "$MODELS" || -z "$TRANSLATORSYSTEMCONFIG" ]]; then
  fail "Failed to parse MODELS / TRANSLATORSYSTEMCONFIG from compose log. Check: $COMPOSE_LOG"
fi

echo ""
echo "========================================"
echo "OFFLINE RUNTIME PARAMETERS"
echo "========================================"
echo "MODELS:"
echo "  $MODELS"
echo ""
echo "TRANSLATORSYSTEMCONFIG:"
echo "  $TRANSLATORSYSTEMCONFIG"
echo "========================================"

# ===========================
# STEP 4: package everything
# ===========================
echo ""
echo "====================="
echo "STEP 4: Package tar.gz"
echo "====================="

PKG_NAME="package-azure-ai-translator-container-${TIMESTAMP}.tar.gz"
PKG_PATH="$ARCHIVE_DIR/$PKG_NAME"

# The run-compose file is placed at the SAME directory level as
# azure-ai-translator/ (the package root), not inside archive/. docker
# compose resolves relative volume paths (./azure-ai-translator/...) against
# the directory the compose file itself lives in, so co-locating them here
# means the shipped package works with a plain
#   docker compose -f run-disconnected-container-docker-compose.yaml up -d
# with no --project-directory workaround needed.
STAGING="$SCRIPT_DIR/staging_${TIMESTAMP}"
mkdir -p "$STAGING/azure-ai-translator" "$STAGING/archive" "$STAGING/compose_config/dotnet_translate/TranslateFiles"

cp -r "$MODELS_DIR"  "$STAGING/azure-ai-translator/models"
cp -r "$LICENSE_DIR" "$STAGING/azure-ai-translator/license"
mkdir -p "$STAGING/azure-ai-translator/logs" "$STAGING/azure-ai-translator/output" "$STAGING/azure-ai-translator/hotfix"
chmod -R o+rwX "$STAGING/azure-ai-translator" "$STAGING/compose_config"

cp "$IMAGE_TAR_PATH" "$STAGING/archive/$IMAGE_TAR_NAME"
cp "$COMPOSE_LOG"    "$STAGING/archive/$(basename "$COMPOSE_LOG")"

cat > "$STAGING/$RUN_COMPOSE_NAME" <<EOF
---
networks:
  adi-network:
    driver: bridge

services:
  azure-ai-translator:
    container_name: azure-ai-translator
    image: $IMAGE
    restart: always
    environment:
      EULA: accept
      Languages: zh-Hant,en
      MODEL_PATH: /usr/local/models
      GENERATEHOTFIXTEMPLATE: "false"
      DOWNLOADLICENSE: "false"
      Mounts:License: "/license"
      MODELS: "$MODELS"
      TRANSLATORSYSTEMCONFIG: "$TRANSLATORSYSTEMCONFIG"
      Mounts:Output: /logs
      MODELS_UPDATED: "false"
      HotfixDataFolder: /user/local/customhotfix
      HotfixReloadInterval: "1"
      HotfixReloadEnabled: "true"
    volumes:
      - ./azure-ai-translator/models:/usr/local/models
      - ./azure-ai-translator/logs:/logs
      - ./azure-ai-translator/output:/output
      - ./azure-ai-translator/license:/license
      - ./azure-ai-translator/hotfix:/hotfix
      - ./compose_config/dotnet_translate/TranslateFiles:/user/local/customhotfix
    ports:
      - "5000:5000"
    networks:
      - adi-network
EOF

(cd "$STAGING" && tar -czf "$PKG_PATH" .)
rm -rf "$STAGING"

echo "Delivery package created:"
echo "  $PKG_PATH"

HASH=$(sha256sum "$PKG_PATH" | awk '{print $1}')

echo ""
echo "========================================"
echo "DELIVERY FILE HASH (SHA256)"
echo "========================================"
echo "File   : $PKG_PATH"
echo "SHA256 : $HASH"
echo "========================================"

echo "$HASH  $(basename "$PKG_PATH")" >> "$SHA_FILE"
echo "SHA256SUMS.txt updated: $SHA_FILE"

# Remove any older package files now that this run's package is the
# confirmed-good one, so only a single unambiguous delivery file remains.
for pkg in "$ARCHIVE_DIR"/package-azure-ai-translator-container-*.tar.gz; do
  [[ -f "$pkg" && "$pkg" != "$PKG_PATH" ]] && rm -f "$pkg"
done

echo ""
echo "Kept locally (for fast reruns / local testing):"
echo "  - docker image  : $IMAGE"
echo "  - models/license: $WORK_ROOT"
echo "  - image tar     : $IMAGE_TAR_PATH"

SCRIPT_END_TIME=$(date +%s)
ELAPSED=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
echo "========================================"
echo "Script finished at : $(date '+%Y-%m-%d %H:%M:%S')"
printf 'Elapsed time      : %02d:%02d:%02d\n' $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60))
echo "========================================"
