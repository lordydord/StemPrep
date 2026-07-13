#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="StemPrep"
SOURCE_APP="$ROOT_DIR/dist/$APP_NAME.app"
TARGET_APP="/Applications/$APP_NAME.app"

cd "$ROOT_DIR"

"$ROOT_DIR/script/build_and_run.sh" --bundle
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ -d "$TARGET_APP" ]]; then
  BACKUP_APP="/tmp/$APP_NAME.app.previous.$(date +%Y%m%d%H%M%S)"
  mv "$TARGET_APP" "$BACKUP_APP"
fi

/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/xattr -cr "$TARGET_APP"
/usr/bin/codesign --force --deep --sign - "$TARGET_APP"

echo "Installed $TARGET_APP"
