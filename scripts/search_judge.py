"""Blind side-by-side judgment of two search-backed answers (F30 CP6; F29 reuses it).

The judge sees two answers to the same question, labelled A and B in a random
order, and picks the better one, or a tie, on correctness, recency and
sourcing. It never learns which search produced which answer. The judge is a
cloud model's CLI, run as a command that reads the prompt on standard input
and writes its verdict on standard output.

Standard library only.
"""

import json
import random
import subprocess

CRITERIA = ("correctness", "recency", "sourcing", "overall")
CHOICES = ("A", "B", "tie")

# Claude Code with no tools, no MCP servers, no customizations and no saved
# session: the judge only reads the prompt.
CLAUDE_CODE = [
    "claude", "-p", "--output-format", "text", "--tools", "", "--strict-mcp-config", "--safe-mode",
    "--no-session-persistence", "--disable-slash-commands",
]

PROMPT = """You are judging two answers to the same web question. Each answer was \
written by an assistant that searched the web, and lists the sources it used. \
You don't know which assistant or search wrote which answer; judge only what \
you see.

Judge on:
- correctness: which answer is more accurate and answers the question asked;
- recency: which answer reflects the most current information the question needs;
- sourcing: which answer relies on better, more relevant, more authoritative \
sources, and links them;
- overall: which answer you would rather give the user.

For each, answer "A", "B" or "tie". Call a tie when neither is clearly better.

Reply with only this JSON object, and nothing else:
{{"correctness": "A|B|tie", "recency": "A|B|tie", "sourcing": "A|B|tie", "overall": "A|B|tie", "reason": "one sentence"}}

Question: {question}

=== Answer A ===
{answer_a}

Sources A:
{sources_a}

=== Answer B ===
{answer_b}

Sources B:
{sources_b}
"""


class JudgeError(Exception):
    pass


def claude_code_command(model=None):
    """The default judge: Claude Code, with an optional model alias such as `sonnet`."""
    return CLAUDE_CODE + (["--model", model] if model else [])


def command_judge(command, timeout=300):
    """A judge that runs `command` with the prompt on standard input."""

    def run(prompt):
        try:
            completed = subprocess.run(command, input=prompt, capture_output=True, text=True, timeout=timeout,
                                       check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise JudgeError(f"The judge command didn't finish: {error}") from error
        if completed.returncode != 0:
            raise JudgeError(f"The judge command exited with {completed.returncode}.")
        return completed.stdout

    return run


def format_sources(sources):
    lines = [f"- {source.get('title') or source.get('url', '')} <{source.get('url', '')}>" for source in sources]
    return "\n".join(lines) or "(none)"


def prompt_for(question, answer_a, sources_a, answer_b, sources_b):
    return PROMPT.format(question=question, answer_a=answer_a.strip() or "(no answer)",
                         sources_a=format_sources(sources_a), answer_b=answer_b.strip() or "(no answer)",
                         sources_b=format_sources(sources_b))


def parse_verdict(text):
    """The judge's JSON verdict: the last object in the text with every criterion."""
    decoder = json.JSONDecoder()
    for start in reversed([index for index, character in enumerate(text) if character == "{"]):
        try:
            value, _ = decoder.raw_decode(text, start)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and all(value.get(name) in CHOICES for name in CRITERIA):
            return {name: value[name] for name in CRITERIA}
    raise JudgeError("The judge's reply had no verdict.")


def judge_pair(question, first, second, judge, rng=random):
    """Judges two candidates, `(label, answer, sources)`, in a random A/B order.

    Returns the order shown and, per criterion, the winning label or "tie".
    """
    shown = [first, second]
    rng.shuffle(shown)
    (label_a, answer_a, sources_a), (label_b, answer_b, sources_b) = shown
    verdict = parse_verdict(judge(prompt_for(question, answer_a, sources_a, answer_b, sources_b)))
    names = {"A": label_a, "B": label_b, "tie": "tie"}
    return {"order": [label_a, label_b], "verdict": {name: names[verdict[name]] for name in CRITERIA}}
