#!/bin/bash
#
# Собирает GhostMeet.app в Release и упаковывает в DMG для передачи коллегам.
#
#   ./scripts/make-dmg.sh            # версия из проекта
#   ./scripts/make-dmg.sh 1.0-beta2  # своя метка версии в имени файла
#
# Готовый образ кладётся в dist/. Внутри — приложение, ярлык «Программы» и
# файл с инструкцией: без неё коллега получит «программу нельзя открыть» и
# решит, что сборка битая.
#
# Почему без нотаризации. У проекта есть только сертификат Apple Development —
# нотаризация требует Developer ID, то есть платного участия в Apple Developer
# Program. Подпись при этом настоящая и стабильная, и это
# важнее, чем кажется: разрешения macOS привязаны к подписи, и при ad-hoc
# подписи каждая новая сборка спрашивала бы микрофон и запись экрана заново.
# Цена — карантин: смотри инструкцию, которую скрипт кладёт внутрь образа.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PROJECT="$ROOT/GhostMeet/GhostMeet.xcodeproj"
DERIVED="$ROOT/.build/dmg-derived"
STAGE="$ROOT/.build/dmg-stage"
DIST="$ROOT/dist"

VERSION="${1:-$(xcodebuild -project "$PROJECT" -showBuildSettings -target GhostMeet 2>/dev/null \
  | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')}"
DMG="$DIST/GhostMeet-$VERSION.dmg"

echo "▸ Сборка Release…"
rm -rf "$DERIVED" "$STAGE"
xcodebuild -project "$PROJECT" -scheme GhostMeet -configuration Release \
  -derivedDataPath "$DERIVED" build >/dev/null

APP="$DERIVED/Build/Products/Release/GhostMeet.app"
[ -d "$APP" ] || { echo "✗ Сборка не дала GhostMeet.app"; exit 1; }

echo "▸ Проверка подписи…"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" | sed 's/^/  /'

# Пустой Info.plist ловится здесь, а не у коллеги: строки разрешений в этом
# проекте уже пропадали молча — Xcode выкидывает неизвестные ему INFOPLIST_KEY_*
# без единого предупреждения, и приложение доезжает без доступа к экрану.
echo "▸ Проверка строк разрешений…"
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription \
           NSScreenCaptureUsageDescription NSSpeechRecognitionUsageDescription; do
  plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || { echo "✗ В Info.plist нет $key — приложение молча останется без доступа"; exit 1; }
done
echo "  все четыре на месте"

echo "▸ Сборка образа…"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp "$ROOT/scripts/dmg-readme.txt" "$STAGE/ЧИТАТЬ ПЕРВЫМ.txt"

rm -f "$DMG"
hdiutil create -volname "GhostMeet $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo
echo "✓ $DMG"
echo "  $(du -h "$DMG" | cut -f1), версия $VERSION"
echo
echo "Коллеге вместе с файлом передайте одну команду — без неё macOS откажется"
echo "открывать приложение, потому что оно не нотаризовано:"
echo
echo "  xattr -dr com.apple.quarantine /Applications/GhostMeet.app"
