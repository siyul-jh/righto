#!/bin/bash
# 로컬 ad-hoc 서명 빌드 → ~/Applications/Righto.app
set -euo pipefail
cd "$(dirname "$0")"
APP=${APP:-~/Applications/Righto.app}; V=$(cat VERSION); EXT="$APP/Contents/PlugIns/FinderMenu.appex"
ID=local.righto
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
cp icons/Righto.icns "$APP/Contents/Resources/"
cp icons/menu/rename.png icons/menu/goto.png "$APP/Contents/Resources/"  # 이름 변경·폴더 이동 창 아이콘
swiftc -O -o "$APP/Contents/MacOS/Righto" Host.swift Config.swift Tools.swift
swiftc -O -module-name FinderMenu -application-extension -o "$EXT/Contents/MacOS/FinderMenu" FinderMenu.swift Config.swift \
  -framework FinderSync -framework Cocoa -Xlinker -e -Xlinker _NSExtensionMain
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string><key>CFBundleName</key><string>Righto</string>
<key>CFBundleExecutable</key><string>Righto</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string><key>CFBundleVersion</key><string>$V</string>
<key>CFBundleIconFile</key><string>Righto</string><key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>폴더로 이동할 때 새 창 대신 지금 Finder 창의 경로를 바꿉니다.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Righto</string><key>CFBundleURLSchemes</key><array><string>righto</string></array></dict></array>
</dict></plist>
P
cat > "$EXT/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID.finder</string><key>CFBundleName</key><string>FinderMenu</string>
<key>CFBundleDisplayName</key><string>Righto</string>
<key>CFBundleExecutable</key><string>FinderMenu</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$V</string><key>CFBundleVersion</key><string>$V</string>
<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
<key>NSExtensionPrincipalClass</key><string>FinderMenu.FinderMenu</string></dict></dict></plist>
P
mkdir -p "$EXT/Contents/Resources" && cp icons/menu/*.png "$EXT/Contents/Resources/"
# ad-hoc 서명은 빌드마다 서명이 바뀌어 macOS 가 권한(자동화·손쉬운 사용)을 매번 다시 묻는다.
# 로컬에서는 로그인 키체인의 자체 서명 인증서로 서명해 권한을 유지한다. 처음 한 번 만들고, CI 는 ad-hoc 그대로.
SIGN=-
if [ -z "${CI:-}" ]; then
  SIGN="Righto Local"
  if ! security find-identity -p codesigning | grep -q "\"$SIGN\""; then
    T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$SIGN" > "$T/c.cnf"
    # 시스템 LibreSSL 을 쓴다. Homebrew OpenSSL 3+ 의 p12 는 키체인이 읽지 못한다.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/k.pem" -out "$T/c.pem" -config "$T/c.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:righto
    security import "$T/c.p12" -k ~/Library/Keychains/login.keychain-db -P righto -T /usr/bin/codesign
  fi
fi
codesign -f -s "$SIGN" --entitlements ext.entitlements "$EXT"
codesign -f -s "$SIGN" "$APP"
[ -z "${BUILD_ONLY:-}" ] || exit 0  # dmg.sh 는 빌드만 하고 설치·등록은 건너뜀
open "$APP" --args --register; sleep 1
pluginkit -a "$EXT"; pluginkit -e use -i $ID.finder
killall Finder
pluginkit -m -i $ID.finder -v
