# SilenceCut — заметки для AI-агентов

## Git: .git вне синка Яндекс.Диска (с 11.07.2026)

Яндекс.Диск повреждал `.git` (терял объекты, плодил конфликтные копии ref'ов), поэтому git-dir вынесен из синка: он лежит в `~/.git-store/silencecut.git`, а `.git` в корне проекта — однострочный файл-указатель `gitdir: ../../../.git-store/silencecut.git`. НЕ заменять этот файл папкой и НЕ переписывать путь на абсолютный (относительный путь одинаков на всех машинах с папкой в `~/Yandex.Disk.localized/`).

Настройка git на новой машине (файлы проекта уже приходят через Диск вместе с указателем):

```bash
git clone --no-checkout --separate-git-dir="$HOME/.git-store/silencecut.git" \
  https://github.com/vladimiraldushin/SilenceCut.git "${TMPDIR:-/tmp}/tmp-clone"
rm -rf "${TMPDIR:-/tmp}/tmp-clone"   # временный worktree не нужен — файлы уже в папке
cd "$HOME/Yandex.Disk.localized/Монтаж/silencecut"
git config core.worktree "$PWD"
git reset   # заполнить индекс из HEAD; git status должен стать чистым
```
