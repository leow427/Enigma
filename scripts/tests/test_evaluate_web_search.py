"""Offline tests for scripts/evaluate-web-search.py (F29 CP7).

Run with: python3 -I -B -m unittest discover -s scripts/tests
"""

import contextlib
import importlib.util
import io
import json
import shutil
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURE = SCRIPTS / "tests" / "fixtures" / "web-search-eval"
sys.path.insert(0, str(SCRIPTS))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


evaluate = load("evaluate_web_search", "evaluate-web-search.py")
updater = evaluate.updater
REAL_LISTS = SCRIPTS.parent / "Enigma" / "Resources" / "SearchData"


def fnv_bytes(*domains):
    return b"".join(struct.pack("<Q", value) for value in sorted({updater.fnv1a64(d) for d in domains}))


class ListFixture(unittest.TestCase):
    """A temporary lists folder: the real public suffix list, and small test lists."""

    def make_lists(self, unsafe=("bad.example",), spam=("spam.example",), blocked=("blocked.example",),
                   authority=(".gov", "python.org", "!bad.gov")):
        folder = Path(tempfile.mkdtemp(prefix="web-eval-lists-"))
        self.addCleanup(shutil.rmtree, folder, True)
        shutil.copy(REAL_LISTS / "public_suffix_list.dat", folder / "public_suffix_list.dat")
        (folder / "unsafe.bin").write_bytes(fnv_bytes(*unsafe))
        (folder / "spam.bin").write_bytes(fnv_bytes(*spam))
        (folder / "enigma-blocked.txt").write_text("# test\n" + "\n".join(blocked) + "\n", encoding="utf-8")
        (folder / "authority.txt").write_text("# test\n" + "\n".join(authority) + "\n", encoding="utf-8")
        self.lists_folder = folder
        return evaluate.Lists(folder)


class QuerySetShapeTests(unittest.TestCase):
    def test_query_set_shape(self):
        entries = json.loads((SCRIPTS / "web-search-queries.json").read_text(encoding="utf-8"))
        self.assertEqual(evaluate.validate_questions(entries), [])
        self.assertEqual(len({entry["id"] for entry in entries}), 60)
        f30_ids = {f"web-{number:02d}" for number in range(1, 21)}
        self.assertTrue(f30_ids <= {entry["id"] for entry in entries})

    def test_query_set_shape_rejects_broken_entries(self):
        entries = json.loads((SCRIPTS / "web-search-queries.json").read_text(encoding="utf-8"))
        broken = [dict(entry) for entry in entries]
        broken[0] = {"id": broken[0]["id"], "category": "news", "question": "x"}
        problems = evaluate.validate_questions(broken)
        self.assertTrue(any("needs exactly one" in problem for problem in problems))
        duplicated = entries[:-1] + [dict(entries[0])]
        self.assertTrue(any("not unique" in problem for problem in evaluate.validate_questions(duplicated)))
        counts = [dict(entry) for entry in entries]
        counts[-1]["category"] = "news"
        self.assertTrue(any("news: expected 10" in problem for problem in evaluate.validate_questions(counts)))
        wrong_tool = [dict(entry) for entry in entries]
        wrong_tool[-1] = {"id": "weather-x", "category": "weather", "question": "x",
                          "tool": {"name": "find_places", "arguments": {"query": "x"}}}
        self.assertTrue(any("not the weather tool" in problem for problem in evaluate.validate_questions(wrong_tool)))


class FixtureMetricsTests(ListFixture):
    def setUp(self):
        self.lists = self.make_lists()
        self.questions = {entry["id"]: entry for entry in json.loads((FIXTURE / "questions.json").read_text())}
        self.runs = evaluate.index_runs(evaluate.read_jsonl(FIXTURE / "runs.jsonl"))

    def test_metrics_from_fixture_runs(self):
        # The real question set plus the fixture's four, so the 60 real questions without fixture runs
        # count as missing, once per style.
        questions = {**evaluate.load_questions(), **self.questions}
        measures = evaluate.measure(questions, self.runs, self.lists, {}, [])
        typed = measures["styles"]["typed"]
        # News and health have 2+ sources; facts and docs don't (one of them has only 1).
        self.assertEqual(typed["web"], 4)
        self.assertEqual(typed["twoSources"], 0.75)
        self.assertEqual(typed["pagesRead"], 1.0)
        # Three registrable domains: news (reuters, wikipedia, example.net) and health (cdc, example, bad.example).
        self.assertEqual(typed["variety"], 0.5)
        # Health: cdc.gov matches .gov; docs: docs.python.org matches python.org.
        self.assertEqual(typed["authority"], 1.0)
        self.assertEqual(typed["authorityQuestions"], 2)
        # Latencies: typed 2, 4, 7, 3; model 1, 1.5, 2.5, 9. Median 2.75; nearest-rank p90 is 9.
        self.assertEqual(measures["speedMedian"], 2.75)
        self.assertEqual(measures["speedP90"], 9.0)
        self.assertEqual(measures["speedRuns"], 8)
        # bad.example is on the test unsafe list, once per style.
        self.assertEqual(measures["bad"], 2)
        self.assertEqual(measures["missing"], 2 * 60)

    def test_blind_order_is_deterministic_and_balanced(self):
        ids = sorted(entry["id"] for entry in json.loads((SCRIPTS / "web-search-queries.json").read_text(encoding="utf-8")))
        for style in evaluate.STYLES:
            first = [evaluate.blind_first(qid, style) for qid in ids]
            self.assertEqual(first, [evaluate.blind_first(qid, style) for qid in ids])
            shown_first = first.count("onDevice")
            self.assertTrue(20 <= shown_first <= 40, (style, shown_first))
        self.assertTrue(set(evaluate.blind_first(qid, "typed") for qid in ids) == {"onDevice", "brave"})

    def test_judge_prompt_names_neither_provider(self):
        prompt = evaluate.judge_prompt("Q?", "first answer", ["a.example"], "second answer", ["b.example"])
        self.assertIn("=== Answer A ===", prompt)
        self.assertNotIn("onDevice", prompt)
        self.assertNotIn("brave", prompt.lower())

    def test_judge_verdicts_map_back_to_providers(self):
        def judge(prompt):
            # Always prefers answer A, whichever provider is shown as A.
            return '{"correctness": "A", "recency": "B", "sourcing": "tie", "overall": "A", "reason": "x"}'

        sides = {"onDevice": ("on", ["a.example"]), "brave": ("br", ["b.example"])}
        row = evaluate.judge_one("news-t1", "Q?", "typed", sides, judge)
        first = evaluate.blind_first("news-t1", "typed")
        second = "brave" if first == "onDevice" else "onDevice"
        self.assertEqual(row["shownAsA"], first)
        self.assertEqual(row["verdict"], {"correctness": first, "recency": second, "sourcing": "tie",
                                          "overall": first})

    def test_judge_failure_is_recorded_for_its_question(self):
        def judge(prompt):
            raise evaluate.search_judge.JudgeError("boom")

        row = evaluate.judge_one("news-t1", "Q?", "typed", {"onDevice": ("a", []), "brave": ("b", [])}, judge)
        self.assertIn("boom", row["error"])
        self.assertNotIn("verdict", row)


class JudgeRetryAndCacheTests(unittest.TestCase):
    def test_a_failed_judge_call_is_retried_once_then_missing(self):
        calls = []

        def flaky(prompt):
            calls.append(prompt)
            if len(calls) == 1:
                raise evaluate.search_judge.JudgeError("first try failed")
            return '{"correctness": "A", "recency": "A", "sourcing": "A", "overall": "A", "reason": "Brave is current."}'

        sides = {"onDevice": ("a", []), "brave": ("b", [])}
        row = evaluate.judge_one("news-t1", "Q?", "typed", sides, flaky)
        self.assertEqual(len(calls), 2)
        self.assertIn("verdict", row)
        self.assertEqual(row["reason"], "Brave is current.")

        always = lambda prompt: (_ for _ in ()).throw(evaluate.search_judge.JudgeError("down"))
        missing = evaluate.judge_one("news-t1", "Q?", "typed", sides, always)
        self.assertNotIn("verdict", missing)
        self.assertEqual(missing["error"], "down")

    def test_answer_key_depends_on_model_and_prompt(self):
        messages = [{"role": "user", "content": "x"}]
        self.assertEqual(evaluate.answer_key("m.gguf", messages), evaluate.answer_key("m.gguf", messages))
        self.assertNotEqual(evaluate.answer_key("m.gguf", messages), evaluate.answer_key("n.gguf", messages))
        self.assertNotEqual(evaluate.answer_key("m.gguf", messages),
                            evaluate.answer_key("m.gguf", [{"role": "user", "content": "y"}]))

    def test_fair_shares_water_fill_and_keep_short_sources_whole(self):
        self.assertEqual(evaluate.fair_shares(["x" * 10000, "y" * 100, "z" * 100], 1200), [1000, 100, 100])
        self.assertEqual(evaluate.fair_shares(["a" * 5000, "b" * 5000], 1000), [500, 500])
        self.assertEqual(evaluate.fair_shares(["a" * 30, "b" * 30], 1000), [30, 30])
        self.assertEqual(evaluate.fair_shares([], 1000), [])

    def test_build_messages_keeps_every_source_within_the_cap(self):
        evidence = [{"title": "Long", "url": "https://l.example", "text": "L" * 20000},
                    {"title": "Short", "url": "https://s.example", "text": "S" * 300}]
        content = evaluate.build_messages("Q?", evidence, limit=3000)[1]["content"]
        self.assertIn("[2] Short <https://s.example>", content)
        self.assertLessEqual(content.count("L"), 2700 + 1)

    def test_judge_resumes_and_only_judges_the_limit(self):
        questions = {entry["id"]: entry for entry in [
            {"id": "news-t1", "category": "news", "question": "Q1"},
            {"id": "facts-t1", "category": "facts", "question": "Q2"},
            {"id": "docs-t1", "category": "docs", "question": "Q3"}]}
        def record(provider, qid):
            return {"id": qid, "style": "typed", "provider": provider, "searched": True, "sources": [{"url": "https://a.example/x"}]}
        runs = {("typed", "onDevice"): {q: record("onDevice", q) for q in questions},
                ("typed", "brave"): {q: record("brave", q) for q in questions}}
        answers = {("typed", p, q): "text" for p in ("onDevice", "brave") for q in questions}
        folder = Path(tempfile.mkdtemp(prefix="web-eval-judge-"))
        self.addCleanup(shutil.rmtree, folder, True)
        calls = []
        def judge(prompt):
            calls.append(prompt)
            return '{"correctness": "tie", "recency": "tie", "sourcing": "tie", "overall": "tie", "reason": "same"}'
        first = evaluate.run_judge(questions, runs, answers, judge, 2, folder, limit=2)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(first), 2)
        second = evaluate.run_judge(questions, runs, answers, judge, 2, folder)
        self.assertEqual(len(calls), 3, "the pair judged early isn't judged again")
        self.assertEqual(len(second), 3)


class AdAndBlocklistTests(ListFixture):
    def test_ad_and_blocklist_detection(self):
        lists = self.make_lists()
        self.assertTrue(lists.listed("bad.example"))
        self.assertTrue(lists.listed("sub.bad.example"))
        self.assertTrue(lists.listed("spam.example"))
        self.assertTrue(lists.listed("blocked.example"))
        self.assertFalse(lists.listed("good.example"))
        self.assertFalse(lists.listed("notbad.example"))
        self.assertTrue(evaluate.is_ad("https://duckduckgo.com/y.js?ad_provider=x"))
        self.assertTrue(evaluate.is_ad("https://www.bing.com/aclick?ld=x"))
        self.assertFalse(evaluate.is_ad("https://www.reuters.com/world/a"))

    def test_authority_rules(self):
        lists = self.make_lists()
        self.assertTrue(lists.authoritative("www.cdc.gov"))
        self.assertTrue(lists.authoritative("docs.python.org"))
        self.assertFalse(lists.authoritative("example.org"))
        self.assertFalse(lists.authoritative("bad.gov"))


def base_measures():
    """Measures that pass both bars; each gate test moves one of them."""
    categories = {name: {"questions": count, "judged": count, "brave": 0, "onDevice": count, "tie": 0,
                         "braveShare": 0.0} for name, count in evaluate.CATEGORY_COUNTS.items()}
    style = {"web": 50, "twoSources": 1.0, "pagesRead": 1.0, "variety": 0.9, "authority": 0.9,
             "authorityQuestions": 18}
    judge = {name: {"judged": 60, "questions": 60, "equalOrBetter": 54, "share": 0.9, "categories": categories,
                    "recencyJudged": 20, "recency": 0.9} for name in ("typed", "model")}
    tools = [{"model": "gemma", "overall": 0.9, "right": 65, "total": 72, "newRight": 10, "newTotal": 12}]
    return {"missing": 0, "styles": {"typed": dict(style), "model": dict(style)}, "bad": 0, "bad_sources": [],
            "speedMedian": 2.0, "speedP90": 4.0, "speedRuns": 120, "judge": judge, "tools": tools}


def check(result, key):
    return next(item for item in result["checks"] if item["key"] == key)


class GateTests(unittest.TestCase):
    def test_both_bars_pass_on_the_passing_fixture(self):
        result = evaluate.gate(base_measures())
        self.assertEqual(result["original"], "pass")
        self.assertEqual(result["relaxed"], "pass")

    def test_gate_verdict(self):
        # Speed: 3.0 and 4.5 s pass the spec bar, 3.1 and 4.6 fail it but pass the relaxed one.
        measures = base_measures()
        measures["speedMedian"], measures["speedP90"] = 3.0, 4.5
        self.assertEqual(evaluate.gate(measures)["original"], "pass")
        measures["speedMedian"], measures["speedP90"] = 3.1, 4.6
        result = evaluate.gate(measures)
        self.assertEqual(result["original"], "fail")
        self.assertEqual(result["relaxed"], "pass")
        measures["speedMedian"], measures["speedP90"] = 5.0, 7.0
        self.assertEqual(evaluate.gate(measures)["relaxed"], "pass")
        measures["speedMedian"] = 5.01
        self.assertEqual(evaluate.gate(measures)["relaxed"], "fail")

        # Judge: 80% passes the spec bar, 79% fails it and passes the relaxed 65%.
        measures = base_measures()
        measures["judge"]["typed"]["share"] = 0.8
        self.assertEqual(evaluate.gate(measures)["original"], "pass")
        measures["judge"]["typed"]["share"] = 0.79
        result = evaluate.gate(measures)
        self.assertEqual((result["original"], result["relaxed"]), ("fail", "pass"))
        measures["judge"]["typed"]["share"] = 0.649
        self.assertEqual(evaluate.gate(measures)["relaxed"], "fail")

        # Recency: 70% on news and facts passes the relaxed gate, 69% doesn't.
        measures = base_measures()
        measures["judge"]["model"]["recency"] = 0.69
        self.assertEqual(evaluate.gate(measures)["relaxed"], "fail")
        measures["judge"]["model"]["recency"] = 0.7
        self.assertEqual(evaluate.gate(measures)["relaxed"], "pass")

        # Tool choice: 0.90 overall and 10 of 12 new prompts pass; 0.89 or 9 of 12 fail.
        measures = base_measures()
        measures["tools"][0]["overall"] = 0.89
        self.assertEqual(evaluate.gate(measures)["relaxed"], "fail")
        measures = base_measures()
        measures["tools"][0]["newRight"] = 9
        self.assertEqual(evaluate.gate(measures)["original"], "fail")
        self.assertEqual(evaluate.gate(measures)["relaxed"], "fail")

        # Two sources: 95% passes, 94% fails.
        measures = base_measures()
        measures["styles"]["model"]["twoSources"] = 0.94
        self.assertEqual(evaluate.gate(measures)["relaxed"], "fail")

    def test_authority_and_variety_are_not_relaxed_checks(self):
        measures = base_measures()
        measures["styles"]["typed"]["authority"] = 0.5
        measures["styles"]["typed"]["variety"] = 0.5
        result = evaluate.gate(measures)
        self.assertEqual(result["relaxed"], "pass")
        self.assertEqual(result["original"], "fail")
        self.assertIsNone(check(result, "authority:typed")["relaxed"])

    def test_bad_source_fails_both(self):
        measures = base_measures()
        measures["bad"] = 1
        result = evaluate.gate(measures)
        self.assertEqual((result["original"], result["relaxed"]), ("fail", "fail"))

    def test_missing_runs_are_incomplete_not_pass(self):
        measures = base_measures()
        measures["judge"]["typed"]["share"] = None
        result = evaluate.gate(measures)
        self.assertEqual(result["original"], "incomplete")
        self.assertEqual(result["relaxed"], "incomplete")
        self.assertIsNone(check(result, "judgeShare:typed")["orig"])

    def test_tool_eval_missing_is_not_run(self):
        measures = base_measures()
        measures["tools"] = []
        result = evaluate.gate(measures)
        self.assertEqual(result["original"], "incomplete")
        self.assertIsNone(check(result, "toolShare")["relaxed"])


class ReportTests(ListFixture):
    def test_on_device_only_reports_metrics_without_judge(self):
        self.make_lists()
        folder = Path(tempfile.mkdtemp(prefix="web-eval-run-"))
        self.addCleanup(shutil.rmtree, folder, True)
        shutil.copy(FIXTURE / "runs.jsonl", folder / "runs.jsonl")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = evaluate.main([str(folder), "--no-judge", "--lists", str(self.lists_folder)])
        self.assertEqual(status, 0)
        report = (folder / "report.md").read_text(encoding="utf-8")
        self.assertIn("Median", report)
        self.assertIn("## Judge, per category", report)
        self.assertIn("not run", report)
        self.assertIn(str(folder / "report.md"), output.getvalue())
        self.assertFalse((folder / "spot-check.md").exists())

    def test_answers_are_not_in_the_report(self):
        folder = Path(tempfile.mkdtemp(prefix="web-eval-run-"))
        self.addCleanup(shutil.rmtree, folder, True)
        shutil.copy(FIXTURE / "runs.jsonl", folder / "runs.jsonl")
        (folder / "answers.jsonl").write_text(json.dumps({"id": "news-t1", "style": "typed", "provider": "onDevice",
                                                          "answer": "SECRET ANSWER TEXT"}) + "\n", encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            evaluate.main([str(folder), "--no-judge"])
        self.assertNotIn("SECRET ANSWER TEXT", (folder / "report.md").read_text(encoding="utf-8"))

    def test_answer_prompt_carries_the_evidence(self):
        messages = evaluate.build_messages("Q?", [{"title": "T", "url": "https://u.example", "text": "Passage."}])
        self.assertEqual(messages[0]["role"], "system")
        self.assertIn("[1] T <https://u.example>", messages[1]["content"])
        self.assertIn("Question: Q?", messages[1]["content"])

    def test_percentile_is_nearest_rank(self):
        self.assertEqual(evaluate.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9)
        self.assertEqual(evaluate.percentile([2.0], 0.9), 2.0)
        self.assertIsNone(evaluate.percentile([], 0.9))


if __name__ == "__main__":
    unittest.main()
