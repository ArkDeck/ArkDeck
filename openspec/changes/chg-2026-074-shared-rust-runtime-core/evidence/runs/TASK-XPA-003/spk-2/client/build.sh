#!/bin/sh
# Builds the SPK-2 client once and packages it as several signed variants.
# Usage: sh build.sh <spk2-root>
set -eu
ROOT="$1"
CLIENT="$ROOT/client"
BUILD="$ROOT/build"
ENT="$ROOT/entitlements"
DEVELOPER_ID="Developer ID Application: Hanfeng Fu (8AQTYW5FKR)"
APPLE_DEVELOPMENT="Apple Development: Hanfeng Fu (ZUP86546UG)"

mkdir -p "$BUILD"
xcrun swiftc -O -o "$BUILD/spk2-client" "$CLIENT/main.swift" -framework Security

# make_bundle <name> <bundle-id>
make_bundle() {
  app="$BUILD/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$BUILD/spk2-client" "$app/Contents/MacOS/spk2-client"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>spk2-client</string>
	<key>CFBundleIdentifier</key>
	<string>$2</string>
	<key>CFBundleName</key>
	<string>$1</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
EOF
}

# sign <bundle-name> <identity> <entitlements-file>
sign() {
  codesign --force --sign "$2" --entitlements "$3" --options runtime --timestamp=none \
    "$BUILD/$1.app"
  codesign --verify --strict "$BUILD/$1.app"
}

# A: production entitlements, Developer ID, the expected client identity.
make_bundle SPK2Client com.arkdeck.spk2-client
sign SPK2Client "$DEVELOPER_ID" "$ENT/ArkDeckApp.entitlements"

# B: same bytes and entitlements, ad-hoc signature (no Apple anchor). Its own
# identifier: a second signature under the identifier of A stalls at sandbox
# container initialisation before main (window 1), so each signed variant
# owns a distinct container and the listener's requirement names them all.
make_bundle SPK2ClientAdhoc com.arkdeck.spk2-adhoc
sign SPK2ClientAdhoc "-" "$ENT/ArkDeckApp.entitlements"

# C: Developer ID of the same team, a different identifier.
make_bundle SPK2Impostor com.arkdeck.spk2-impostor
sign SPK2Impostor "$DEVELOPER_ID" "$ENT/ArkDeckApp.entitlements"

# D: correct identity, sandbox on, but without the mach-lookup exception.
make_bundle SPK2ClientNoLookup com.arkdeck.spk2-nolookup
sign SPK2ClientNoLookup "$DEVELOPER_ID" "$ENT/no-mach-lookup.entitlements"

# E: correct identifier, Apple Development certificate of the same team.
make_bundle SPK2ClientDevCert com.arkdeck.spk2-devcert
sign SPK2ClientDevCert "$APPLE_DEVELOPMENT" "$ENT/ArkDeckApp.entitlements"

# F: a bare, unsandboxed, ad-hoc signed tool: what any local process can do.
cp "$BUILD/spk2-client" "$BUILD/spk2-bare"
codesign --force --sign - --identifier com.arkdeck.spk2-bare "$BUILD/spk2-bare"

for app in SPK2Client SPK2ClientAdhoc SPK2Impostor SPK2ClientNoLookup SPK2ClientDevCert; do
  echo "== $app"
  codesign -dv --verbose=2 "$BUILD/$app.app" 2>&1 | grep -E '^(Identifier|Authority=Developer|Authority=Apple Development|TeamIdentifier|Signature|CodeDirectory)' | sed 's/^/   /'
  codesign -d --entitlements - --xml "$BUILD/$app.app" 2>/dev/null | shasum -a 256 | sed 's/^/   entitlements-xml-sha256 /'
done
echo "== spk2-bare"
codesign -dv --verbose=2 "$BUILD/spk2-bare" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)' | sed 's/^/   /'
