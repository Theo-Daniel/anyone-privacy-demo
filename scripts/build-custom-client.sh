#!/usr/bin/env bash
# Rebuild the customized zkAPI client and cover runner from pinned public source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="32b97d19c6ceb2c2c1b5ef99a9ecac2266467255"
UPSTREAM="https://github.com/ethereum/zkapi.git"
BUILD_ROOT="$ROOT/.cache/zkapi-source-build"
SOURCE="$BUILD_ROOT/upstream"

command -v git >/dev/null || { echo 'git required' >&2; exit 1; }
command -v go >/dev/null || { echo 'Go required' >&2; exit 1; }
mkdir -p "$BUILD_ROOT" "$ROOT/tools"

# Remove only the script's own disposable build checkout, not project data.
if [[ -d "$SOURCE" ]]; then
  printf 'Build checkout already exists: %s\n' "$SOURCE" >&2
  printf 'Remove it yourself to rebuild from a fresh checkout.\n' >&2
  exit 1
fi

git clone --filter=blob:none "$UPSTREAM" "$SOURCE"
git -C "$SOURCE" checkout --detach "$COMMIT"
git -C "$SOURCE" apply "$ROOT/patches/zkapi-mainnet-isolation.patch"

DEST="$SOURCE/zkapi-clientd"
mkdir -p "$DEST/internal/cover" "$DEST/cmd/anyone-cover-demo"
cp "$ROOT/zkapi-additions/internal/relay/tor.go" "$DEST/internal/relay/tor.go"
cp "$ROOT/zkapi-additions/internal/server/anyone_isolation_test.go" "$DEST/internal/server/anyone_isolation_test.go"
cp "$ROOT/zkapi-additions/internal/cover/"*.go "$DEST/internal/cover/"
cp "$ROOT/zkapi-additions/cmd/anyone-cover-demo/main.go" "$DEST/cmd/anyone-cover-demo/main.go"

(
  cd "$DEST"
  go test ./internal/cover ./internal/relay ./internal/server ./cmd/anyone-cover-demo -count=1
  go build -o "$ROOT/tools/zkapi-clientd-isolated-test" ./cmd/zkapi-clientd
  go build -o "$ROOT/tools/anyone-cover-demo" ./cmd/anyone-cover-demo
)
printf '\nBuild complete. Binaries are in tools/.\n'
