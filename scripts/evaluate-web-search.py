#!/usr/bin/env python3
"""Scores on-device web search against Brave (F29 CP7), and applies the quality gate.

Reads one run folder (outside the repository), written by `WebSearchEvaluationTests`:

- `runs.jsonl`: one line per question, style (`typed` or `model`) and provider (`onDevice` or
  `brave`): `id`, `category`, `style`, `provider`, `route`, `latencyMs`, `error`, `sources`
  (`url`, `kind`, `title`, `site`, `published`) and, for on-device, `trace`;
- `contexts.jsonl`: the evidence each provider's answer is grounded on (`id`, `style`,
  `provider`, `evidence`: a list of `title`, `url`, `kind` and `text`);
- `answers.jsonl` (optional, written by this script with `--answer`): `id`, `style`,
  `provider`, `answer`;
- `tool-*.json` (optional): the tool-use eval reports, passed with `--tool-eval`.

It writes, into the same folder: `judgments.jsonl` (the blind judge's verdicts), `report.md`
(metrics, gate, tuning-ready numbers, domains), `spot-check.md` (15 blind pairs, no verdicts),
`spot-check-key.json` (the answer order and the judge's verdict, for the owner's comparison),
and `summary.json`. None of them goes into the repository.

    python3 -I -B scripts/evaluate-web-search.py <folder> \\
      [--answer typed=<model.gguf> --answer model=<model.gguf> --llama-server <binary>] \\
      [--judge-command "claude -p --model sonnet"] [--no-judge] \\
      [--lists Enigma/Resources/SearchData] [--tool-eval <report.json> ...]

The judge sees two answers labelled A and B, each with its source domains, and the rubric. The
order is decided by a hash of the question ID and the style, so it's deterministic and balanced.
The judge's prompt never names either provider. Standard library only.
"""

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import math
import random
import re
import shlex
import socket
import statistics
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import search_judge  # noqa: E402

REPO = SCRIPTS.parent
QUESTIONS = SCRIPTS / "web-search-queries.json"
DEFAULT_LISTS = REPO / "Enigma" / "Resources" / "SearchData"
DEFAULT_JUDGE_MODEL = "sonnet"
SPOT_CHECK_SEED = 20261030
SPOT_CHECK_PAIRS = 15

STYLES = ("typed", "model")
PROVIDERS = ("onDevice", "brave")
JUDGE_LABELS = ("onDevice", "brave", "tie")

# The spec's counts (§ Quality gate). F30's 20 keep their IDs; the rest are CP7's.
CATEGORY_COUNTS = {"news": 10, "facts": 10, "docs": 10, "health-finance": 8, "reviews": 6, "places": 6,
                   "weather": 4, "encyclopedic": 6}
TOOL_CATEGORIES = ("places", "weather")
TOOL_NAMES = {"places": "find_places", "weather": "get_weather"}
TOOL_ARGUMENTS = {"find_places": {"query", "area"}, "get_weather": {"place"}}
AUTHORITY_CATEGORIES = ("health-finance", "docs")
RECENCY_CATEGORIES = ("news", "facts")
AD_MARKERS = ("duckduckgo.com/y.js", "bing.com/aclick", "googleadservices", "doubleclick")
PAGE_KINDS = ("article", "wikipedia")

# The bars. `orig` is the spec's original bar; `relaxed` is the owner's relaxed gate (D3). A check
# with None is not part of that bar. Speed and the judge's share differ between the two bars, so
# they have a check per bar.
BARS = {
    "clean": {"orig": 0, "relaxed": 0},
    "twoSources": {"orig": 0.95, "relaxed": 0.95},
    "pagesRead": {"orig": 0.90, "relaxed": 0.90},
    "variety": {"orig": 0.80, "relaxed": None},
    "authority": {"orig": 0.80, "relaxed": None},
    "speedMedian": {"orig": 3.0, "relaxed": 4.0},
    "speedP90": {"orig": 4.5, "relaxed": 6.0},
    "judgeShare": {"orig": 0.80, "relaxed": 0.65},
    "judgeBraveCategory": {"orig": 0.5, "relaxed": 0.5},
    "recency": {"orig": None, "relaxed": 0.70},
    "toolShare": {"orig": 0.90, "relaxed": 0.90},
    "toolNew": {"orig": 10, "relaxed": 10},
}
NEW_TOOL_PREFIX = "new-"
NEW_TOOL_COUNT = 12


def load_module(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The hashing and the list loading are the list updater's (F29 CP3), not a second copy.
updater = load_module("update_search_lists", "update-search-lists.py")


# MARK: The question set

def validate_questions(entries):
    """The problems with a question set: counts, IDs, categories, and one of `query` or `tool`."""
    problems = []
    if not isinstance(entries, list):
        return ["The question set is not a list."]
    ids = [entry.get("id") for entry in entries]
    if len(entries) != sum(CATEGORY_COUNTS.values()):
        problems.append(f"Expected {sum(CATEGORY_COUNTS.values())} questions, found {len(entries)}.")
    if len(set(ids)) != len(ids):
        problems.append("Question IDs are not unique.")
    counts = Counter(entry.get("category") for entry in entries)
    for category, expected in CATEGORY_COUNTS.items():
        if counts.get(category, 0) != expected:
            problems.append(f"{category}: expected {expected}, found {counts.get(category, 0)}.")
    for category in set(counts) - set(CATEGORY_COUNTS):
        problems.append(f"Unknown category {category}.")
    for entry in entries:
        identifier = entry.get("id", "?")
        if not str(entry.get("question", "")).strip():
            problems.append(f"{identifier}: empty question.")
        has_query, has_tool = "query" in entry, "tool" in entry
        if has_query == has_tool:
            problems.append(f"{identifier}: needs exactly one of query and tool.")
            continue
        if has_tool:
            tool = entry["tool"]
            name = tool.get("name")
            if name not in TOOL_ARGUMENTS or entry.get("category") not in TOOL_CATEGORIES:
                problems.append(f"{identifier}: bad tool.")
            elif TOOL_NAMES[entry["category"]] != name:
                problems.append(f"{identifier}: {name} is not the {entry['category']} tool.")
            elif not set(tool.get("arguments", {})) <= TOOL_ARGUMENTS[name]:
                problems.append(f"{identifier}: unknown tool arguments.")
        elif entry.get("category") in TOOL_CATEGORIES or not str(entry["query"]).strip():
            problems.append(f"{identifier}: a web question needs a non-empty query.")
    return problems


def load_questions(path=QUESTIONS):
    entries = json.loads(Path(path).read_text(encoding="utf-8"))
    problems = validate_questions(entries)
    if problems:
        raise SystemExit("The question set is invalid:\n" + "\n".join(problems))
    return {entry["id"]: entry for entry in entries}


# MARK: Lists

def registrable(domain, psl):
    return psl.registrable(domain) or domain


def hash_set(path):
    """The 8-byte little-endian FNV-1a hashes of a bundled `.bin` list (update-search-lists.py)."""
    data = Path(path).read_bytes()
    count = len(data) // 8
    return set(struct.unpack("<%dQ" % count, data[:count * 8])) if count else set()


class Lists:
    """Ad, blocklist, spam and authority matching, from the bundled lists."""

    def __init__(self, folder):
        folder = Path(folder)
        self.psl = updater.parse_psl((folder / "public_suffix_list.dat").read_text(encoding="utf-8"))
        self.unsafe = hash_set(folder / "unsafe.bin")
        self.spam = hash_set(folder / "spam.bin")
        self.blocked = set()
        for line in (folder / "enigma-blocked.txt").read_text(encoding="utf-8").splitlines():
            text = line.strip()
            domain = updater.normalize_domain(text) if text and not text.startswith("#") else None
            if domain:
                self.blocked.add(domain)
        self.rules = []
        for line in (folder / "authority.txt").read_text(encoding="utf-8").splitlines():
            text = line.strip()
            if text and not text.startswith("#"):
                self.rules.append(text.lower())

    def listed(self, domain):
        """Whether the domain, or a parent with two or more labels, is on a blocklist or spam list."""
        labels = domain.split(".")
        for start in range(len(labels) - 1):
            candidate = ".".join(labels[start:])
            if updater.fnv1a64(candidate) in self.unsafe or updater.fnv1a64(candidate) in self.spam:
                return True
            if candidate in self.blocked:
                return True
        return False

    def authoritative(self, domain):
        """Spec §3.3: a suffix rule starts with '.', a domain covers its subdomains, and a '!' rule
        is never an authority whatever else matches (D58)."""
        matched = False
        for rule in self.rules:
            negate = rule.startswith("!")
            text = rule[1:] if negate else rule
            hit = domain.endswith(text) if text.startswith(".") else (domain == text or domain.endswith("." + text))
            if hit and negate:
                return False
            matched = matched or hit
        return matched


def domain_of(url):
    host = urllib.parse.urlsplit(url).hostname or ""
    return host.removeprefix("www.").lower()


def is_ad(url):
    return any(marker in url for marker in AD_MARKERS)


# MARK: Reading the run folder

def read_jsonl(path):
    path = Path(path)
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def index_runs(rows):
    """{(style, provider): {id: record}}; a later line for the same key wins."""
    runs = {}
    for row in rows:
        runs.setdefault((row["style"], row["provider"]), {})[row["id"]] = row
    return runs


def index_answers(rows):
    answers = {}
    for row in rows:
        answers[(row["style"], row["provider"], row["id"])] = row["answer"]
    return answers


def latency_seconds(record):
    value = record.get("latencyMs")
    return None if value is None else value / 1000.0


def percentile(values, share):
    """The nearest-rank percentile."""
    ordered = sorted(values)
    if not ordered:
        return None
    rank = max(1, math.ceil(share * len(ordered)))
    return round(ordered[min(len(ordered), rank) - 1], 2)


def median_of(values):
    return round(statistics.median(values), 2) if values else None


# MARK: Measures

def sources_of(record):
    return record.get("sources") or []


def on_device_web_ids(questions, runs, style):
    """The questions the on-device provider routed to the web for this style."""
    rows = runs.get((style, "onDevice"), {})
    return [qid for qid in questions if qid in rows and rows[qid].get("route") == "web"], \
        [qid for qid in questions if qid not in rows]


def blind_first(question_id, style):
    """The label shown as answer A: a hash bit of the question and style, so the order is fixed
    for a question and balanced across the set, and the provider never shows in the prompt."""
    return "onDevice" if hashlib.sha256(f"{question_id}|{style}".encode()).digest()[0] & 1 else "brave"


def measure(questions, runs, lists, judgments, tool_reports):
    """Every number the gate and the report use. Missing runs are counted, never skipped quietly."""
    measures = {"missing": 0, "styles": {}, "bad": 0, "bad_sources": []}
    latencies = []
    for style in STYLES:
        on_device = runs.get((style, "onDevice"), {})
        web_ids, missing = on_device_web_ids(questions, runs, style)
        measures["missing"] += len(missing)
        two = sum(1 for qid in web_ids if len(sources_of(on_device[qid])) >= 2)
        read = sum(1 for qid in web_ids if any(s.get("kind") in PAGE_KINDS for s in sources_of(on_device[qid])))
        variety = sum(1 for qid in web_ids
                      if len({registrable(domain_of(s["url"]), lists.psl) for s in sources_of(on_device[qid])}) >= 3)
        authority_ids = [qid for qid in web_ids if questions[qid]["category"] in AUTHORITY_CATEGORIES]
        authority = sum(1 for qid in authority_ids
                        if any(lists.authoritative(domain_of(s["url"])) for s in sources_of(on_device[qid])))
        measures["styles"][style] = {
            "web": len(web_ids), "twoSources": share(two, len(web_ids)), "pagesRead": share(read, len(web_ids)),
            "variety": share(variety, len(web_ids)), "authority": share(authority, len(authority_ids)),
            "authorityQuestions": len(authority_ids),
        }
        for qid, record in on_device.items():
            if record.get("latencyMs") is not None:
                latencies.append(latency_seconds(record))
            for source in sources_of(record):
                domain = domain_of(source["url"])
                if is_ad(source["url"]) or lists.listed(domain):
                    measures["bad"] += 1
                    measures["bad_sources"].append(f"{style}:{qid}:{domain}")
    measures["speedMedian"] = median_of(latencies)
    measures["speedP90"] = percentile(latencies, 0.9)
    measures["speedRuns"] = len(latencies)
    measures["judge"] = judge_measures(questions, judgments)
    measures["tools"] = tool_measures(tool_reports)
    return measures


def share(part, whole):
    return round(part / whole, 3) if whole else None


def judge_measures(questions, judgments):
    """Per style: the share of questions where on-device wins or ties, the Brave-win share in each
    category, and the recency share on news and changing-facts questions."""
    result = {}
    for style in STYLES:
        rows = [judgments[(style, qid)] for qid in questions if (style, qid) in judgments
                and "verdict" in judgments[(style, qid)]]
        judged = len(rows)
        equal = sum(1 for row in rows if row["verdict"]["overall"] != "brave")
        categories = {}
        for category in CATEGORY_COUNTS:
            cat_ids = [qid for qid in questions if questions[qid]["category"] == category]
            cat_rows = [row for row in rows if questions[row["id"]]["category"] == category]
            brave_wins = sum(1 for row in cat_rows if row["verdict"]["overall"] == "brave")
            categories[category] = {"questions": len(cat_ids), "judged": len(cat_rows), "brave": brave_wins,
                                    "onDevice": sum(1 for row in cat_rows if row["verdict"]["overall"] == "onDevice"),
                                    "tie": sum(1 for row in cat_rows if row["verdict"]["overall"] == "tie"),
                                    "braveShare": share(brave_wins, len(cat_ids))}
        recency_rows = [row for row in rows if questions[row["id"]]["category"] in RECENCY_CATEGORIES]
        recency_equal = sum(1 for row in recency_rows if row["verdict"]["recency"] != "brave")
        recency_total = sum(1 for qid in questions if questions[qid]["category"] in RECENCY_CATEGORIES)
        result[style] = {"judged": judged, "questions": len(questions), "equalOrBetter": equal,
                         "share": share(equal, len(questions)) if judged == len(questions) else None,
                         "categories": categories,
                         "recencyJudged": len(recency_rows),
                         "recency": share(recency_equal, recency_total) if len(recency_rows) == recency_total else None}
    return result


def tool_measures(reports):
    """Each flagged model's tool-use eval: the overall share and the 12 new prompts right."""
    rows = []
    for name, report in reports:
        results = report.get("results", [])
        new = [item for item in results if str(item.get("id", "")).startswith(NEW_TOOL_PREFIX)]
        rows.append({"model": name, "overall": report["overall"]["share"], "right": report["overall"]["right"],
                     "total": report["overall"]["total"], "newRight": sum(1 for item in new if item.get("right")),
                     "newTotal": len(new)})
    return rows


# MARK: The gate

def gate_checks(measures):
    """Each check: its value, whether it's a pass for each bar (True, False or None for not run)."""
    checks = []

    def add(key, label, value, passed, op):
        base = key.split(":")[0]
        checks.append({"key": key, "label": label, "value": value, "op": op,
                       "inOrig": BARS[base]["orig"] is not None, "inRelaxed": BARS[base]["relaxed"] is not None,
                       "orig": passed("orig") if BARS[base]["orig"] is not None else None,
                       "relaxed": passed("relaxed") if BARS[base]["relaxed"] is not None else None})

    def at_most(key, value):
        return lambda bar: None if value is None else value <= BARS[key][bar]

    bad = measures["bad"]
    add("clean", "Ad, blocklisted or spam sources (on-device runs)", bad, lambda bar: bad <= BARS["clean"][bar], "<=")
    for style in STYLES:
        data = measures["styles"][style]
        value = data["twoSources"]
        add(f"twoSources:{style}", f"2+ sources, web questions ({style})", value,
            lambda bar, v=value: None if v is None else v >= BARS["twoSources"][bar], ">=")
        value = data["pagesRead"]
        add(f"pagesRead:{style}", f"1+ page read, web questions ({style})", value,
            lambda bar, v=value: None if v is None else v >= BARS["pagesRead"][bar], ">=")
        value = data["variety"]
        add(f"variety:{style}", f"3+ domains, web questions ({style})", value,
            lambda bar, v=value: None if v is None else v >= BARS["variety"][bar], ">=")
        value = data["authority"]
        add(f"authority:{style}", f"Authority source, health and docs ({style})", value,
            lambda bar, v=value: None if v is None else v >= BARS["authority"][bar], ">=")
    add("speedMedian", "Median search time (s)", measures["speedMedian"],
        at_most("speedMedian", measures["speedMedian"]), "<=")
    add("speedP90", "90th percentile search time (s)", measures["speedP90"],
        at_most("speedP90", measures["speedP90"]), "<=")
    judge = measures["judge"]
    for style in STYLES:
        value = judge[style]["share"]
        add(f"judgeShare:{style}", f"On-device equal or better, all questions ({style})", value,
            lambda bar, v=value: None if v is None else v >= BARS["judgeShare"][bar], ">=")
    worst = None
    for style in STYLES:
        for category, data in judge[style]["categories"].items():
            if data["braveShare"] is not None and (worst is None or data["braveShare"] > worst):
                worst = data["braveShare"]
    if any(judge[style]["share"] is None for style in STYLES):
        worst = None
    add("judgeBraveCategory", "Largest Brave-win share in one category", worst,
        lambda bar, v=worst: None if v is None else v <= BARS["judgeBraveCategory"][bar], "<=")
    for style in STYLES:
        value = judge[style]["recency"]
        add(f"recency:{style}", f"Recency equal or better, news and facts ({style})", value,
            lambda bar, v=value: None if v is None else v >= BARS["recency"][bar], ">=")
    tools = measures["tools"]
    if tools:
        worst_overall = min(row["overall"] for row in tools)
        worst_new = min(row["newRight"] for row in tools)
        add("toolShare", "Tool-use eval, lowest flagged model", worst_overall,
            lambda bar: worst_overall >= BARS["toolShare"][bar], ">=")
        add("toolNew", "New places and weather prompts right, lowest model (of 12)", worst_new,
            lambda bar: worst_new >= BARS["toolNew"][bar], ">=")
    else:
        add("toolShare", "Tool-use eval, lowest flagged model", None, lambda bar: None, ">=")
        add("toolNew", "New places and weather prompts right, lowest model (of 12)", None, lambda bar: None, ">=")
    return checks


def verdict(checks, bar):
    """`pass`, `fail`, or `incomplete` when any check in the bar wasn't run (never a pass then)."""
    results = [check[bar] for check in checks if check["in" + ("Orig" if bar == "orig" else "Relaxed")]]
    if any(result is False for result in results):
        return "fail"
    if any(result is None for result in results) or not results:
        return "incomplete"
    return "pass"


def gate(measures):
    checks = gate_checks(measures)
    return {"checks": checks, "original": verdict(checks, "orig"), "relaxed": verdict(checks, "relaxed"),
            "measures": measures}


# MARK: The judge

def format_sources(domains):
    return "\n".join(f"- {domain} <{domain}>" for domain in domains) or "(none)"


def judge_prompt(question, first_answer, first_domains, second_answer, second_domains):
    return search_judge.PROMPT.format(
        question=question, answer_a=first_answer.strip() or "(no answer)", sources_a=format_sources(first_domains),
        answer_b=second_answer.strip() or "(no answer)", sources_b=format_sources(second_domains))


def judge_one(question_id, question, style, sides, judge):
    """`sides` maps provider to (answer, domains). Returns the verdict in provider labels."""
    first = blind_first(question_id, style)
    second = "brave" if first == "onDevice" else "onDevice"
    prompt = judge_prompt(question, sides[first][0], sides[first][1], sides[second][0], sides[second][1])
    try:
        raw = judge(prompt)
        winners = search_judge.parse_verdict(raw)
    except search_judge.JudgeError as error:
        return {"id": question_id, "style": style, "error": str(error)}
    names = {"A": first, "B": second, "tie": "tie"}
    return {"id": question_id, "style": style, "shownAsA": first,
            "verdict": {name: names[winners[name]] for name in search_judge.CRITERIA}}


def run_judge(questions, runs, answers, judge, workers, out):
    jobs = []
    for style in STYLES:
        for qid in sorted(questions):
            sides = {}
            for provider in PROVIDERS:
                record = runs.get((style, provider), {}).get(qid)
                answer = answers.get((style, provider, qid))
                if record is None or answer is None:
                    break
                sides[provider] = (answer, sorted({domain_of(s["url"]) for s in sources_of(record)}))
            else:
                jobs.append((qid, questions[qid]["question"], style, sides))
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(judge_one, qid, question, style, sides, judge) for qid, question, style, sides in jobs]
        for future in futures:
            results.append(future.result())
    results.sort(key=lambda row: (row["style"], row["id"]))
    with open(out / "judgments.jsonl", "w", encoding="utf-8") as handle:
        for row in results:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    return {(row["style"], row["id"]): row for row in results}


def claude_judge(command, timeout=600):
    def run(prompt):
        try:
            completed = subprocess.run(command, input=prompt, capture_output=True, text=True, timeout=timeout,
                                       check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise search_judge.JudgeError(f"The judge command didn't finish: {error}") from error
        if completed.returncode != 0:
            raise search_judge.JudgeError(f"The judge command exited with {completed.returncode}.")
        return completed.stdout
    return run


# MARK: Answers from the installed model

def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# The evidence an answer sees is capped, the same for both providers, so the 27B-class models stay
# within a few minutes per answer on this Mac (D97). The cap is in characters of evidence text.
EVIDENCE_CHARACTERS = 12_000


def build_messages(question, evidence, limit=EVIDENCE_CHARACTERS):
    lines = []
    used = 0
    for number, item in enumerate(evidence, start=1):
        text = item.get("text", "")
        room = limit - used
        if room <= 0:
            break
        text = text[:room]
        used += len(text)
        lines.append(f"[{number}] {item.get('title', '')} <{item.get('url', '')}>\n{text}")
    system = ("Answer the user's question using only the search results below. Cite the results you use by "
              "their numbers. If the results don't answer the question, say so.")
    body = "\n\n".join(lines) or "(no results)"
    return [{"role": "system", "content": system},
            {"role": "user", "content": f"Search results:\n\n{body}\n\nQuestion: {question}"}]


def ask(port, messages, timeout=300):
    body = json.dumps({"messages": messages, "temperature": 0.2, "max_tokens": 400}).encode("utf-8")
    request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        reply = json.loads(response.read().decode("utf-8"))
    text = reply["choices"][0]["message"].get("content") or ""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()


def generate_answers(folder, questions, contexts, mapping, server_binary):
    """Starts the bundled llama-server once per model path, answers every context whose style uses
    that model, and stops only the processes it started. Rows already in answers.jsonl are kept."""
    out = folder / "answers.jsonl"
    done = {(row["style"], row["provider"], row["id"]) for row in read_jsonl(out)}
    by_model = {}
    for style, model_path in mapping.items():
        by_model.setdefault(model_path, []).append(style)
    for model_path, styles in by_model.items():
        port = free_port()
        process = subprocess.Popen([server_binary, "-m", model_path, "--host", "127.0.0.1", "--port", str(port),
                                    "-c", "8192", "-ngl", "99", "--no-webui"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_until_ready(port, process)
            with open(out, "a", encoding="utf-8") as handle:
                for style in styles:
                    for context in sorted(contexts.get(style, []), key=lambda row: (row["provider"], row["id"])):
                        key = (style, context["provider"], context["id"])
                        if key in done:
                            continue
                        question = questions[context["id"]]["question"]
                        answer = ask(port, build_messages(question, context.get("evidence", [])))
                        row = {"id": context["id"], "style": style, "provider": context["provider"], "answer": answer}
                        handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                        done.add(key)
        finally:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
    return read_jsonl(out)


def wait_until_ready(port, process, timeout=600):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if process.poll() is not None:
            raise SystemExit("llama-server exited before it was ready.")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, OSError):
            time.sleep(2)
    raise SystemExit("llama-server didn't become ready in time.")


# MARK: The spot check

def write_spot_check(folder, questions, runs, answers, judgments):
    """15 pairs for the owner to judge blind. The key (answer order and the judge's verdict) is a
    separate file, which the blind reader never sees."""
    pairs = sorted((style, qid) for (style, qid), row in judgments.items()
                   if "verdict" in row and (style, "onDevice", qid) in answers and (style, "brave", qid) in answers)
    rng = random.Random(SPOT_CHECK_SEED)
    chosen = sorted(rng.sample(pairs, min(SPOT_CHECK_PAIRS, len(pairs))))
    lines = ["# Spot check: blind pairs", "",
             "For each pair, read both answers and the sources, then pick Answer 1, Answer 2 or tie on",
             "correctness, recency and sourcing. Write your picks in `spot-check-picks.json` as",
             '{"1": "1" | "2" | "tie", ...}. Don\'t look at spot-check-key.json.', ""]
    key = []
    for number, (style, qid) in enumerate(chosen, start=1):
        pair_rng = random.Random(f"{SPOT_CHECK_SEED}|{number}")
        order = ["onDevice", "brave"]
        pair_rng.shuffle(order)
        lines += [f"## Pair {number:02d}", "", f"Question: {questions[qid]['question']}", ""]
        for index, provider in enumerate(order, start=1):
            record = runs[(style, provider)][qid]
            domains = sorted({domain_of(s["url"]) for s in sources_of(record)})
            lines += [f"### Answer {index}", "", answers[(style, provider, qid)].strip() or "(no answer)", "",
                      "Sources: " + (", ".join(domains) or "(none)"), ""]
        key.append({"pair": number, "id": qid, "style": style, "answer1": order[0], "answer2": order[1],
                    "judge": judgments[(style, qid)]["verdict"]})
    (folder / "spot-check.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (folder / "spot-check-key.json").write_text(json.dumps(key, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return key


def spot_check_agreement(folder, key):
    picks_path = folder / "spot-check-picks.json"
    if not picks_path.exists():
        return None
    picks = json.loads(picks_path.read_text(encoding="utf-8"))
    agreed = compared = 0
    for item in key:
        pick = picks.get(str(item["pair"]))
        if pick not in ("1", "2", "tie"):
            continue
        compared += 1
        owner = "tie" if pick == "tie" else (item["answer1"] if pick == "1" else item["answer2"])
        if owner == item["judge"]["overall"]:
            agreed += 1
    return {"compared": compared, "agreed": agreed, "share": share(agreed, compared)}


# MARK: The report

def fmt(value):
    if value is None:
        return "not run"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        return str(round(value, 3))
    return str(value)


def report_markdown(folder, questions, result, runs, agreement, lists, judge_model):
    measures = result["measures"]
    lines = ["# Web search evaluation: report", "",
             f"Run folder: `{folder}` (outside the repository). Judge: `{judge_model}`. Questions: {len(questions)}.",
             "", "## Gate", "",
             "| Check | Value | Original bar | Relaxed bar | Original | Relaxed |", "| --- | --- | --- | --- | --- | --- |"]
    for check in result["checks"]:
        original_bar = BARS[check["key"].split(":")[0]]["orig"]
        relaxed_bar = BARS[check["key"].split(":")[0]]["relaxed"]
        lines.append(f"| {check['label']} | {fmt(check['value'])} | {fmt(original_bar)} {check['op']} | "
                     f"{fmt(relaxed_bar)} {check['op']} | {fmt(check['orig'])} | {fmt(check['relaxed'])} |")
    lines += ["", f"**Original gate (spec):** {result['original']}. **Relaxed gate (D3):** {result['relaxed']}.", ""]
    lines += ["## Speed", "", f"On-device runs: {measures['speedRuns']}. Median {fmt(measures['speedMedian'])} s, "
              f"90th percentile {fmt(measures['speedP90'])} s.", ""]
    lines += ["## Judge, per category (on-device, brave, tie)", ""]
    for style in STYLES:
        data = measures["judge"][style]
        lines += [f"### {style}: judged {data['judged']} of {data['questions']}", "",
                  "| Category | Questions | On-device | Brave | Tie | Brave share |", "| --- | --- | --- | --- | --- | --- |"]
        for category, row in data["categories"].items():
            lines.append(f"| {category} | {row['questions']} | {row['onDevice']} | {row['brave']} | {row['tie']} | "
                         f"{fmt(row['braveShare'])} |")
        lines.append("")
    lines += ["## Web questions (on-device route)", "", "| Style | Web questions | 2+ sources | 1+ page read | "
              "3+ domains | Authority (health, docs) |", "| --- | --- | --- | --- | --- | --- |"]
    for style in STYLES:
        data = measures["styles"][style]
        lines.append(f"| {style} | {data['web']} | {fmt(data['twoSources'])} | {fmt(data['pagesRead'])} | "
                     f"{fmt(data['variety'])} | {fmt(data['authority'])} |")
    lines.append("")
    if measures["tools"]:
        lines += ["## Tool choice", "", "| Model | Overall | New prompts right (of 12) |", "| --- | --- | --- |"]
        for row in measures["tools"]:
            lines.append(f"| {row['model']} | {row['right']}/{row['total']} = {fmt(row['overall'])} | "
                         f"{row['newRight']}/{row['newTotal']} |")
        lines.append("")
    if agreement:
        lines += ["## Spot check", "", f"The owner agreed with the judge on {agreement['agreed']} of "
                  f"{agreement['compared']} pairs ({fmt(agreement['share'])}).", ""]
    else:
        lines += ["## Spot check", "", "Not yet compared: `spot-check-picks.json` isn't in the folder.", ""]
    for provider in PROVIDERS:
        counter = Counter(domain_of(s["url"]) for record in runs.get(("typed", provider), {}).values()
                          for s in sources_of(record))
        counter.update(domain_of(s["url"]) for record in runs.get(("model", provider), {}).values()
                       for s in sources_of(record))
        lines += [f"## Most frequent domains: {provider}", "", ", ".join(f"{d} ({n})" for d, n in
                                                                       counter.most_common(20)) or "(none)", ""]
    lines += ["## Not run", ""]
    if measures["missing"]:
        lines.append(f"- {measures['missing']} question runs missing from the on-device folder.")
    if not measures["judge"]["typed"]["judged"] and not measures["judge"]["model"]["judged"]:
        lines.append("- The judge didn't run: no Brave answers and on-device answers.")
    lines.append("")
    return "\n".join(lines)


def summary_json(result, agreement):
    checks = [{key: value for key, value in check.items()} for check in result["checks"]]
    return {"original": result["original"], "relaxed": result["relaxed"], "checks": checks,
            "spotCheck": agreement, "measures": {k: v for k, v in result["measures"].items() if k != "bad_sources"}}


# MARK: The command

def parse_mapping(values):
    mapping = {}
    for value in values or []:
        style, _, path = value.partition("=")
        if style not in STYLES or not path:
            raise SystemExit(f"--answer takes typed=<model> or model=<model>, not {value!r}.")
        mapping[style] = path
    return mapping


def load_tool_reports(paths):
    reports = []
    for path in paths or []:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        reports.append((data.get("route", Path(path).stem), data))
    return reports


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("folder")
    parser.add_argument("--lists", default=str(DEFAULT_LISTS))
    parser.add_argument("--judge-command", default=None)
    parser.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)
    parser.add_argument("--no-judge", action="store_true")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--answer", action="append", help="typed=<gguf> or model=<gguf>")
    parser.add_argument("--llama-server", default=None)
    parser.add_argument("--tool-eval", action="append", help="a tool-use eval report (JSON)")
    args = parser.parse_args(argv)

    folder = Path(args.folder)
    if not folder.is_dir():
        raise SystemExit(f"No run folder at {folder}.")
    questions = load_questions()
    runs = index_runs(read_jsonl(folder / "runs.jsonl"))
    if not runs:
        raise SystemExit("No runs.jsonl in the folder.")
    lists = Lists(args.lists)

    mapping = parse_mapping(args.answer)
    if mapping:
        if not args.llama_server:
            raise SystemExit("--answer needs --llama-server.")
        contexts = {}
        for row in read_jsonl(folder / "contexts.jsonl"):
            contexts.setdefault(row["style"], []).append(row)
        generate_answers(folder, questions, contexts, mapping, args.llama_server)
    answers = index_answers(read_jsonl(folder / "answers.jsonl"))

    judgments = {}
    if not args.no_judge:
        command = shlex.split(args.judge_command) if args.judge_command else search_judge.claude_code_command(
            args.judge_model)
        judgments = run_judge(questions, runs, answers, claude_judge(command), args.workers, folder)
    else:
        for row in read_jsonl(folder / "judgments.jsonl"):
            judgments[(row["style"], row["id"])] = row

    tool_reports = load_tool_reports(args.tool_eval)
    measures = measure(questions, runs, lists, judgments, tool_reports)
    result = gate(measures)
    key = write_spot_check(folder, questions, runs, answers, judgments) if answers and judgments else []
    agreement = spot_check_agreement(folder, key) if key else None
    (folder / "report.md").write_text(report_markdown(folder, questions, result, runs, agreement, lists,
                                                      args.judge_model), encoding="utf-8")
    (folder / "summary.json").write_text(json.dumps(summary_json(result, agreement), indent=2,
                                                    ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Original gate: {result['original']}. Relaxed gate: {result['relaxed']}.")
    print(f"Report: {folder / 'report.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
