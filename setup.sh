#!/usr/bin/env bash
# cn-media — host setup on kaiser.lan. Idempotent: safe to re-run.
#
#   1. sanity check (hostname=kaiser)
#   2. fetch step-ca root CA → ./certs/
#   3. NFS sanity (refuse if /home/gonzalo/docker/data/nfs isn't mounted)
#   4. rsync legacy jellyfin config from ~/docker/docker-compose-nas/jellyfin/
#      (preserves user accounts, library DB, metadata cache, watch history)
#   5. clear <BaseUrl> in network.xml (legacy used /jellyfin path prefix;
#      we use subdomain routing, BaseUrl must be empty)
#   6. install /etc/systemd/system/docker-compose@cn-media.service + reload
#   7. enable + start the service
#   8. print status

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LEGACY_JELLYFIN="$HOME/docker/docker-compose-nas/jellyfin"
NFS_MOUNTPOINT="/home/gonzalo/docker/data/nfs"

if [ "$(hostname -s)" != "kaiser" ]; then
  echo "ERROR: must run on kaiser.lan (hostname is '$(hostname -s)')" >&2
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo (systemd install). You may be prompted."
fi

# ── 1. step-ca root CA ───────────────────────────────────────────────────
if [ ! -f "$REPO_DIR/certs/root_ca.crt" ]; then
  mkdir -p "$REPO_DIR/certs"
  echo "[1/7] fetching step-ca root CA"
  curl -sfo "$REPO_DIR/certs/root_ca.crt" http://pki.lan/cert/ca.crt
else
  echo "[1/7] step-ca root CA already in place"
fi

# ── 2. NFS sanity ────────────────────────────────────────────────────────
if ! mountpoint -q "$NFS_MOUNTPOINT"; then
  echo "ERROR: $NFS_MOUNTPOINT not mounted — cn-media needs the raidnas NFS share" >&2
  echo "       fix the mount first (see cn-bittorrent/setup.sh §1-2)" >&2
  exit 1
fi
echo "[2/7] NFS mounted: $(mount | grep raidnas | head -1)"

# ── 3. rsync legacy jellyfin config ──────────────────────────────────────
if [ -d "$LEGACY_JELLYFIN" ] && [ ! -d "$REPO_DIR/jellyfin" ]; then
  echo "[3/7] rsync'ing legacy jellyfin config ($(du -sh "$LEGACY_JELLYFIN" | cut -f1))"
  rsync -a "$LEGACY_JELLYFIN/" "$REPO_DIR/jellyfin/"
elif [ -d "$REPO_DIR/jellyfin" ]; then
  echo "[3/7] jellyfin/ already present, skipping rsync"
else
  echo "[3/7] no legacy jellyfin at $LEGACY_JELLYFIN — starting fresh (run setup wizard on first launch)"
fi

# ── 4. clear BaseUrl (legacy was /jellyfin path prefix; we use subdomains) ──
NETXML="$REPO_DIR/jellyfin/network.xml"
if [ -f "$NETXML" ]; then
  if grep -q '<BaseUrl>[^<]\+</BaseUrl>' "$NETXML"; then
    sudo sed -i 's|<BaseUrl>[^<]*</BaseUrl>|<BaseUrl></BaseUrl>|' "$NETXML"
    echo "[4/7] BaseUrl cleared in network.xml"
  else
    echo "[4/7] BaseUrl already empty"
  fi
fi

# ── 4b. neutralize legacy migrations.xml ──────────────────────────────────
# Pre-10.10 jellyfin tracked applied migrations in migrations.xml; 10.10+
# moved that into __EFMigrationsHistory in the SQLite DB. If the legacy
# file is present, 10.11's migration converter tries to map old GUIDs to
# new IDs, filters to known mappings, and crashes with
# "Sequence contains no elements" when none of them map (the legacy file
# only has 3-4 entries with GUIDs that have no direct 10.11 equivalent).
#
# Replace with an empty Applied list so the converter sees "nothing
# legacy to convert" and falls through to the normal startup path. The
# DB already has all 68 EF migrations applied (legacy was migrated
# forward to 10.11.x schema before the upgrade attempt that broke).
MIGXML="$REPO_DIR/jellyfin/migrations.xml"
if [ -f "$MIGXML" ] && grep -q '<ValueTupleOfGuidString>' "$MIGXML"; then
  echo "[4b/7] neutralizing legacy migrations.xml (preserves a backup)"
  cp -n "$MIGXML" "$MIGXML.legacy-backup" 2>/dev/null || true
  cat > "$MIGXML" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<MigrationOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Applied />
</MigrationOptions>
XML
else
  echo "[4b/7] migrations.xml already neutralized (or absent)"
fi

# ── 5. systemd unit ──────────────────────────────────────────────────────
UNIT_SRC="$REPO_DIR/systemd/docker-compose@cn-media.service"
UNIT_DST="/etc/systemd/system/docker-compose@cn-media.service"
if [ ! -f "$UNIT_DST" ] || ! sudo cmp -s "$UNIT_SRC" "$UNIT_DST"; then
  echo "[5/7] installing $UNIT_DST"
  sudo cp "$UNIT_SRC" "$UNIT_DST"
  sudo systemctl daemon-reload
else
  echo "[5/7] systemd unit already in place"
fi

# ── 6. enable + start ────────────────────────────────────────────────────
echo "[6/7] enabling + starting docker-compose@cn-media"
sudo systemctl enable --now docker-compose@cn-media.service

# ── 7. status ────────────────────────────────────────────────────────────
echo "[7/7] status:"
sudo systemctl status docker-compose@cn-media.service --no-pager -l | head -15
echo
docker compose -p cn-media ps

echo
echo "Done. Verify with the §13 drill in the plan."
