#!/bin/bash
# Собирает CLI и кладёт его в ~/.local/bin.
#
# Отдельный шаг, потому что бинарь зовут не из папки проекта: конвейер с Remotion
# запускает его из другого репозитория, и путь внутри DerivedData туда не годится —
# он меняется при пересборке и содержит хеш конфигурации.

set -euo pipefail

cd "$(dirname "$0")/.."

DEST="${1:-$HOME/.local/bin}"
mkdir -p "$DEST"

echo "Сборка silencecut-cli..."
xcodebuild -project SilenceCut.xcodeproj -scheme silencecut-cli \
    -configuration Release build >/dev/null

# Путь спрашиваем у самого xcodebuild. Поиск по DerivedData находит ещё и файл
# отладочных символов внутри .dSYM — он называется так же и тоже исполняемый на вид,
# но запускаться отказывается.
PRODUCTS_DIR=$(xcodebuild -project SilenceCut.xcodeproj -scheme silencecut-cli \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
BINARY="$PRODUCTS_DIR/silencecut"

if [ ! -x "$BINARY" ]; then
    echo "Не нашёлся собранный бинарь: $BINARY" >&2
    exit 1
fi

cp "$BINARY" "$DEST/silencecut"
chmod +x "$DEST/silencecut"

echo "Установлено: $DEST/silencecut"
if ! command -v silencecut >/dev/null 2>&1; then
    echo "ВНИМАНИЕ: $DEST не в PATH. Добавьте в ~/.zshrc:"
    echo "  export PATH=\"$DEST:\$PATH\""
fi
