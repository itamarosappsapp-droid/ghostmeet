#!/usr/bin/env python3
"""Собирает системный промпт стенда из документа и вписывает его в bench.html.

Существует потому, что уже подвело: промпт правился в коде и в
docs/GhostMeet-Prompts.md, а встроенная копия в bench.html осталась старой, и
целый прогон четырёх моделей измерил предыдущую версию правил. Отличить одно от
другого по отчёту нельзя — тексты похожи, а выводы противоположны.

    python3 sync-prompt.py            # переписать bench.html
    python3 sync-prompt.py --check    # ничего не менять, код возврата 1 при расхождении

Заготовки (профиль + контекст собеседования) живут здесь, а не в HTML: это
фикстура прогона, и менять её надо одинаково для всех моделей сразу.
"""

import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOC = ROOT / "docs" / "GhostMeet-Prompts.md"
BENCH = pathlib.Path(__file__).with_name("bench.html")

# Заголовки — дословно из PromptFragment; расходиться им нельзя, иначе стенд
# меряет промпт, которого приложение не собирает.
PROFILE_HEADING = "Контекст о пользователе (резюме / роль / стек):"
CONTEXT_HEADING = "Заготовки пользователя к этому собеседованию:"

PROFILE = """Роль: backend-разработчик
Опыт: 7 лет, финтех и высоконагруженные сервисы
Стек: Go, PostgreSQL, Kafka, Kubernetes"""

# Три разные истории, а не одна. С одной заготовкой любой вопрос про опыт
# получал ответ про миграцию горячей таблицы, и перетекание полей друг в друга
# («горячую таблицу платежей», где «платежи» из мотивации) было не отличить от
# нормальной работы: рассказывать было просто нечего больше.
INTERVIEW_CONTEXT = f"""Истории из практики:
Разошлись с коллегой по миграции горячей таблицы: я настаивал на поэтапной, он на разовом переключении. Собрал цифры по рискам и вынес на общий разбор, сошлись на промежуточном варианте.

Ночной инцидент: очередь встала, потребитель не успевал за продюсером и лаг рос часами. Поднял число партиций и вынес тяжёлую обработку в отдельный воркер, к утру лаг разошёлся; после этого завёл алерт на рост лага.

Самое сложное за последний год — выкатить смену схемы без простоя. Сделал двойную запись, перелил старые строки фоном, переключил чтение и только потом убрал старую колонку.

Почему эта компания:
Продукт про платежи, знаком по прошлой работе; интересен масштаб и команда.

Ожидания по деньгам:
От 350 тысяч на руки, готов обсуждать в зависимости от объёма задач.

Вопросы к работодателю:
Как устроен процесс ревью и кто принимает решение о выкатке."""


# Вопросы фикстуры. Держатся здесь, а не в HTML, по той же причине, что и
# профиль: вопрос должен быть один и тот же для обоих жанров и всех моделей.
#
# У каждого своя строка `you` — начатая реплика кандидата для галочки «я уже
# начал отвечать». Общей она быть не может: половина фразы про структуру данных
# посреди вопроса про event loop — это не проверка утверждения промпта, а шум.
QUESTIONS = [
    {
        "id": "top100",
        "label": "Топ-100 товаров — алгоритм, внутри стека",
        "them": ("Нужно отдавать топ сто товаров по просмотрам за последний час. "
                 "Просмотров — миллионы. Какая структура данных и какая сложность?"),
        "you": "Ну, я бы тут смотрел в сторону структуры, которая держит топ по ключу, и",
    },
    {
        "id": "eventloop",
        "label": "Event loop — вне стека профиля",
        "them": ("Давайте про event loop. Почему setTimeout с нулём выполняется не сразу, "
                 "и что произойдёт раньше — он или промис, который уже зарезолвился?"),
        "you": "Ну, насколько я помню, там две разные очереди, и",
    },
    {
        "id": "conflict",
        "label": "Конфликт в команде — проверка заготовок",
        "them": "Расскажите про случай, когда вы разошлись во мнениях с коллегой. Что вы сделали?",
        "you": "Был у нас случай на ревью, когда мы с коллегой",
    },
]


def blocks_from_doc(section: str) -> list[str]:
    """Блоки ```text``` указанного раздела авторитетного документа."""
    doc = DOC.read_text(encoding="utf-8")
    start = doc.index(section)
    end = doc.index("\n## ", start + 5)
    found = re.findall(r"```text\n(.*?)\n```", doc[start:end], re.S)
    if len(found) < 2:
        raise SystemExit(f"в разделе «{section}» ожидались system- и user-блоки")
    return found


def assembled(section: str) -> str:
    """System-промпт жанра ровно так, как его клеит `PromptFragment.system`."""
    return "\n\n".join([
        blocks_from_doc(section)[0],
        f"{PROFILE_HEADING}\n{PROFILE}",
        f"{CONTEXT_HEADING}\n{INTERVIEW_CONTEXT}",
    ])


def user_tail(section: str) -> str:
    """Закрывающая строка user-сообщения жанра — всё, что идёт после разговора.

    Отделена от вопроса намеренно: вопрос принадлежит прогону, а эта строка —
    жанру, и склеенные вместе они означали, что смена жанра стирает выбранный
    вопрос. Страница собирает сообщение из двух частей.

    Шаблон в документе размечен `{{#if …}}`; ветки, которых в стенде нет
    (саммари, OCR), выкидываются целиком — приложение делает так же и голого
    заголовка не шлёт.
    """
    tpl = blocks_from_doc(section)[1]
    tpl = re.sub(r"\{\{#if (?:summary|ocr_text|transcript_empty)\}\}.*?\{\{/if\}\}\n?", "", tpl, flags=re.S)
    head, _, tail = tpl.partition("{{transcript_all}}")
    if not _:
        raise SystemExit(f"в user-шаблоне «{section}» нет {{{{transcript_all}}}}")
    return tail.strip()


def embedded(html: str, name: str) -> str:
    start = html.index(f"const {name}")
    end = html.index(";\n", start)
    return json.loads(html[start:end].split("=", 1)[1].strip())


def fingerprint(value) -> str:
    """Отпечаток константы. Не только строки: `QUESTIONS` и `USER_TAILS` —
    структуры, а сверять их надо тем же способом, что и промпт."""
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:8]


# Четыре константы страницы — два жанра по два сообщения. «Подробно» и «коротко»
# отвечают на один и тот же разговор и различаются только текстом правил и
# бюджетом; сравнивать их между собой имеет смысл только так.
CONSTANTS = [
    ("DEFAULT_SYSTEM", lambda: assembled("## 9. Коротко")),
    ("DEFAULT_SYSTEM_LONG", lambda: assembled("## 1. Assist")),
    ("USER_TAILS", lambda: {"brief": user_tail("## 9. Коротко"), "long": user_tail("## 1. Assist")}),
    ("QUESTIONS", lambda: QUESTIONS),
]


def main() -> int:
    html = BENCH.read_text(encoding="utf-8")
    stale = []
    for name, build in CONSTANTS:
        want = build()
        have = embedded(html, name)
        if want != have:
            stale.append((name, have, want))

    if not stale:
        print("совпадает: " + ", ".join(f"{n} {fingerprint(b())}" for n, b in CONSTANTS))
        return 0

    if "--check" in sys.argv:
        for name, have, want in stale:
            print(f"РАСХОЖДЕНИЕ {name}: в стенде {fingerprint(have)}, в документе {fingerprint(want)}")
        print("прогон измерит не тот промпт; запустите sync-prompt.py без --check")
        return 1

    def put(name: str, value: str) -> None:
        # Срезом, а не re.sub: в промпте есть обратные слэши, и шаблон замены
        # тихо превратил бы \n в настоящий перевод строки — этим уже был сломан
        # весь скрипт страницы.
        nonlocal html
        start = html.index(f"const {name}")
        end = html.index(";\n", start) + 1
        html = html[:start] + f"const {name} = {value};" + html[end:]

    for name, have, want in stale:
        put(name, json.dumps(want, ensure_ascii=False, indent=None))
        print(f"обновлено {name}: {fingerprint(have)} → {fingerprint(want)}")

    # Отпечатки едут в страницу, а не считаются в ней: отчёт должен печатать
    # ровно то число, которое печатает этот скрипт, иначе сверять их бесполезно.
    put("PROMPT_FINGERPRINTS", json.dumps(
        {"brief": fingerprint(assembled("## 9. Коротко")),
         "long": fingerprint(assembled("## 1. Assist"))}, ensure_ascii=False))
    BENCH.write_text(html, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
