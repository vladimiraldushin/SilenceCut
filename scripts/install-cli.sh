#!/bin/bash
# Собирает CLI и ставит его в ~/.local/bin вместе с фреймворками.
#
# Бинарь зовут не из папки проекта: конвейер с Remotion запускает его из другого
# репозитория. Путь внутри DerivedData туда не годится — он содержит хеш конфигурации
# и меняется при пересборке.
#
# Фреймворки кладутся в ../lib/silencecut относительно бинаря — этот путь зашит в
# LD_RUNPATH_SEARCH_PATHS. Компилировать их внутрь нельзя: их исходники импортируют
# RECore, и при компиляции внутрь модуль оказался бы объявлен дважды.

set -euo pipefail

cd "$(dirname "$0")/.."

BIN_DIR="${1:-$HOME/.local/bin}"
LIB_DIR="$(dirname "$BIN_DIR")/lib/silencecut"
mkdir -p "$BIN_DIR" "$LIB_DIR"

echo "Сборка silencecut-cli..."
xcodebuild -project SilenceCut.xcodeproj -scheme silencecut-cli \
    -configuration Release build >/dev/null

# Путь спрашиваем у самого xcodebuild. Поиск по DerivedData находит ещё и файл
# отладочных символов внутри .dSYM — он называется так же и на вид исполняемый,
# но запускаться отказывается.
PRODUCTS_DIR=$(xcodebuild -project SilenceCut.xcodeproj -scheme silencecut-cli \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')

BINARY="$PRODUCTS_DIR/silencecut"
if [ ! -x "$BINARY" ]; then
    echo "Не нашёлся собранный бинарь: $BINARY" >&2
    exit 1
fi

cp "$BINARY" "$BIN_DIR/silencecut"
chmod +x "$BIN_DIR/silencecut"

for framework in RECore RETimeline REExport; do
    rm -rf "$LIB_DIR/$framework.framework"
    cp -R "$PRODUCTS_DIR/$framework.framework" "$LIB_DIR/"
done

echo "Установлено: $BIN_DIR/silencecut"
echo "Фреймворки:  $LIB_DIR"

if ! "$BIN_DIR/silencecut" help >/dev/null 2>&1; then
    echo "ВНИМАНИЕ: бинарь не запускается — проверьте пути к фреймворкам" >&2
    exit 1
fi
if ! command -v silencecut >/dev/null 2>&1; then
    echo "ВНИМАНИЕ: $BIN_DIR не в PATH. Добавьте в ~/.zshrc:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
