#!/usr/bin/env python3
"""Достаёт ошибки сборки из .xcresult и печатает их аннотациями GitHub Actions.

    python3 scripts/xcresult-errors.py .build/ci-result.xcresult

Зачем отдельный файл, а не строчка в workflow: логи Actions без токена
репозитория не читаются вовсе, а аннотации читаются открытым API — и когда CI
падает, единственный способ узнать причину со стороны это они. Встроенный в YAML
python при этом ломает блочный скаляр отступами, что уже случилось.

Бандл .xcresult берётся вместо лога сознательно: его пишет сам xcodebuild, и он
переживает даже потерю конвейера — ровно так нашлась настоящая причина, когда
файла лога не существовало.

Молчит и выходит с нулём, если бандла нет, он не читается или ошибок в нём нет:
этот скрипт объясняет чужое падение, а не создаёт своё.
"""

import json
import subprocess
import sys

MAX_ERRORS = 10
MAX_MESSAGE = 300


def build_errors(path: str) -> list[dict]:
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "build-results", "--path", path],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return []

    if raw.returncode != 0 or not raw.stdout.strip():
        return []

    try:
        return json.loads(raw.stdout).get("errors") or []
    except (ValueError, AttributeError):
        return []


def annotate(issue: dict) -> str:
    # Имя файла, а не полный путь: путь на раннере начинается с /Users/runner и
    # в заголовке аннотации не помещается, а различить файлы хватает имени.
    source = (issue.get("sourceURL") or "").split("#")[0]
    where = source.rsplit("/", 1)[-1] or "проект"
    message = " ".join((issue.get("message") or "").split())[:MAX_MESSAGE]
    return f"::error title=Сборка {where}::{message}"


def main() -> int:
    if len(sys.argv) != 2:
        print("Укажите путь к .xcresult", file=sys.stderr)
        return 2

    for issue in build_errors(sys.argv[1])[:MAX_ERRORS]:
        print(annotate(issue))
    return 0


if __name__ == "__main__":
    sys.exit(main())
