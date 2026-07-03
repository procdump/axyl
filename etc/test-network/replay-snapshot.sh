#!/usr/bin/env bash
# Replay a real testnet snapshot into local-validators/ (4 validators).
# See doc/testnet-replay.md.
set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <setup.tar.gz> <latest.tar.zst> [--yes]

Pass --yes to skip the wipe confirmation.
After: ./etc/test-network/local-testnet.sh --start
EOF
  exit 2
}

[[ $# -ge 2 ]] || usage
SETUP=$1
SNAP=$2
AUTO_YES=0
[[ "${3:-}" == "--yes" ]] && AUTO_YES=1

[[ -f "$SETUP" ]] || { echo "setup tarball not found: $SETUP" >&2; exit 1; }
[[ -f "$SNAP"  ]] || { echo "snapshot not found: $SNAP" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
TESTNET="$REPO/etc/test-network"
DST="$TESTNET/local-validators"
ENV_FILE="$TESTNET/.env"
STAGE=/tmp/rayls-snapshot
trap 'rm -rf "$STAGE"' EXIT

if [[ "$(uname -s)" == "Darwin" ]]; then
  CP_CLONE=(cp -c -R)
else
  CP_CLONE=(cp --reflink=auto -R)
fi

if [[ -d "$DST" ]]; then
  if [[ $AUTO_YES -eq 0 ]]; then
    read -r -p "About to delete $DST. Continue? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || { echo "aborted"; exit 0; }
  fi
  rm -rf "$DST"
fi

echo "==> extracting setup tarball"
tar -xzf "$SETUP" -C "$TESTNET/"
[[ -d "$DST/validator-1" ]] || {
  echo "setup tarball did not produce $DST/validator-1 — wrong archive?" >&2
  exit 1
}

echo "==> extracting chain snapshot to $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"
zstd -dc "$SNAP" | tar -x -C "$STAGE"

echo "==> fixing flat MDBX layout"
cd "$STAGE"
mkdir -p consensus-db db
[[ -f consensus-db_mdbx.dat ]] && mv consensus-db_mdbx.dat consensus-db/mdbx.dat
[[ -f db_mdbx.dat ]]           && mv db_mdbx.dat           db/mdbx.dat

echo "==> placing chain state under validator-1"
for D in blobstore consensus-db db rocksdb static_files; do
  [[ -e "$STAGE/$D" ]] || {
    echo "error: $STAGE/$D missing from snapshot — refusing to produce a broken setup" >&2
    exit 1
  }
  mv "$STAGE/$D" "$DST/validator-1/"
done

echo "==> cloning to validators 2-4 (${CP_CLONE[*]})"
for V in 2 3 4; do
  for D in blobstore consensus-db db rocksdb static_files; do
    "${CP_CLONE[@]}" "$DST/validator-1/$D" "$DST/validator-$V/"
  done
done

echo "==> patching $ENV_FILE (NUM_VALIDATORS=4, NUM_OBSERVERS=0)"
sed -i.bak \
  -e 's/^NUM_VALIDATORS=.*/NUM_VALIDATORS=4/' \
  -e 's/^NUM_OBSERVERS=.*/NUM_OBSERVERS=0/' \
  "$ENV_FILE"
rm -f "$ENV_FILE.bak"

cat <<EOF

Done. Launch with:
  ./etc/test-network/local-testnet.sh --start
EOF
