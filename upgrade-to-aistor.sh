#!/usr/bin/env bash
# Upgrade an existing Linux/bare-metal MinIO cluster to MinIO AIStor.
#
# Run the phases in this order:
#   1. backup                  (once, as the user who already has the mc alias)
#   2. install-binary           (once on every MinIO node; this does not restart)
#   3. restart-and-license      (once, as the user who already has the mc alias)
#
# The upgrade is permanent. This script intentionally requires
# --confirm-permanent on every invocation that changes the cluster.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "==> $*"; }
usage() {
  cat <<'EOF'
Usage:
  ./upgrade-to-aistor.sh backup --confirm-permanent
  sudo ./upgrade-to-aistor.sh install-binary --confirm-permanent
  ./upgrade-to-aistor.sh restart-and-license --confirm-permanent

Configuration is read from environment variables or --config FILE. The script
uses an existing local mc alias; see upgrade.env.example.
EOF
}

PHASE="${1:-}"
[[ -n "$PHASE" && "$PHASE" != "-h" && "$PHASE" != "--help" ]] || { usage; exit 0; }
shift
CONFIG_FILE=""
CONFIRMED=false
while (($#)); do
  case "$1" in
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    --confirm-permanent) CONFIRMED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -z "$CONFIG_FILE" ]] || { [[ -r "$CONFIG_FILE" ]] || die "Cannot read config: $CONFIG_FILE"; # shellcheck disable=SC1090
  source "$CONFIG_FILE"; }

# Non-secret defaults. Environment/config values override these.
: "${MINIO_SERVICE_NAME:=minio}"
: "${MINIO_BINARY_PATH:=/usr/local/bin/minio}"
: "${AISTOR_ARCH:=}"
: "${AISTOR_BINARY_URL:=}"
: "${AISTOR_BINARY_FILE:=}"
: "${AISTOR_BACKUP_DIR:=}"
: "${MC_ALIAS:=}"
: "${AISTOR_LICENSE_FILE:=}"

require_confirmation() {
  [[ "$CONFIRMED" == true ]] || die "This migration is permanent. Re-run with --confirm-permanent after reviewing backups and the maintenance window."
}
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_root() { [[ $EUID -eq 0 ]] || die "This phase must run as root (use sudo)."; }
require_mc_alias() {
  require_command mc
  [[ -n "$MC_ALIAS" ]] || die "Set MC_ALIAS to an alias already configured for the current user."
  mc alias list "$MC_ALIAS" >/dev/null 2>&1 || die "mc alias '$MC_ALIAS' is not configured for user $(id -un). Run this phase as the user who owns that alias."
}
check_service_and_binary() {
  require_command systemctl
  [[ -x "$MINIO_BINARY_PATH" ]] || die "MinIO binary is not executable: $MINIO_BINARY_PATH"
  systemctl is-active --quiet "$MINIO_SERVICE_NAME" || die "Service is not active: $MINIO_SERVICE_NAME"
}
resolve_download_url() {
  if [[ -n "$AISTOR_BINARY_FILE" ]]; then
    [[ -r "$AISTOR_BINARY_FILE" ]] || die "Cannot read AISTOR_BINARY_FILE: $AISTOR_BINARY_FILE"
    printf '%s\n' "$AISTOR_BINARY_FILE"
    return
  fi
  if [[ -z "$AISTOR_ARCH" ]]; then
    case "$(uname -m)" in
      x86_64) AISTOR_ARCH=linux-amd64 ;;
      aarch64|arm64) AISTOR_ARCH=linux-arm64 ;;
      *) die "Unsupported CPU architecture $(uname -m); set AISTOR_ARCH explicitly." ;;
    esac
  fi
  if [[ -z "$AISTOR_BINARY_URL" ]]; then
    AISTOR_BINARY_URL="https://dl.min.io/aistor/minio/release/${AISTOR_ARCH}/minio"
  fi
  printf '%s\n' "$AISTOR_BINARY_URL"
}

case "$PHASE" in
  backup)
    require_confirmation
    require_mc_alias
    require_command date
    : "${AISTOR_BACKUP_DIR:=./aistor-upgrade-backup-$(date -u +%Y%m%dT%H%M%SZ)}"
    [[ ! -e "$AISTOR_BACKUP_DIR" ]] || die "Backup directory already exists: $AISTOR_BACKUP_DIR"
    BACKUP_PARENT="$(dirname "$AISTOR_BACKUP_DIR")"
    # Create only the directory path that will hold script-generated backups.
    # License, binary, and configuration paths are inputs and must already exist.
    mkdir -p -- "$BACKUP_PARENT" || die "Cannot create backup parent directory: $BACKUP_PARENT"
    install -d -m 0700 "$AISTOR_BACKUP_DIR"
    info "Confirming cluster access"
    mc admin info "$MC_ALIAS" >"$AISTOR_BACKUP_DIR/pre-upgrade-cluster-info.txt"
    info "Exporting cluster configuration, bucket metadata, and IAM metadata"
    mc admin config export "$MC_ALIAS" >"$AISTOR_BACKUP_DIR/minio-config-export.txt"
    (cd "$AISTOR_BACKUP_DIR" && mc admin cluster bucket export "$MC_ALIAS")
    mc admin cluster iam export "$MC_ALIAS" --output "$AISTOR_BACKUP_DIR/${MC_ALIAS}-iam-info.zip"
    find "$AISTOR_BACKUP_DIR" -maxdepth 1 -type f -print | sort
    info "Backup complete. Copy this directory to durable secure storage before installing binaries: $AISTOR_BACKUP_DIR"
    ;;

  install-binary)
    require_confirmation
    require_root
    require_command install
    check_service_and_binary
    SOURCE="$(resolve_download_url)"
    TEMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TEMP_DIR"' EXIT
    NEW_BINARY="$TEMP_DIR/minio"
    if [[ -r "$SOURCE" ]]; then
      cp "$SOURCE" "$NEW_BINARY"
    else
      require_command curl
      info "Downloading AIStor binary for $(uname -m)"
      curl --fail --show-error --location --retry 10 --progress-bar "$SOURCE" --output "$NEW_BINARY"
    fi
    chmod 0755 "$NEW_BINARY"
    "$NEW_BINARY" --version >/dev/null || die "Downloaded file is not an executable MinIO/AIStor binary."
    BACKUP_BINARY="${MINIO_BINARY_PATH}.pre-aistor.$(date -u +%Y%m%dT%H%M%SZ)"
    cp --preserve=mode,ownership,timestamps "$MINIO_BINARY_PATH" "$BACKUP_BINARY"
    install -o root -g root -m 0755 "$NEW_BINARY" "$MINIO_BINARY_PATH"
    info "Installed new binary. Previous binary saved at: $BACKUP_BINARY"
    "$MINIO_BINARY_PATH" --version
    info "Do NOT restart this node manually. Repeat install-binary on every node, then run restart-and-license once."
    ;;

  restart-and-license)
    require_confirmation
    require_mc_alias
    [[ -r "$AISTOR_LICENSE_FILE" ]] || die "Set AISTOR_LICENSE_FILE to a readable AIStor license file."
    info "Restarting the entire cluster simultaneously via mc"
    mc admin service restart "$MC_ALIAS"
    info "Waiting for cluster API to return"
    for _ in $(seq 1 30); do
      if mc admin info "$MC_ALIAS" >/dev/null 2>&1; then break; fi
      sleep 5
    done
    mc admin info "$MC_ALIAS" || die "Cluster did not become healthy within 150 seconds; inspect journalctl -u $MINIO_SERVICE_NAME on each node."
    info "Registering AIStor license (stored in and replicated by the object store)"
    mc license register "$MC_ALIAS" --license "$AISTOR_LICENSE_FILE"
    mc admin info "$MC_ALIAS"
    info "Upgrade complete. Keep the metadata backups and pre-AIStor binaries until post-upgrade validation is complete."
    ;;

  *) usage; die "Unknown phase: $PHASE" ;;
esac
