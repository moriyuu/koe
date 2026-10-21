#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=~/Applications/Koe.app
RESTART=false
[[ "${1:-}" == "--restart" ]] && RESTART=true

$RESTART && { pkill -x Koe || true; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O main.swift -o "$APP/Contents/MacOS/Koe"
# 同じ証明書で署名し続けると、再ビルドしてもアクセシビリティの許可が消えない
IDENTITY="${KOE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)}"
if [[ -z "$IDENTITY" ]]; then
  echo "署名用の証明書がないのでアドホック署名します（再ビルドのたびにアクセシビリティの許可がやり直しになります）"
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "built: $APP"
if $RESTART; then open "$APP"; fi
