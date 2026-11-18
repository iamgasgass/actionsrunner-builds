#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check the words of Buy me tokens against App Store Review Guideline 3.1.1.

A tip is a voluntary one-time purchase, so no string of the tip jar's table
names a donation, a plan or a subscription, promises an unlock, an upgrade or
premium access, or quotes a token amount or balance, in any language the table
has: the English words, and the Chinese and Japanese ones that say the same.
The table also says plainly, in the statement string, that a tip is a voluntary
one-time purchase and that every feature is free either way, and the statement
says it in every language the table has: each storefront reads its own. A no-break
space reads as a space and a word joiner (U+2060), which ties the last characters
of a Chinese or Japanese text so that none wraps alone, as nothing. A tip is
打赏 in Simplified Chinese and 贊助 in Traditional Chinese, and neither language
uses the other's word or 小费.

The table is a String Catalog (`Localization/TipJar.xcstrings`) or a compiled
strings file (`TipJar.strings` of an application's language directory); every
key and every localized value is read, and a comment, which no one sees, is not.
Run it on the catalog, and again, once the translations are in, on the
application's tables.

    check-tip-words.py Andarium/Localization/TipJar.xcstrings
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

# The words each language's table must not use, as regular expressions: English
# whole words and their forms, and the Chinese (Simplified and Traditional) and
# Japanese words for the same ideas.
FORBIDDEN = (
    ("donate", re.compile(r"\bdonat\w*|\bdonor\w*", re.IGNORECASE)),
    ("plan", re.compile(r"\bplans?\b", re.IGNORECASE)),
    ("subscription", re.compile(r"\bsubscri\w*", re.IGNORECASE)),
    ("unlock", re.compile(r"\bunlock\w*", re.IGNORECASE)),
    ("premium", re.compile(r"\bpremium\b", re.IGNORECASE)),
    ("upgrade", re.compile(r"\bupgrad\w*", re.IGNORECASE)),
    ("credits", re.compile(r"\bcredits?\b", re.IGNORECASE)),
    ("balance", re.compile(r"\bbalances?\b", re.IGNORECASE)),
    # The Chinese and Japanese words are the App Store's and iOS's own for these ideas: 捐赠 and 捐款 are
    # Apple's Donate, 订阅 and 訂閱 its Subscription, 套餐, 方案 and プラン its Plan.
    ("a donation", re.compile("捐赠|捐贈|捐款|捐助|捐献|捐獻|斗内|斗內|寄付|寄附|募金|ドネーション")),
    ("a subscription", re.compile("订阅|訂閱|購読|定期購入|定期購読|サブスク")),
    ("a plan", re.compile("套餐|方案|计划|計劃|計畫|プラン")),
    ("an unlock", re.compile("解锁|解鎖|アンロック|ロック解除")),
    ("premium or upgrade", re.compile("高级版|高級版|プレミアム|升级|升級|アップグレード")),
    ("credits", re.compile("积分|積分|点数|點數|クレジット")),
    ("a balance", re.compile("余额|余額|餘額|残高")),
)
# A tip is 打赏 in Simplified Chinese and 贊助 in Traditional Chinese. Each language must not use the
# other's word (in either script) or the earlier 小费, as a word of any other meaning.
NOT_IN = {
    "zh-Hans": ("小费", "小費", "打賞", "贊助", "赞助"),
    "zh-Hant": ("小费", "小費", "打赏", "打賞", "赞助"),
}
# A number, or a placeholder for one, beside the word token: Western, full-width
# and Chinese or Japanese numerals, with the counters 个, 個, 枚 and つ between.
NUMBER = r"(?:[0-9０-９]|%(?:\d+\$)?(?:l{0,2}d|f|@))"
NUMERAL = "[〇零一二三四五六七八九十百千万萬两兩]"
TOKEN = r"(?:tokens?|トークン)"
COUNTER = r"(?:个|個|枚|つ)?\s*(?:的|の)?\s*"
AMOUNT = re.compile(
    NUMBER + r"[0-9０-９.,，．]*\s*[kKmM万萬]?\s*" + COUNTER + TOKEN
    + "|" + NUMERAL + r"+\s*" + COUNTER + TOKEN
    + "|" + TOKEN + r"\s*[:：]?\s*" + NUMBER,
    re.IGNORECASE)
# What the statement must say in each language, each idea in one of the words of its
# group: voluntary, one-time, a purchase, and free either way.
REQUIRED = {
    "en": (("voluntary",), ("one-time",), ("purchase",), ("free",)),
    "zh-Hans": (("自愿",), ("一次性",), ("购买",), ("免费",)),
    "zh-Hant": (("自願",), ("一次性",), ("購買",), ("免費",)),
    "ja": (("任意",), ("1回限り", "一回限り"), ("購入",), ("無料",)),
}


def statement_key(texts: list[tuple[str, str, str]]) -> str | None:
    """The statement is the key whose English text says most of its ideas, and at least two."""
    best, score = None, 1
    for key in sorted({key for key, _language, _text in texts}):
        said = sum(any(word in key.lower() for word in group) for group in REQUIRED["en"])
        if said > score:
            best, score = key, said
    return best


def statement_problems(texts: list[tuple[str, str, str]], name: str, languages: set[str]) -> list[str]:
    """The statement, in each of the languages, with each of its ideas. A language the check
    holds no words for is itself a problem: it is added here with the table."""
    key = statement_key(texts)
    if key is None:
        return [f"{name}: no string says that a tip is a voluntary one-time purchase, and that every "
                "feature is free either way"]
    found = []
    for language in sorted(languages):
        words = REQUIRED.get(language)
        if words is None:
            found.append(f"{name}: [{language}] has no required words in this check; add the ones that say "
                         "voluntary, one-time, purchase and free")
            continue
        values = [text.lower() for k, lang, text in texts if lang == language and k == key]
        for group in words:
            if not any(word.lower() in value for value in values for word in group):
                found.append(f"{name}: no statement [{language}] says {group[0]!r}: a tip is a voluntary "
                             "one-time purchase, and every feature is free either way")
    return found


def plain(text: str) -> str:
    """The text as it reads: a no-break space is a space, and a word joiner, which ties the
    last characters of a Chinese or Japanese line (and says nothing), is nothing."""
    return text.replace("\u2060", "").replace("\u00a0", " ")


def texts_of_catalog(data: dict) -> list[tuple[str, str, str]]:
    """(key, language, text) for every key of a String Catalog (the key itself is
    the source language's text) and every value localized for it."""
    source = data.get("sourceLanguage", "en")
    found = []
    for key, entry in data.get("strings", {}).items():
        found.append((plain(key), source, plain(key)))
        for language, localization in (entry.get("localizations") or {}).items():
            units = []
            if "stringUnit" in localization:
                units.append(localization["stringUnit"])
            for variation in (localization.get("variations") or {}).values():
                units.extend(item.get("stringUnit", {}) for item in variation.values())
            found.extend((plain(key), language, plain(unit["value"])) for unit in units if isinstance(unit.get("value"), str))
    return found


def texts_of_strings(path: Path) -> list[tuple[str, str, str]]:
    """(key, language, text) for a compiled strings file, the language being its
    directory's."""
    language = path.parent.name.removesuffix(".lproj")
    raw = path.read_bytes()
    try:
        table = plistlib.loads(raw)
    except (plistlib.InvalidFileException, ValueError):
        # An old-style text file: UTF-16 with a mark, or UTF-8.
        text = plain(raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", errors="replace"))
        return [(text[:40], language, text)]
    found = []
    for key, value in table.items():
        found.append((plain(str(key)), language, plain(str(key))))
        found.extend((plain(str(key)), language, plain(text)) for text in flatten(value))
    return found


def flatten(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in flatten(item)]
    if isinstance(value, (list, tuple)):
        return [text for item in value for text in flatten(item)]
    return []


def problems_in(texts: list[tuple[str, str, str]], name: str) -> list[str]:
    found = []
    seen = set()
    for key, language, text in texts:
        if (key, language, text) in seen:
            continue
        seen.add((key, language, text))
        for label, pattern in FORBIDDEN:
            match = pattern.search(text)
            if match:
                found.append(f"{name}: {key!r} [{language}] uses {label} ({match.group(0)!r})")
        for word in NOT_IN.get(language, ()):
            if word in text:
                found.append(f"{name}: {key!r} [{language}] uses {word!r}, which is not this language's word for a tip")
        match = AMOUNT.search(text)
        if match:
            found.append(f"{name}: {key!r} [{language}] quotes a token amount ({match.group(0)!r})")
    return found


def check(path: Path) -> tuple[list[str], int]:
    """The problems of one table and how many texts it has."""
    if path.suffix == ".xcstrings":
        texts = texts_of_catalog(json.loads(path.read_text(encoding="utf-8")))
        name = path.name
    else:
        texts = texts_of_strings(path)
        name = str(path)
    found = problems_in(texts, name)
    found.extend(statement_problems(texts, name, {language for _key, language, _text in texts}))
    return found, len(texts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tables", nargs="+", type=Path, help="a TipJar.xcstrings or a TipJar.strings")
    options = parser.parse_args()
    found: list[str] = []
    count = 0
    for path in options.tables:
        try:
            problems, texts = check(path)
        except (OSError, ValueError) as error:
            found.append(f"{path}: cannot be read: {error}")
            continue
        found.extend(problems)
        count += texts
    for line in found:
        print(line, file=sys.stderr)
    if found:
        return 1
    print(f"{len(options.tables)} table(s), {count} texts: no forbidden word, no token amount, "
          "the statement in every language")
    return 0


if __name__ == "__main__":
    sys.exit(main())
