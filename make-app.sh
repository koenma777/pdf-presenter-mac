#!/bin/bash
# PDFPresenter.app をビルド・配置するスクリプト
#   既定の出力先: ~/Applications/PDFPresenter.app
#   試しに別の場所へ作るとき: PDFPRESENTER_APP_PATH=/path/to/PDFPresenter.app ./make-app.sh
#   Apple シリコンと Intel の両方で動く版（ユニバーサル）にするとき: PDFPRESENTER_UNIVERSAL=1
set -euo pipefail

# アプリのバージョン（Info.plist の CFBundleVersion / CFBundleShortVersionString に入る。配布用 zip の名前にも使われる）
APP_VERSION="1.0"

# 出力先を決める（相対パスは実行した場所から見たパスとして扱うので、cd より前に解決する）
if [[ -n "${PDFPRESENTER_APP_PATH+set}" ]]; then
    if [[ -z "$PDFPRESENTER_APP_PATH" ]]; then
        # 空のまま既定（本番の ~/Applications）に落ちないよう止める
        echo "✖ PDFPRESENTER_APP_PATH が空です" >&2
        exit 1
    fi
    APP="$PDFPRESENTER_APP_PATH"
    [[ "$APP" == /* ]] || APP="$PWD/$APP"
else
    APP="$HOME/Applications/PDFPresenter.app"
fi
APP="${APP%/}"
# 出力先は rm -rf してから作り直すので、.app で終わらないパスは受け付けない（安全弁）
if [[ "$APP" != *.app ]] || [[ "$(basename "$APP")" == ".app" ]]; then
    echo "✖ 出力先は .app で終わるパスにしてください: $APP" >&2
    exit 1
fi

cd "$(dirname "$0")"

ICON_SOURCE="Resources/AppIcon.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "✖ アイコンの元画像がありません: $ICON_SOURCE" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 実行ファイルは種類ごとの出力先（--show-bin-path）から取る。
# .build/release は最後にビルドした種類を指すので、ユニバーサルを作った後に別の種類を拾わないようにするため
BINARY="$WORK_DIR/PDFPresenter"
if [[ "${PDFPRESENTER_UNIVERSAL:-}" == "1" ]]; then
    echo "▸ リリースビルド中（ユニバーサル: x86_64 + arm64）..."
    swift build -c release --triple x86_64-apple-macosx14.0
    swift build -c release --triple arm64-apple-macosx14.0
    X86_BIN="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/PDFPresenter"
    ARM_BIN="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/PDFPresenter"
    lipo -create "$X86_BIN" "$ARM_BIN" -output "$BINARY"
    echo "  種類: $(lipo -archs "$BINARY")"
else
    echo "▸ リリースビルド中..."
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/PDFPresenter" "$BINARY"
fi

# アイコン（.icns）は既存の .app を消す前に作っておく（変換に失敗しても今のアプリを壊さない）
echo "▸ アイコンを作成中..."
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK_DIR/AppIcon.icns"

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/PDFPresenter"
cp "$WORK_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PDF Presenter</string>
    <key>CFBundleDisplayName</key>
    <string>PDF Presenter</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.koenma777.PDFPresenter</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>PDFPresenter</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>スマホからページ送りの操作を受け付けるために使います</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 koenma777</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# ad-hoc署名（ローカル実行用）
codesign --force --sign - "$APP"

# Finder や Dock がアイコンを読み直しやすいよう更新日時を進める
touch "$APP"

echo "✅ 完成: $APP"
