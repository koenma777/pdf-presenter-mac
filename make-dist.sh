#!/bin/bash
# 配布用の zip（アプリ＋受け取る人向けの手順書）を output/dist/ に作るスクリプト
#
#   ./make-dist.sh
#
# できるもの:
#   output/dist/PDF Presenter <バージョン>/PDFPresenter.app
#   output/dist/PDF Presenter <バージョン>/はじめにお読みください.html
#   output/dist/PDFPresenter-<バージョン>.zip   （上のフォルダを固めたもの）
#
# ~/Applications には触らない（アプリは一時フォルダに作ってからコピーする）。
set -euo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
DIST="$REPO/output/dist"
GUIDE_SOURCE="$REPO/docs/guide/guide.html"
GUIDE_NAME="はじめにお読みください.html"

fail() {
    echo "✖ $*" >&2
    exit 1
}

[[ -f "$GUIDE_SOURCE" ]] || fail "手順書の元データがありません: $GUIDE_SOURCE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. アプリを組み立てる（組み立ての処理は make-app.sh だけに持たせる）
BUILT_APP="$WORK/build/PDFPresenter.app"
PDFPRESENTER_APP_PATH="$BUILT_APP" PDFPRESENTER_UNIVERSAL=1 ./make-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || fail "バージョンの形が想定外です: $VERSION"

FOLDER_NAME="PDF Presenter $VERSION"
ZIP_NAME="PDFPresenter-$VERSION.zip"
FOLDER="$DIST/$FOLDER_NAME"
ZIP="$DIST/$ZIP_NAME"

# 2. 前回の出力（このフォルダと zip の2つだけ）を消す。output/dist/ の直下以外は消さない（安全弁）
remove_previous() {
    local target="$1"
    [[ "$(dirname "$target")" == "$DIST" ]] || fail "output/dist/ の直下ではないので消しません: $target"
    [[ -n "$(basename "$target")" && "$(basename "$target")" != "." && "$(basename "$target")" != ".." ]] \
        || fail "消す対象の名前が不正です: $target"
    rm -rf "$target"
}
mkdir -p "$DIST"
remove_previous "$FOLDER"
remove_previous "$ZIP"

# 3. 手順書：images/ の画像を data URI に埋め込んで1ファイルにする
embed_images() {
    local source="$1" output="$2" base line rel path mime data
    base="$(dirname "$source")"
    : > "$output"
    while IFS= read -r line || [[ -n "$line" ]]; do
        while [[ "$line" =~ src=\"(images/[^\"]+)\" ]]; do
            rel="${BASH_REMATCH[1]}"
            path="$base/$rel"
            [[ -f "$path" ]] || fail "手順書の画像がありません: $path"
            case "$rel" in
                *.png) mime="image/png" ;;
                *.jpg | *.jpeg) mime="image/jpeg" ;;
                *) fail "手順書の画像の形式が想定外です: $rel" ;;
            esac
            data="$(base64 -i "$path" | tr -d '\n')"
            line="${line/src=\"$rel\"/src=\"data:$mime;base64,$data\"}"
        done
        printf '%s\n' "$line" >> "$output"
    done < "$source"
}

echo "▸ 配布用フォルダを作成中..."
mkdir -p "$FOLDER"
ditto "$BUILT_APP" "$FOLDER/PDFPresenter.app"
embed_images "$GUIDE_SOURCE" "$FOLDER/$GUIDE_NAME"

echo "▸ zip を作成中..."
# 拡張属性やリソースフォークは入れない（--norsrc --noextattr --noacl）。
# 入れると zip に「._」の隠しファイルができ、Mac標準以外の方法で解凍したときにそれがアプリの中に
# 実体として出てきて署名が壊れる（受け取った人の Mac で「壊れているため開けません」になる）
(cd "$DIST" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$FOLDER_NAME" "$ZIP_NAME")

# 4. zip を一時フォルダに展開し直して確かめる
echo "▸ zip の中身を確認中..."
CHECK="$WORK/check"
mkdir -p "$CHECK"
ditto -x -k "$ZIP" "$CHECK"
CHECK_APP="$CHECK/$FOLDER_NAME/PDFPresenter.app"
CHECK_GUIDE="$CHECK/$FOLDER_NAME/$GUIDE_NAME"

[[ -d "$CHECK_APP" ]] || fail "zip の中にアプリがありません"
codesign --verify --deep --strict "$CHECK_APP" || fail "zip の中のアプリの署名を確認できません"
ARCHS="$(lipo -archs "$CHECK_APP/Contents/MacOS/PDFPresenter")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || fail "arm64 と x86_64 の両方が入っていません: $ARCHS"
CHECK_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CHECK_APP/Contents/Info.plist")"
[[ "$CHECK_VERSION" == "$VERSION" ]] || fail "zip の中のバージョンが違います: $CHECK_VERSION"
[[ -s "$CHECK_GUIDE" ]] || fail "zip の中に手順書がありません"
if grep -q 'src="images/' "$CHECK_GUIDE"; then fail "手順書に埋め込まれていない画像があります"; fi
if grep -Eq '(src|href)="(https?:)?//' "$CHECK_GUIDE"; then fail "手順書が外部のリソースを読み込んでいます"; fi

# zip に「._」や __MACOSX の隠しファイルが入っていないこと
if unzip -Z1 "$ZIP" | grep -Eq '(^|/)(\._|__MACOSX)'; then fail "zip に隠しファイル（._ / __MACOSX）が入っています"; fi
# Mac標準以外の方法（unzip コマンド）で解凍しても署名が壊れないこと
PLAIN="$WORK/plain-unzip"
mkdir -p "$PLAIN"
(cd "$PLAIN" && unzip -q "$ZIP")
codesign --verify --deep --strict "$PLAIN/$FOLDER_NAME/PDFPresenter.app" \
    || fail "unzip コマンドで解凍したアプリの署名を確認できません"

# 5. 結果
SIZE_BYTES="$(stat -f %z "$ZIP")"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo ""
echo "✅ 配布用 zip ができました"
echo "  場所:     $ZIP"
echo "  大きさ:   $(du -h "$ZIP" | cut -f1 | tr -d ' ')（$SIZE_BYTES バイト）"
echo "  SHA-256:  $SHA256"
echo "  対応:     $ARCHS"
echo "  手順書:   $(stat -f %z "$CHECK_GUIDE") バイト"
