"""Offline tests for scripts/evaluate-native-search.py and scripts/search_judge.py.

Run with: python3 -I -B -m unittest discover -s scripts/tests
"""

import importlib.util
import io
import json
import random
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


evaluate = load("evaluate_native_search", "evaluate-native-search.py")
judge_module = evaluate.search_judge  # the same module the script imports

# F30's 20 questions; F29 CP7 adds 40 more to the same file, which this comparison doesn't use.
QUESTIONS = [entry for entry in json.loads((SCRIPTS / "web-search-queries.json").read_text(encoding="utf-8"))
             if entry["id"].startswith("web-")]


def record(question, backend, searched=True, sources=2, unsafe=0, error=None, first=2.0, total=5.0, answer=None):
    return {
        "id": question["id"], "category": question["category"], "route": "claude-code", "model": "sonnet",
        "backend": backend, "searched": searched,
        "sources": [{"title": f"Page {n}", "url": f"https://example.com/{backend}/{n}"} for n in range(sources)],
        "unsafeSources": unsafe, "firstTextSeconds": first, "totalSeconds": total,
        "answer": answer if answer is not None else f"{backend} answer to {question['id']}", "error": error,
    }


def write_folder(root, route, backend, records):
    folder = Path(root) / route / backend
    folder.mkdir(parents=True, exist_ok=True)
    for entry in records:
        (folder / f"{entry['id']}.json").write_text(json.dumps(entry), encoding="utf-8")


FAKE_JUDGE = r'''
import json, sys
prompt = sys.stdin.read()
# Prefer the answer whose text says "provider", wherever it was shown.
a = prompt.split("=== Answer A ===")[1].split("=== Answer B ===")[0]
pick = "A" if "provider answer" in a else "B"
print("Some thinking first. {not json}")
print(json.dumps({"correctness": pick, "recency": "tie", "sourcing": pick, "overall": pick, "reason": "fake"}))
'''


CHATGPT = "chatgpt-codex:gpt-5.6-luna"
TIE = json.dumps({"correctness": "tie", "recency": "tie", "sourcing": "tie", "overall": "tie"})


def eval_report(passes=True, search=14, none=15, provider_search=True, route="claude-code:sonnet"):
    """An F32 eval report as NativeToolsEvalTests writes it, with the fields the gate reads."""
    return {"route": route, "passes": passes, "providerSearch": provider_search, "overall": {"right": 58, "total": 60},
            "categories": {"web_search": {"right": search, "total": 15}, "none": {"right": none, "total": 15}}}


class SearchJudgeTests(unittest.TestCase):
    def test_order_is_randomized_and_mapped_back(self):
        prompts = []

        def judge(prompt):
            prompts.append(prompt)
            return json.dumps({"correctness": "A", "recency": "B", "sourcing": "tie", "overall": "A", "reason": "x"})

        orders = set()
        for seed in range(20):
            result = judge_module.judge_pair("Q?", ("provider", "first", []), ("brave", "second", []), judge,
                                             random.Random(seed))
            orders.add(tuple(result["order"]))
            # A is whichever was shown first; the verdict names it, never the letter.
            self.assertEqual(result["verdict"]["correctness"], result["order"][0])
            self.assertEqual(result["verdict"]["recency"], result["order"][1])
            self.assertEqual(result["verdict"]["sourcing"], "tie")
        self.assertEqual(orders, {("provider", "brave"), ("brave", "provider")}, "both orders occur")

    def test_prompt_is_blind(self):
        prompt = judge_module.prompt_for("Q?", "one", [{"title": "T", "url": "https://a.example/"}], "two", [])
        for word in ("provider", "brave", "Brave", "ChatGPT", "Claude", "Codex"):
            self.assertNotIn(word, prompt)
        self.assertIn("T <https://a.example/>", prompt)
        self.assertIn("(none)", prompt)

    def test_parse_verdict_takes_the_last_complete_object(self):
        text = 'Like {"overall": "A"} but finally {"correctness": "B", "recency": "tie", "sourcing": "A", "overall": "B"}'
        self.assertEqual(judge_module.parse_verdict(text),
                         {"correctness": "B", "recency": "tie", "sourcing": "A", "overall": "B"})
        braces = '{"correctness": "A", "recency": "A", "sourcing": "A", "overall": "A", "reason": "A shows the {strict} flag"}'
        self.assertEqual(judge_module.parse_verdict("Verdict: " + braces + " done")["overall"], "A",
                         "braces inside a string don't hide the verdict")
        for bad in ("no json", '{"correctness": "C", "recency": "A", "sourcing": "A", "overall": "A"}'):
            with self.assertRaises(judge_module.JudgeError):
                judge_module.parse_verdict(bad)

    def test_command_judge_reads_stdin_and_fails_loudly(self):
        echo = judge_module.command_judge([sys.executable, "-I", "-c", "import sys; print(sys.stdin.read().upper())"])
        self.assertEqual(echo("hi").strip(), "HI")
        failing = judge_module.command_judge([sys.executable, "-I", "-c", "raise SystemExit(3)"])
        with self.assertRaises(judge_module.JudgeError):
            failing("hi")

    def test_default_judge_is_claude_code_without_tools(self):
        command = judge_module.claude_code_command("sonnet")
        self.assertEqual(command[:2], ["claude", "-p"])
        self.assertEqual(command[command.index("--tools") + 1], "")
        self.assertIn("--strict-mcp-config", command)
        self.assertEqual(command[-2:], ["--model", "sonnet"])


class EvaluateNativeSearchTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.folder = self.root.name

    def fake_judge(self):
        script = Path(self.folder) / "fake_judge.py"
        script.write_text(FAKE_JUDGE, encoding="utf-8")
        return judge_module.command_judge([sys.executable, "-I", "-B", str(script)])

    def test_metrics_and_gate_without_brave(self):
        records = [record(q, "provider") for q in QUESTIONS]
        records[0] = record(QUESTIONS[0], "provider", searched=False, sources=0, first=None)
        records[1] = record(QUESTIONS[1], "provider", sources=1, error="Timed out")
        write_folder(self.folder, "claude-code", "provider", records)
        summary = evaluate.summarize(self.folder)
        entry = summary["claude-code"]
        self.assertEqual(entry["provider"]["questions"], 20)
        self.assertEqual(entry["provider"]["searched"], 19)
        self.assertEqual(entry["provider"]["twoOrMoreSources"], 18)
        self.assertEqual(entry["provider"]["errors"], 1)
        self.assertEqual(entry["provider"]["medianFirstTextSeconds"], 2.0, "a run with no text is left out")
        self.assertIsNone(entry["judge"])
        self.assertEqual(entry["gate"], {"eval": "not run", "searched": "pass", "twoOrMoreSources": "pass",
                                         "noUnsafeSource": "pass", "judge": "not run", "passes": False})
        self.assertNotIn("brave", entry)

    def test_gate_boundaries(self):
        def gate_for(searched, sourced, unsafe=0):
            records = [record(q, "provider", searched=i < searched, sources=2 if i < sourced else 1, unsafe=unsafe if i == 0 else 0)
                       for i, q in enumerate(QUESTIONS)]
            folder = tempfile.mkdtemp(dir=self.folder)
            write_folder(folder, "chatgpt-codex", "provider", records)
            return evaluate.summarize(folder, eval_reports={"chatgpt-codex": eval_report(route=CHATGPT)})[
                "chatgpt-codex"]["gate"]

        self.assertEqual(gate_for(18, 18)["searched"], "pass")
        self.assertEqual(gate_for(17, 18)["searched"], "fail")
        self.assertEqual(gate_for(18, 17)["twoOrMoreSources"], "fail")
        self.assertEqual(gate_for(20, 20, unsafe=1)["noUnsafeSource"], "fail")
        self.assertEqual(gate_for(18, 18)["eval"], "pass")

    def test_eval_check_needs_provider_search_and_the_category_floors(self):
        write_folder(self.folder, "chatgpt-codex", "provider", [record(q, "provider") for q in QUESTIONS])

        def check(report, baselines=None, route="chatgpt-codex"):
            report = {**report, "route": f"{route}:model"}  # the route's own report
            return evaluate.summarize(self.folder, eval_reports={route: report}, baselines=baselines)[route]["gate"]["eval"]

        # F32 measured ChatGPT at 14/15 search and 15/15 none, so the floors are 13 and 14.
        self.assertEqual(check(eval_report(search=13, none=14)), "pass")
        self.assertEqual(check(eval_report(search=12, none=15)), "fail", "search below F32's minus one")
        self.assertEqual(check(eval_report(search=15, none=13)), "fail", "none below F32's minus one")
        self.assertEqual(check(eval_report(passes=False)), "fail")
        self.assertEqual(check(eval_report(provider_search=False)), "fail", "a stub-search report doesn't count")
        self.assertEqual(check(eval_report(), baselines={"chatgpt-codex": {"web_search": 15, "none": 15}}), "pass")
        self.assertEqual(check(eval_report(search=13), baselines={"chatgpt-codex": {"web_search": 15, "none": 15}}),
                         "fail", "--eval-baseline replaces the built-in counts")
        # Another route's report never counts for this one.
        self.assertEqual(evaluate.summarize(self.folder, eval_reports={"chatgpt-codex": eval_report()})[
            "chatgpt-codex"]["gate"]["eval"], "fail", "a Claude Code report given for ChatGPT")
        # A route with no baseline can't pass.
        write_folder(self.folder, "openai", "provider", [record(q, "provider") for q in QUESTIONS])
        self.assertEqual(check(eval_report(), route="openai"), "fail")
        self.assertEqual(check(eval_report(), baselines={"openai": {"web_search": 14, "none": 15}}, route="openai"), "pass")

    def test_a_partial_folder_is_incomplete_not_passing(self):
        write_folder(self.folder, "claude-code", "provider", [record(q, "provider") for q in QUESTIONS[:3]])
        write_folder(self.folder, "claude-code", "brave", [record(q, "brave") for q in QUESTIONS[:3]])
        entry = evaluate.summarize(self.folder, judge=lambda _: TIE, eval_reports={"claude-code": eval_report()})[
            "claude-code"]
        self.assertEqual(entry["questionSet"], 20)
        self.assertEqual(entry["gate"], {"eval": "pass", "searched": "incomplete", "twoOrMoreSources": "incomplete",
                                         "noUnsafeSource": "incomplete", "judge": "incomplete", "passes": False})
        self.assertEqual(entry["judge"]["providerOrTieShare"], 0.15, "the share is over the whole question set")

    def test_judge_runs_blind_on_pairs_only(self):
        write_folder(self.folder, "claude-code", "provider", [record(q, "provider") for q in QUESTIONS])
        # Brave answered all but the last question; that one isn't judged.
        write_folder(self.folder, "claude-code", "brave", [record(q, "brave", sources=3) for q in QUESTIONS[:-1]])
        summary = evaluate.summarize(self.folder, judge=self.fake_judge(),
                                     eval_reports={"claude-code": eval_report(passes=False)}, rng=random.Random(7))
        entry = summary["claude-code"]
        self.assertEqual(entry["judge"]["judged"], 19)
        self.assertEqual(entry["judge"]["overall"], {"provider": 19, "brave": 0, "tie": 0})
        self.assertEqual(entry["judge"]["recency"], {"provider": 0, "brave": 0, "tie": 19})
        orders = {tuple(judgment["order"]) for judgment in entry["judgments"]}
        self.assertEqual(len(orders), 2, "the A/B order varies")
        self.assertEqual(entry["gate"]["judge"], "incomplete", "one question has no pair")
        self.assertEqual(entry["gate"]["eval"], "fail")
        self.assertFalse(entry["gate"]["passes"])
        self.assertEqual(entry["brave"]["meanSources"], 3.0)

    def judge_with_overall(self, verdicts):
        """A judge that gives each question's overall verdict, by id, mapped to whichever letter that answer has."""
        def judge(prompt):
            question_id = next(q["id"] for q in QUESTIONS if q["question"] in prompt)
            want = verdicts[question_id]
            if want == "tie":
                pick = "tie"
            else:
                a = prompt.split("=== Answer A ===")[1].split("=== Answer B ===")[0]
                pick = "A" if f"{want} answer" in a else "B"
            return json.dumps({"correctness": "tie", "recency": "tie", "sourcing": "tie", "overall": pick})
        return judge

    def test_judge_bar_counts_ties_and_is_inclusive(self):
        write_folder(self.folder, "claude-code", "provider", [record(q, "provider") for q in QUESTIONS])
        write_folder(self.folder, "claude-code", "brave", [record(q, "brave") for q in QUESTIONS])
        ids = [q["id"] for q in QUESTIONS]

        def judged(ties, provider, brave):
            verdicts = dict(zip(ids, ["tie"] * ties + ["provider"] * provider + ["brave"] * brave))
            return evaluate.summarize(self.folder, judge=self.judge_with_overall(verdicts), rng=random.Random(5))[
                "claude-code"]

        at_bar = judged(12, 4, 4)
        self.assertEqual(at_bar["judge"]["overall"], {"provider": 4, "brave": 4, "tie": 12})
        self.assertEqual(at_bar["judge"]["providerOrTie"], 16)
        self.assertEqual(at_bar["judge"]["providerOrTieShare"], 0.8)
        self.assertEqual(at_bar["gate"]["judge"], "pass", "16 of 20, ties counted, is exactly the bar")
        below = judged(11, 4, 5)
        self.assertEqual(below["judge"]["providerOrTieShare"], 0.75)
        self.assertEqual(below["gate"]["judge"], "fail")
        self.assertEqual(judged(0, 0, 20)["gate"]["judge"], "fail")

    def test_a_failed_judgment_is_recorded_and_the_rest_still_run(self):
        write_folder(self.folder, "claude-code", "provider", [record(q, "provider") for q in QUESTIONS])
        write_folder(self.folder, "claude-code", "brave", [record(q, "brave") for q in QUESTIONS])

        def judge(prompt):
            if QUESTIONS[3]["question"] in prompt:
                raise judge_module.JudgeError("usage limit")
            return TIE

        entry = evaluate.summarize(self.folder, judge=judge, rng=random.Random(2))["claude-code"]
        self.assertEqual(entry["judge"]["judged"], 19)
        self.assertEqual(entry["judge"]["failed"], 1)
        self.assertIn({"id": "web-04", "error": "usage limit"}, entry["judgments"])
        self.assertEqual(entry["gate"]["judge"], "incomplete")

    def test_main_writes_summary_without_answers(self):
        write_folder(self.folder, "claude-code", "provider",
                     [record(q, "provider", answer="provider answer, SECRET ANSWER TEXT") for q in QUESTIONS])
        write_folder(self.folder, "claude-code", "brave", [record(q, "brave", answer="brave answer, OTHER ANSWER TEXT") for q in QUESTIONS])
        report = Path(self.folder) / "report.json"
        report.write_text(json.dumps(eval_report()), encoding="utf-8")
        script = Path(self.folder) / "fake_judge.py"
        script.write_text(FAKE_JUDGE, encoding="utf-8")
        output = io.StringIO()
        with redirect_stdout(output):
            status = evaluate.main([self.folder, "--eval", f"claude-code={report}", "--seed", "3",
                                    "--judge-command", f"{sys.executable} -I -B {script}"])
        self.assertEqual(status, 0)
        summary_text = (Path(self.folder) / "summary.json").read_text(encoding="utf-8")
        for text in (summary_text, output.getvalue()):
            self.assertNotIn("ANSWER TEXT", text)
            self.assertNotIn("https://example.com", text)
        summary = json.loads(summary_text)
        self.assertTrue(summary["claude-code"]["gate"]["passes"])
        self.assertIn("| claude-code | 58/60 | 20/20 | passes", output.getvalue())

    def test_main_writes_the_summary_when_the_judge_fails(self):
        write_folder(self.folder, "claude-code", "provider", [record(q, "provider") for q in QUESTIONS])
        write_folder(self.folder, "claude-code", "brave", [record(q, "brave") for q in QUESTIONS])
        with redirect_stdout(io.StringIO()):
            status = evaluate.main([self.folder, "--judge-command", f"{sys.executable} -I -c 'raise SystemExit(2)'"])
        self.assertEqual(status, 1)
        summary = json.loads((Path(self.folder) / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(summary["claude-code"]["judge"]["failed"], 20)
        self.assertEqual(summary["claude-code"]["gate"]["judge"], "incomplete")

    def test_main_fails_without_runs_and_rejects_bad_arguments(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(evaluate.main([self.folder, "--no-judge"]), 1)
        for bad in (["--eval", "claude-code"], ["--eval-baseline", "claude-code"],
                    ["--eval-baseline", "claude-code=web_search"]):
            with self.assertRaises(SystemExit):
                evaluate.main([self.folder, "--no-judge", *bad])
        self.assertEqual(evaluate.parse_baselines(["openai=web_search:14,none:15"]),
                         {"openai": {"web_search": 14, "none": 15}})


if __name__ == "__main__":
    unittest.main()
