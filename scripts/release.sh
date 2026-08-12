#!/bin/bash
#
# Выпускает релиз GhostMeet: проверяет, собирает, подписывает, тегает, публикует.
#
#   ./scripts/release.sh 0.2.0        # спросит перед тем, как что-то отправить наружу
#   ./scripts/release.sh 0.2.0 --yes  # без вопросов (для повторного прогона)
#   ./scripts/release.sh 0.2.0 --dry-run  # всё локально, ничего не отправлять
#
# Почему релиз собирается здесь, а не в CI. Разрешения macOS привязаны к подписи, а подпись у
# проекта одна — личный сертификат Apple Development. Отдать его закрытую часть в secrets значит
# разрешить подписывать вашим именем всякому, кто получит доступ к репозиторию; собирать в CI без
# подписи значит выдать коллегам сборку, которая заново просит микрофон и запись экрана. Поэтому
# CI собирает и прогоняет тесты, а подписывает эта машина.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PROJECT="$ROOT/GhostMeet/GhostMeet.xcodeproj"
DERIVED="$ROOT/.build/release-derived"
CHANGELOG="$ROOT/CHANGELOG.md"

VERSION="${1:-}"
ASSUME_YES=no
DRY_RUN=no
for arg in "${@:2}"; do
  case "$arg" in
    --yes) ASSUME_YES=yes ;;
    --dry-run) DRY_RUN=yes ;;
    *) echo "✗ Неизвестный ключ: $arg"; exit 1 ;;
  esac
done

fail() { echo "✗ $1"; exit 1; }

[ -n "$VERSION" ] || fail "Укажите версию: ./scripts/release.sh 0.2.0"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "Версия должна быть MAJOR.MINOR.PATCH, а не «$VERSION»"

TAG="v$VERSION"

echo "▸ Проверки перед релизом…"

# Грязное дерево — это релиз из того, чего нет в истории: тег будет указывать на один код,
# а DMG собран из другого, и разойдутся они молча.
[ -z "$(git status --porcelain)" ] || fail "Рабочее дерево грязное — закоммитьте или отложите правки"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Тег $TAG уже существует"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "  ⚠ ветка $BRANCH, не main"

grep -q "^## \[$VERSION\]" "$CHANGELOG" \
  || fail "В CHANGELOG.md нет раздела ## [$VERSION] — релиз без записи о том, что в нём"

PROJECT_VERSION="$(xcodebuild -project "$PROJECT" -showBuildSettings -target GhostMeet 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION / {print $2; exit}')"
[ "$PROJECT_VERSION" = "$VERSION" ] \
  || fail "MARKETING_VERSION в проекте — $PROJECT_VERSION, а релиз $VERSION. Поправьте проект и закоммитьте"

echo "  дерево чистое, тега нет, CHANGELOG и проект согласны на $VERSION"

# Тесты гоняются до сборки образа: собранный и подписанный DMG со сломанными тестами — это
# двадцать минут, потраченных на то, чтобы его выбросить.
echo "▸ Тесты…"
TEST_LOG="$ROOT/.build/release-tests.log"
mkdir -p "$ROOT/.build"
set +e
xcodebuild -project "$PROJECT" -scheme GhostMeet -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" test >"$TEST_LOG" 2>&1
TEST_STATUS=$?
set -e

# «✔ Test run with 0 tests in N suites passed» — это упавший host-процесс, а не успех: сюиты
# объявились, приложение умерло до первого теста, и их ноль тестов честно не упал. Один раз эта
# строка уже была принята за зелёный прогон.
if grep -q "Test run with 0 tests" "$TEST_LOG"; then
  fail "Ноль тестов — host-приложение упало на старте. Смотрите ~/Library/Logs/DiagnosticReports/GhostMeet-*.ips и $TEST_LOG"
fi
[ $TEST_STATUS -eq 0 ] || fail "Тесты упали (код $TEST_STATUS), подробности в $TEST_LOG"

TEST_COUNT="$(grep -oE "Test run with [0-9]+ test" "$TEST_LOG" | tail -1 | grep -oE '[0-9]+' || echo '?')"
echo "  прошло тестов: $TEST_COUNT"

echo "▸ Сборка образа…"
"$ROOT/scripts/make-dmg.sh" "$VERSION"
DMG="$ROOT/dist/GhostMeet-$VERSION.dmg"
[ -f "$DMG" ] || fail "make-dmg.sh не оставил $DMG"

# Заметки к релизу берутся из CHANGELOG, а не пишутся заново: два описания одного релиза
# расходятся на первой же правке.
NOTES="$ROOT/.build/release-notes-$VERSION.md"
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { inside = 1; next }
  inside && /^## \[/ { exit }
  inside { print }
' "$CHANGELOG" > "$NOTES"
[ -s "$NOTES" ] || fail "Раздел ## [$VERSION] в CHANGELOG пуст"

echo "▸ Тег $TAG…"
git tag -a "$TAG" -m "GhostMeet $VERSION" -m "$(cat "$NOTES")"

if [ "$DRY_RUN" = yes ]; then
  echo
  echo "✓ Локально готово: $DMG, тег $TAG."
  echo "  --dry-run: наружу ничего не отправлено. Отменить тег: git tag -d $TAG"
  exit 0
fi

echo
echo "Дальше — наружу:"
echo "  • git push origin $BRANCH --follow-tags"
echo "  • релиз $TAG на GitHub с файлом $(basename "$DMG")"
if [ "$ASSUME_YES" != yes ]; then
  read -r -p "Публиковать? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Остановился. Локально всё готово; тег снимается через git tag -d $TAG"; exit 0 ;;
  esac
fi

echo "▸ Push…"
git push origin "$BRANCH" --follow-tags

if command -v gh >/dev/null 2>&1; then
  echo "▸ Релиз на GitHub…"
  gh release create "$TAG" "$DMG" --title "GhostMeet $VERSION" --notes-file "$NOTES"
  echo
  echo "✓ $TAG опубликован"
else
  echo
  echo "⚠ gh не установлен — тег отправлен, релиз нужно создать руками."
  echo
  echo "  brew install gh && gh auth login"
  echo "  gh release create $TAG \"$DMG\" --title \"GhostMeet $VERSION\" --notes-file \"$NOTES\""
  echo
  echo "  Либо через веб: Releases → Draft a new release → тег $TAG,"
  echo "  описание из $NOTES, приложить $DMG"
fi

echo
echo "Коллеге вместе с файлом передайте одну команду — без неё macOS откажется"
echo "открывать приложение, потому что оно не нотаризовано:"
echo
echo "  xattr -dr com.apple.quarantine /Applications/GhostMeet.app"
