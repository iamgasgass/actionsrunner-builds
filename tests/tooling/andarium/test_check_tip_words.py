#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check what the Buy me tokens word check refuses and what it accepts."""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

STATEMENT = ("A tip is a voluntary one-time purchase that supports Andarium’s development. "
             "Every feature is free either way.")
# The statement in each language, as the table says it; each idea is one word of it.
STATEMENTS = {
    "zh-Hans": "打赏是自愿的一次性购买，用于支持Andarium的开发。无论是否打赏，所有功能都免费。",
    "zh-Hant": "贊助是自願的一次性購買，用於支持Andarium的開發。無論是否贊助，所有功能都免費。",
    "ja": "チップは、Andariumの開発を支える任意の一回限りの購入です。チップの有無にかかわらず、すべての機能は無料です。",
}
# Each language's ideas, one word that says each in STATEMENTS.
IDEAS = {
    "zh-Hans": ("自愿", "一次性", "购买", "免费"),
    "zh-Hant": ("自願", "一次性", "購買", "免費"),
    "ja": ("任意", "一回限り", "購入", "無料"),
}


def catalog(strings: dict[str, dict[str, str]]) -> str:
    """A String Catalog: each key with the values localized for it, by language."""
    return json.dumps({
        "sourceLanguage": "en", "version": "1.0",
        "strings": {key: {"comment": "A note for translators: plan, donate, subscription.",
                          "localizations": {language: {"stringUnit": {"state": "translated", "value": value}}
                                            for language, value in values.items()}}
                    for key, values in strings.items()},
    }, ensure_ascii=False, indent=2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checker", type=Path, required=True)
    parser.add_argument("--table", type=Path, required=True, help="the application's TipJar.xcstrings")
    options = parser.parse_args()
    failures: list[str] = []

    def run(*paths: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-B", str(options.checker), *map(str, paths)], check=False, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)

    def expect(label: str, result: subprocess.CompletedProcess[str], *, passes: bool, said: str = "") -> None:
        if (result.returncode == 0) != passes:
            failures.append(f"{label}: expected {'a pass' if passes else 'a failure'}:\n{result.stdout}")
        elif said and said not in result.stdout:
            failures.append(f"{label}: output lacks {said!r}:\n{result.stdout}")

    with tempfile.TemporaryDirectory(prefix="andarium-tip-words-") as directory:
        root = Path(directory)

        def table(name: str, strings: dict[str, dict[str, str]], *, statement: bool = True,
                  said: dict[str, str] | None = None) -> Path:
            """A table with the statement said in every language (`said` changes a language's
            words) or, without `statement`, with none; only the languages the table localizes."""
            path = root / name / "TipJar.xcstrings"
            path.parent.mkdir()
            everything = dict(strings)
            if statement:
                languages = {language for values in strings.values() for language in values} | set(said or {})
                everything = {STATEMENT: {language: (said or {}).get(language) or STATEMENTS.get(language, "x")
                                          for language in languages if language != "en"}, **strings}
            path.write_text(catalog(everything), encoding="utf-8")
            return path

        # The application's own table passes.
        expect("the table", run(options.table), passes=True, said="no forbidden word")

        # Plain words pass, including the ones that only contain a forbidden word.
        expect("clean", run(table("clean", {
            "Buy me tokens": {"ja": "トークンをおごる", "zh-Hans": "请我喝点Token", "zh-Hant": "請我喝點Token"},
            "Done": {"ja": "完了", "zh-Hans": "完成", "zh-Hant": "完成"},
            "Please explain the planet, planting and the planar plane.": {},
            "Tips aren’t available right now": {},
            "Pro, $4.99": {},
            "Token": {},
        })), passes=True)

        # Each English word, in a key and in a localized value, in any case.
        for index, word in enumerate((
                "donate", "Donation", "DONATIONS", "donor", "plan", "Plans", "subscription", "Subscribe", "subscriber",
                "unlock", "Unlocked", "premium", "Upgrade", "credit", "Credits", "balance")):
            expect(f"key-{word}", run(table(f"key-{index}", {f"Please {word} now": {}})), passes=False, said="uses")
            expect(f"value-{word}", run(table(f"value-{index}", {"Thanks": {"en": f"Thanks, {word}!"}})),
                   passes=False, said="uses")

        # The Chinese and Japanese words for the same ideas, in the language that has them.
        for index, (language, text) in enumerate((
                ("zh-Hans", "感谢您的捐赠"), ("zh-Hant", "感謝您的捐款"),
                ("zh-Hant", "斗內"), ("zh-Hans", "订阅更多"), ("zh-Hant", "訂閱"),
                ("zh-Hans", "选择方案"), ("zh-Hans", "升级高级版"),
                ("zh-Hans", "解锁功能"), ("zh-Hant", "余額不足"),
                ("ja", "寄付をお願いします"), ("ja", "サブスクリプション"),
                ("ja", "プランを選ぶ"), ("ja", "プレミアム機能"),
                ("ja", "アップグレード"), ("ja", "残高"),
                ("zh-Hans", "选择套餐"), ("zh-Hant", "選擇方案"), ("zh-Hans", "你的计划"), ("zh-Hant", "你的計畫"),
                ("zh-Hant", "你的計劃"), ("zh-Hans", "捐助开发者"), ("zh-Hant", "捐獻"),
                ("ja", "ドネーション"), ("ja", "定期購読"), ("ja", "定期購入"), ("ja", "募金"),
                ("ja", "サブスク"), ("ja", "寄附"))):
            expect(f"{language}-{index}", run(table(f"cjk-{index}", {"Thanks": {language: text}})),
                   passes=False, said=f"[{language}]")

        # The ties that keep a last word on its line (a no-break space, a word joiner between the last
        # characters) change nothing: the statement says what it must through them, and a forbidden word
        # cannot hide behind one.
        expect("ties", run(table("ties", {"Done": {"ja": "x"}}, said={
            "ja": STATEMENTS["ja"].replace("無料", "無\u2060料").replace("購入", "購\u2060入")})), passes=True)
        expect("ties-en", run(table("ties-en", {"Please sort the thing out.": {}, "Done": {"en": "Almost\u00a0done."}})),
               passes=True)
        for index, (language, text) in enumerate((("en", "Please sub\u2060scribe"), ("zh-Hans", "订\u2060阅更多"),
                                                  ("ja", "寄\u2060付"), ("en", "Please donate\u00a0now"))):
            expect(f"tie-{index}", run(table(f"tie-{index}", {"Thanks": {language: text}})), passes=False, said="uses")

        # A tip is 打赏 in Simplified and 贊助 in Traditional Chinese: each language's own word passes, and the
        # other's, in either script, and 小费 in both, do not.
        expect("tip-words", run(table("tip-words", {
            "One-time tip": {"zh-Hans": "一次性打赏", "zh-Hant": "一次性贊助"}})), passes=True)
        for index, (language, text) in enumerate((
                ("zh-Hant", "一次性打賞"), ("zh-Hant", "一次性打赏"), ("zh-Hant", "一次性小費"),
                ("zh-Hant", "一次性小费"), ("zh-Hant", "一次性赞助"), ("zh-Hans", "一次性小费"),
                ("zh-Hans", "一次性小費"), ("zh-Hans", "一次性打賞"), ("zh-Hans", "一次性贊助"),
                ("zh-Hans", "一次性赞助"))):
            expect(f"tip-word-{index}", run(table(f"tip-word-{index}", {"One-time tip": {language: text}})),
                   passes=False, said=f"[{language}] uses")

        # A token amount or balance, in a number or a placeholder, either side of the word.
        for index, text in enumerate((
                "You have 500 tokens", "You have 1,000 Tokens", "500k tokens", "2.5M tokens", "%lld tokens",
                "%d token", "%1$lld tokens", "Tokens: 12", "tokens 5", "%@ tokens", "トークン 500",
                "12トークン",
                # Counters, full-width digits and Chinese or Japanese numerals.
                "100个Token", "100個のトークン", "１００トークン", "Token：５００", "五十枚トークン",
                "10万Token", "三つのトークン", "一百个Token", "twelve 12 tokens")):
            expect(f"amount-{index}", run(table(f"amount-{index}", {text: {}})), passes=False, said="token amount")

        # The statement is required in English and in every language the table localizes: each of its
        # ideas, said in that language.
        expect("no-statement", run(table("no-statement", {"Buy me tokens": {}}, statement=False)),
               passes=False, said="no string says that a tip is a voluntary")
        for index, word in enumerate(("voluntary", "one-time", "purchase", "free")):
            expect(f"missing-{word}", run(table(f"missing-{index}", {
                STATEMENT.lower().replace(word, "x"): {}}, statement=False)), passes=False, said=f"{word!r}")
        for language, ideas in IDEAS.items():
            expect(f"{language}-statement", run(table(f"say-{language}", {"Done": {language: "x"}})), passes=True)
            for index, idea in enumerate(ideas):
                expect(f"{language}-without-{idea}", run(table(f"without-{language}-{index}", {"Done": {language: "x"}},
                                                                said={language: STATEMENTS[language].replace(idea, "〇")})),
                       passes=False, said=f"[{language}] says")
            # A language that has strings and no statement of its own.
            plain = {"Done": {language: "x"}}
            path = root / f"unsaid-{language}" / "TipJar.xcstrings"
            path.parent.mkdir()
            path.write_text(catalog({STATEMENT: {}, **plain}), encoding="utf-8")
            expect(f"{language}-unsaid", run(path), passes=False, said=f"no statement [{language}] says")
        # Either way of writing Japanese's "one time", and a language the check has no words for.
        expect("ja-kanji", run(table("ja-kanji", {"Done": {"ja": "x"}}, said={
            "ja": STATEMENTS["ja"].replace("1回限り", "一回限り")})), passes=True)
        expect("other-language", run(table("other-language", {"Done": {"ko": "완료"}}, said={"ko": "x"})),
               passes=False, said="[ko] has no required words")

        # A compiled strings table of a language: the same words, by the directory's language, and
        # the statement in that language.
        compiled = root / "ja.lproj" / "TipJar.strings"
        compiled.parent.mkdir()
        say = {STATEMENT: STATEMENTS["ja"]}
        compiled.write_bytes(plistlib.dumps({**say, "Done": "寄付"}, fmt=plistlib.FMT_BINARY))
        expect("compiled-bad", run(compiled), passes=False, said="[ja]")
        compiled.write_bytes(plistlib.dumps({**say, "Done": "完了", "Try again": "もう一度"}, fmt=plistlib.FMT_BINARY))
        expect("compiled-ok", run(compiled), passes=True)
        compiled.write_bytes(plistlib.dumps({"Done": "完了"}, fmt=plistlib.FMT_BINARY))
        expect("compiled-no-statement", run(compiled), passes=False, said="no string says")
        compiled.write_bytes(plistlib.dumps({STATEMENT: STATEMENTS["ja"].replace("無料", "有料")},
                                            fmt=plistlib.FMT_BINARY))
        expect("compiled-not-free", run(compiled), passes=False, said="[ja] says '無料'")
        compiled.write_bytes(f'"Done" = "Please subscribe";\n"{STATEMENT}" = "{STATEMENTS["ja"]}";\n'.encode())
        expect("compiled-text", run(compiled), passes=False, said="uses")
        expect("both", run(options.table, compiled), passes=False, said="uses")

        # An unreadable table is no pass.
        broken = root / "broken" / "TipJar.xcstrings"
        broken.parent.mkdir()
        broken.write_text("{", encoding="utf-8")
        expect("broken", run(broken), passes=False, said="cannot be read")
        expect("absent", run(root / "absent" / "TipJar.xcstrings"), passes=False, said="cannot be read")

    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
