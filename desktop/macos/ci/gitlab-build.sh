#!/usr/bin/env bash
# Builds a distributable, self-signed macOS .app + .zip for the Omi desktop app.
# Used by .gitlab-ci.yml on macOS runners (tags: macos, omi, xcode).
#
# Unlike run.sh (dev launcher), this script:
#   - builds in RELEASE configuration (smaller, faster binary)
#   - always creates a FRESH named bundle (never touches Omi / Omi Beta / Omi Dev)
#   - self-signs with a generated local identity (no Apple Developer cert needed);
#     the resulting bundle runs fine for testing but loses Screen Recording
#     permission on first launch -- grant it in System Settings after install.
#   - writes the artifacts to ./build-dist/ and (optionally) uploads them as
#     GitLab job artifacts for download from the pipeline page.
#
# Required env (CI provides these):
#   CI_BRANCH or GIT_REF   branch/ref being built (used in the bundle name)
# Optional env:
#   OMI_CI_APP_NAME         override app name (default: omi-ci-<branch-slug>)
#   OMI_CI_SKIP_ZIP=1       skip the .zip step
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"

cd "$MACOS_DIR"

# ─── Homebrew PATH (agent/launchd shells may not inherit it) ────────────────
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ─── Derive a unique named-bundle identity ──────────────────────────────────
BRANCH="${CI_COMMIT_REF_NAME:-${CI_BRANCH:-${GIT_REF:-$(git rev-parse --abbrev-ref HEAD)}}}"
SLUG="$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' | cut -c1-40)"
[ -n "$SLUG" ] || SLUG="manual"
APP_NAME="${OMI_CI_APP_NAME:-omi-ci-$SLUG}"
APP_SLUG="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
BUNDLE_ID="com.omi.$APP_SLUG"
URL_SCHEME="omi-$APP_SLUG"
BINARY_NAME="Omi Computer"

echo "==> Building $APP_NAME (bundle: $BUNDLE_ID, ref: $BRANCH @ $(git rev-parse --short HEAD))"

# ─── Toolchain checks ───────────────────────────────────────────────────────
command -v xcrun >/dev/null || { echo "ERROR: xcrun not found (need Xcode CLT)"; exit 1; }
command -v codesign >/dev/null || { echo "ERROR: codesign not found"; exit 1; }
command -v pkg-config >/dev/null || { echo "ERROR: pkg-config not found (brew install pkg-config)"; exit 1; }
pkg-config --exists libwebp || { echo "ERROR: libwebp not found (brew install webp)"; exit 1; }

# ─── Agent runtime (npm deps + dist + universal node) ──────────────────────
echo "==> Preparing agent runtime"
./scripts/prepare-agent-runtime.sh --universal-node

# ─── Tool surfaces ──────────────────────────────────────────────────────────
NODE_BIN=""
for candidate in \
    "Desktop/Sources/Resources/node" \
    "$(command -v node 2>/dev/null || true)" \
    "/opt/homebrew/opt/node@22/bin/node"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" --experimental-strip-types -e '0' >/dev/null 2>&1; then
        NODE_BIN="$candidate"
        break
    fi
done
[ -n "$NODE_BIN" ] || { echo "ERROR: Node 22.6+ required for tool surface generation"; exit 1; }
(cd agent && "$NODE_BIN" --experimental-strip-types scripts/generate-tool-surfaces.mjs)

# pi-mono-extension npm deps
(cd pi-mono-extension && npm ci --no-fund --no-audit)

# ─── Swift release build ────────────────────────────────────────────────────
echo "==> swift build -c release"
xcrun swift build -c release --package-path Desktop -Xswiftc -emit-const-values

SWIFTPM_RELEASE_DIR="Desktop/.build/release"
[ -f "$SWIFTPM_RELEASE_DIR/$BINARY_NAME" ] || { echo "ERROR: release binary missing at $SWIFTPM_RELEASE_DIR/$BINARY_NAME"; exit 1; }

# ─── Assemble bundle ────────────────────────────────────────────────────────
DIST_DIR="$MACOS_DIR/build-dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

echo "==> Assembling $APP_BUNDLE"
cp -f "$SWIFTPM_RELEASE_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

./scripts/embed-app-intents-metadata.sh Desktop "$APP_BUNDLE" Release "$(uname -m)"

# Info.plist with our identity
cp -f Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $URL_SCHEME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.0-ci" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-parse --short HEAD)" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Firebase config: dev variant (same based-hardware project, dev bundle id stamped in)
if [ -f "Desktop/Sources/GoogleService-Info-Dev.plist" ]; then
    cp -f Desktop/Sources/GoogleService-Info-Dev.plist "$APP_BUNDLE/Contents/Resources/GoogleService-Info.plist"
else
    cp -f Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/GoogleService-Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :BUNDLE_ID $BUNDLE_ID" "$APP_BUNDLE/Contents/Resources/GoogleService-Info.plist" 2>/dev/null || true

# Resource bundle (app assets)
RESOURCE_BUNDLE="$SWIFTPM_RELEASE_DIR/Omi Computer_Omi Computer.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# App icon
if [ -s omi_icon.icns ]; then
    cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns"
fi

# .env: point at the DEV serving plane (named bundles default to dev anyway,
# but pin it explicitly so the bundle is self-contained)
cat > "$APP_BUNDLE/Contents/Resources/.env" <<EOF
OMI_DESKTOP_API_URL=https://desktop-backend-dt5lrfkkoa-uc.a.run.app
OMI_PYTHON_API_URL=https://api.omiapi.com
EOF

# Frameworks: Sparkle + onnxruntime + libwebp
if [ -d "$SWIFTPM_RELEASE_DIR/Sparkle.framework" ]; then
    cp -R "$SWIFTPM_RELEASE_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
fi
if [ -d "$SWIFTPM_RELEASE_DIR/onnxruntime.framework" ]; then
    cp -R "$SWIFTPM_RELEASE_DIR/onnxruntime.framework" "$APP_BUNDLE/Contents/Frameworks/"
fi
WEBP_LIB="$(pkg-config --variable=libdir libwebp 2>/dev/null)/libwebp.7.dylib"
if [ -f "$WEBP_LIB" ]; then
    cp -f "$WEBP_LIB" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
    SHARPYUV_LIB="$(dirname "$WEBP_LIB")/libsharpyuv.0.dylib"
    [ -f "$SHARPYUV_LIB" ] && cp -f "$SHARPYUV_LIB" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
    install_name_tool -id "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib" 2>/dev/null || true
    if [ -f "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib" ]; then
        install_name_tool -id "@rpath/libsharpyuv.0.dylib" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib" 2>/dev/null || true
    fi
fi

# Agent runtime
AGENT_DIR="$MACOS_DIR/agent"
mkdir -p "$APP_BUNDLE/Contents/Resources/agent"
cp -R "$AGENT_DIR/dist" "$APP_BUNDLE/Contents/Resources/agent/dist"
cp -f "$AGENT_DIR/package.json" "$APP_BUNDLE/Contents/Resources/agent/"
if [ -d "$MACOS_DIR/.harness/agent-runtime/agent-node_modules" ]; then
    cp -R "$MACOS_DIR/.harness/agent-runtime/agent-node_modules" "$APP_BUNDLE/Contents/Resources/agent/node_modules"
fi

# pi-mono-extension
PI_MONO="$MACOS_DIR/pi-mono-extension"
mkdir -p "$APP_BUNDLE/Contents/Resources/pi-mono-extension"
cp -f "$PI_MONO/index.ts" "$PI_MONO/package.json" "$PI_MONO/package-lock.json" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/" 2>/dev/null || true
if [ -d "$PI_MONO/node_modules" ]; then
    cp -R "$PI_MONO/node_modules" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/node_modules"
fi

# ─── Normalize + sign ───────────────────────────────────────────────────────
./scripts/prepare-desktop-bundle-native-deps.sh "$APP_BUNDLE"
chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Self-signed local identity (teamless -> relax library validation, drop Sign in with Apple)
CI_SIGN_KEYCHAIN="$HOME/Library/Keychains/omi-ci-signing.keychain-db"
CI_SIGN_IDENTITY="Omi CI Local Signing"
ensure_ci_signing_identity() {
    if security find-certificate -c "$CI_SIGN_IDENTITY" "$CI_SIGN_KEYCHAIN" >/dev/null 2>&1; then
        return 0
    fi
    local work
    work="$(mktemp -d)"
    cat > "$work/ci-sign.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Omi CI Local Signing
O = Omi CI
[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CNF
    security delete-keychain "$CI_SIGN_KEYCHAIN" 2>/dev/null || true
    security create-keychain -p "omi-ci" "$CI_SIGN_KEYCHAIN"
    security set-keychain-settings -t 3600 -l "$CI_SIGN_KEYCHAIN"
    security unlock-keychain -p "omi-ci" "$CI_SIGN_KEYCHAIN"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "omi-ci" "$CI_SIGN_KEYCHAIN" 2>/dev/null || true
    openssl req -new -x509 -keyout "$work/key.pem" -out "$work/cert.pem" \
        -days 3650 -config "$work/ci-sign.cnf" -nodes 2>/dev/null
    security import "$work/cert.pem" -k "$CI_SIGN_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security -P "" 2>/dev/null || \
        security import "$work/cert.pem" -k "$CI_SIGN_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null
    security import "$work/key.pem" -k "$CI_SIGN_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security -P "" 2>/dev/null || \
        security import "$work/key.pem" -k "$CI_SIGN_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null
    rm -rf "$work"
}
ensure_ci_signing_identity

# Teamless identity: entitlements without Sign-in-with-Apple + library validation off
ENTITLEMENTS="$DIST_DIR/ci.entitlements"
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.automation.apple-events</key><true/>
    <key>com.apple.security.get-task-allow</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.screen-capture</key><true/>
    <key>com.apple.security.personal-information.calendars</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing nested frameworks"
for fw in Sparkle.framework onnxruntime.framework; do
    [ -d "$APP_BUNDLE/Contents/Frameworks/$fw" ] && \
        codesign --force --options runtime --sign "$CI_SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/$fw"
done
for dy in libwebp.7.dylib libsharpyuv.0.dylib; do
    [ -f "$APP_BUNDLE/Contents/Frameworks/$dy" ] && \
        codesign --force --options runtime --sign "$CI_SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/$dy"
done
NODE_BUNDLED="$APP_BUNDLE/Contents/Resources/Omi Computer_Omi Computer.bundle/Contents/Resources/node"
if [ -f "$NODE_BUNDLED" ]; then
    codesign --force --options runtime --entitlements Desktop/Node.entitlements --sign "$CI_SIGN_IDENTITY" "$NODE_BUNDLED"
fi

echo "==> Signing app bundle (self-signed: $CI_SIGN_IDENTITY)"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$CI_SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || { echo "ERROR: codesign verify failed"; exit 1; }

chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "==> Bundle audit"
./scripts/audit-desktop-bundle-deps.sh "$APP_BUNDLE" || echo "WARN: bundle dep audit reported issues (non-fatal for CI)"

# ─── Zip artifact ───────────────────────────────────────────────────────────
if [ "${OMI_CI_SKIP_ZIP:-0}" != "1" ]; then
    echo "==> Creating zip"
    (cd "$DIST_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip")
fi

echo "==> Done. Artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR"
echo ""
echo "Install with:  sudo cp -R \"$DIST_DIR/$APP_NAME.app\" /Applications/"
echo "(Self-signed: first launch needs Screen Recording + Microphone grants in System Settings.)"
