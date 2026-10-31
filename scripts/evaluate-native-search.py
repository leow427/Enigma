#!/usr/bin/env python3
"""Scores F30's provider-search comparison and applies its quality gate.

Reads the folder `NativeWebSearchEvaluationTests/testCompare` writes
(`<folder>/<route>/<backend>/<id>.json`, backend `provider` or `brave`), and:

- counts, per route and backend, the questions answered with a search, with at
  least two sources, with an unsafe source, and with an error, and the median
  times to the first text and to the end;
- where a question has both a provider and a Brave answer, asks a cloud
  model's CLI for a blind side-by-side judgment (`search_judge.py`);
- applies the gate per route, over the whole question set: the F32 eval
  (from `--eval`) ran with provider search, passes, and keeps its search and
  none categories at F32's measured counts minus one at most (`F32_BASELINE`,
  or `--eval-baseline`); it searched on 90% or more of the questions, 2 or more
  sources on 90% or more, no unsafe source, and the judge prefers provider
  search or calls a tie on 80% or more. A check with missing runs or
  judgments is `incomplete`, never `pass`.

Writes `summary.json` to the folder and prints a Markdown summary. Neither
holds an answer or page text.

    python3 -I -B scripts/evaluate-native-search.py <folder> \\
      [--eval claude-code=<report.json>] [--eval-baseline claude-code=web_search:15,none:15] \\
      [--judge-model sonnet] [--no-judge]

Standard library only.
"""

import argparse
import json
import math
import random
import shlex
import statistics
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import search_judge  # noqa: E402

SEARCHED_SHARE = 0.9
SOURCED_SHARE = 0.9
MINIMUM_SOURCES = 2
JUDGE_SHARE = 0.8
# F32 CP5's measured right counts (2026-10-28, stub search) for the categories
# the spec's gate keeps; a provider-search eval may be at most one below each.
# F32 measured ChatGPT with gpt-5.6-luna and Claude Code with sonnet; another
# model's eval should bring its own counts with --eval-baseline.
F32_BASELINE = {
    "chatgpt-codex": {"web_search": 14, "none": 15},
    "claude-code": {"web_search": 15, "none": 15},
}


def load_runs(folder):
    """{route: {backend: {id: record}}} from the comparison folder."""
    runs = {}
    for path in sorted(Path(folder).glob("*/*/*.json")):
        record = json.loads(path.read_text(encoding="utf-8"))
        route, backend = path.parent.parent.name, path.parent.name
        runs.setdefault(route, {}).setdefault(backend, {})[record["id"]] = record
    return runs


QUESTIONS = Path(__file__).resolve().parent / "web-search-queries.json"


def question_set():
    """{id: question} for F30's 20 questions (`web-` IDs). F29 CP7 adds 40 more to the same file,
    which F29's `evaluate-web-search.py` reads; the F30 comparison keeps its own set."""
    return {entry["id"]: entry["question"] for entry in json.loads(QUESTIONS.read_text(encoding="utf-8"))
            if entry["id"].startswith("web-")}


def median(values):
    values = [value for value in values if value is not None]
    return round(statistics.median(values), 1) if values else None


def metrics(records):
    records = list(records)
    return {
        "questions": len(records),
        "searched": sum(1 for record in records if record["searched"]),
        "twoOrMoreSources": sum(1 for record in records if len(record["sources"]) >= MINIMUM_SOURCES),
        "unsafeSources": sum(record["unsafeSources"] for record in records),
        "errors": sum(1 for record in records if record.get("error")),
        "meanSources": round(statistics.mean(len(record["sources"]) for record in records), 1) if records else 0,
        "medianFirstTextSeconds": median(record.get("firstTextSeconds") for record in records),
        "medianTotalSeconds": median(record.get("totalSeconds") for record in records),
    }


def judge_route(route_runs, questions, judge, rng):
    """Blind judgments for every question with both a provider and a Brave answer. A judge that
    fails on one question is recorded for it, and the rest still run."""
    provider, brave = route_runs.get("provider", {}), route_runs.get("brave", {})
    judgments = []
    for question_id in sorted(set(provider) & set(brave) & set(questions)):
        first, second = provider[question_id], brave[question_id]
        try:
            result = search_judge.judge_pair(
                questions[question_id],
                ("provider", first["answer"], first["sources"]),
                ("brave", second["answer"], second["sources"]),
                judge, rng)
        except search_judge.JudgeError as error:
            result = {"error": str(error)}
        judgments.append({"id": question_id, **result})
    return judgments


def judge_summary(judgments, question_count):
    """Counts over the judged pairs; the share is over the whole question set."""
    judged = [judgment for judgment in judgments if "verdict" in judgment]
    summary = {"judged": len(judged), "failed": len(judgments) - len(judged), "questions": question_count}
    for criterion in search_judge.CRITERIA:
        verdicts = [judgment["verdict"][criterion] for judgment in judged]
        summary[criterion] = {label: verdicts.count(label) for label in ("provider", "brave", "tie")}
    summary["providerOrTie"] = sum(1 for judgment in judged if judgment["verdict"]["overall"] != "brave")
    summary["providerOrTieShare"] = round(summary["providerOrTie"] / question_count, 3) if question_count else 0
    return summary


def eval_check(report, route, baseline):
    """The F32 eval's part of the gate: this route's report (`<route>:<model>`), run with provider
    search, passing, and within one of F32's measured search and none counts."""
    if report is None:
        return "not run"
    if str(report.get("route", "")).split(":")[0] != route:
        return "fail"
    if report.get("providerSearch") is not True or not baseline:
        return "fail"
    categories = report.get("categories", {})
    floors_met = all(categories.get(name, {}).get("right", -1) >= count - 1 for name, count in baseline.items())
    return "pass" if report.get("passes") and floors_met else "fail"


def gate(route, provider_metrics, question_count, judged, eval_report, baseline):
    """Each criterion as `pass`, `fail`, `incomplete` or `not run`, over the whole question set; the
    route ships only if every one passes."""
    complete = question_count > 0 and provider_metrics["questions"] == question_count

    def share_check(count, share):
        if count >= math.ceil(share * question_count) and question_count:
            return "pass"
        return "fail" if complete else "incomplete"

    if judged is None:
        judge = "not run"
    elif judged["judged"] < question_count:
        judge = "incomplete"
    else:
        judge = "pass" if judged["providerOrTieShare"] >= JUDGE_SHARE else "fail"
    checks = {
        "eval": eval_check(eval_report, route, baseline),
        "searched": share_check(provider_metrics["searched"], SEARCHED_SHARE),
        "twoOrMoreSources": share_check(provider_metrics["twoOrMoreSources"], SOURCED_SHARE),
        "noUnsafeSource": "fail" if provider_metrics["unsafeSources"] else ("pass" if complete else "incomplete"),
        "judge": judge,
    }
    checks["passes"] = all(value == "pass" for value in checks.values())
    return checks


def summarize(folder, judge=None, eval_reports=None, baselines=None, rng=None, questions=None):
    """Per route: each backend's metrics over the question set, the judgments, and the gate. The
    judge runs only where Brave answers exist."""
    eval_reports = eval_reports or {}
    baselines = {**F32_BASELINE, **(baselines or {})}
    rng = rng or random.Random()
    questions = questions if questions is not None else question_set()
    summary = {}
    for route, route_runs in sorted(load_runs(folder).items()):
        route_runs = {backend: {key: record for key, record in records.items() if key in questions}
                      for backend, records in route_runs.items()}
        entry = {backend: metrics(records.values()) for backend, records in sorted(route_runs.items())}
        entry["questionSet"] = len(questions)
        judged = None
        entry["judgments"] = []
        if judge and route_runs.get("brave"):
            entry["judgments"] = judge_route(route_runs, questions, judge, rng)
            judged = judge_summary(entry["judgments"], len(questions))
        eval_report = eval_reports.get(route)
        entry["eval"] = None if eval_report is None else {
            "overall": eval_report["overall"], "categories": eval_report["categories"], "passes": eval_report["passes"],
            "providerSearch": eval_report.get("providerSearch", False), "baseline": baselines.get(route)}
        entry["judge"] = judged
        entry["gate"] = gate(route, entry.get("provider", metrics([])), len(questions), judged, eval_report, baselines.get(route))
        summary[route] = entry
    return summary


def markdown(summary):
    lines = ["| Route | Backend | Searched | 2+ sources | Unsafe | Errors | Mean sources | First text (median s) "
             "| Total (median s) |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for route, entry in summary.items():
        for backend in ("provider", "brave"):
            if backend not in entry:
                continue
            m = entry[backend]
            lines.append(f"| {route} | {backend} | {m['searched']}/{m['questions']} | {m['twoOrMoreSources']}/{m['questions']} "
                         f"| {m['unsafeSources']} | {m['errors']} | {m['meanSources']} | {m['medianFirstTextSeconds']} "
                         f"| {m['medianTotalSeconds']} |")
    lines += ["", "| Route | Eval | Judge (provider or tie) | Gate |", "| --- | --- | --- | --- |"]
    for route, entry in summary.items():
        evaluation = entry["eval"]
        eval_text = "not run" if evaluation is None else f"{evaluation['overall']['right']}/{evaluation['overall']['total']}"
        judge = entry["judge"]
        judge_text = "not run" if judge is None else f"{judge['providerOrTie']}/{judge['questions']}"
        checks = ", ".join(f"{name} {value}" for name, value in entry["gate"].items() if name != "passes")
        lines.append(f"| {route} | {eval_text} | {judge_text} | {'passes' if entry['gate']['passes'] else 'does not pass'} "
                     f"({checks}) |")
    return "\n".join(lines)


def parse_baselines(values):
    """`<route>=<category>:<count>,…`, such as `claude-code=web_search:15,none:15`."""
    baselines = {}
    for value in values or []:
        route, separator, pairs = value.partition("=")
        try:
            baselines[route] = {name: int(count) for name, count in (pair.split(":") for pair in pairs.split(","))}
        except ValueError:
            raise SystemExit(f"--eval-baseline takes <route>=<category>:<count>,…, not {value!r}.") from None
        if not separator:
            raise SystemExit(f"--eval-baseline takes <route>=<category>:<count>,…, not {value!r}.")
    return baselines


def parse_eval(values):
    reports = {}
    for value in values or []:
        route, separator, path = value.partition("=")
        if not separator:
            raise SystemExit(f"--eval takes <route>=<report.json>, not {value!r}.")
        reports[route] = json.loads(Path(path).read_text(encoding="utf-8"))
    return reports


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("folder", help="The folder NativeWebSearchEvaluationTests wrote")
    parser.add_argument("--eval", action="append", metavar="ROUTE=REPORT",
                        help="The F32 eval's report.json for a route, such as claude-code=/path/report.json")
    parser.add_argument("--eval-baseline", action="append", metavar="ROUTE=CATEGORY:COUNT,...",
                        help="F32's measured counts for a route not in F32_BASELINE, such as "
                             "claude-code=web_search:15,none:15")
    parser.add_argument("--judge-command", help="The judge command, reading the prompt on standard input "
                                                "(default: Claude Code)")
    parser.add_argument("--judge-model", help="Claude Code's model for the judge, such as sonnet")
    parser.add_argument("--no-judge", action="store_true", help="Skip the side-by-side judgment")
    parser.add_argument("--seed", type=int, help="Seed for the A/B order, to repeat a run")
    args = parser.parse_args(argv)

    judge = None
    if not args.no_judge:
        command = shlex.split(args.judge_command) if args.judge_command else search_judge.claude_code_command(args.judge_model)
        judge = search_judge.command_judge(command)
    summary = summarize(args.folder, judge=judge, eval_reports=parse_eval(args.eval),
                        baselines=parse_baselines(args.eval_baseline), rng=random.Random(args.seed))
    (Path(args.folder) / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(markdown(summary))
    return 0 if summary and all(entry["gate"]["passes"] for entry in summary.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
