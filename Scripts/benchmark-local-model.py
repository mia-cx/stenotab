#!/usr/bin/python3
"""Measure autocomplete TTFT and decode throughput through the real HTTP API."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import time
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_FIXTURES = (
    Path(__file__).resolve().parent.parent
    / "Benchmarks"
    / "autocomplete-fixtures.json"
)
PROMPT_ROOT = (
    Path(__file__).resolve().parent.parent
    / "Sources"
    / "CompletionCore"
    / "Resources"
    / "Prompts"
)
DEFAULT_SYSTEM_INSTRUCTION = (
    "Continue the user's current text at the cursor. Match their voice. "
    "Produce only text that should be inserted."
)


def load_fixture_suite(path: Path) -> tuple[str, list[dict[str, Any]]]:
    payload = json.loads(path.read_text())
    if payload.get("schema_version") != 1:
        raise ValueError(f"Unsupported fixture schema in {path}")
    cases = payload.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError(f"No cases found in {path}")
    instruction = payload.get("system_instruction")
    if not isinstance(instruction, str) or not instruction:
        instruction = DEFAULT_SYSTEM_INSTRUCTION
    return instruction, cases


def prompt_component(filename: str) -> str:
    return (PROMPT_ROOT / "Base" / filename).read_text().removesuffix("\n")


def input_noun_phrase(value: str | None) -> str | None:
    if not value:
        return None
    lowered = value.lower()
    mappings = [
        ("comment", "a comment"),
        ("reply", "a reply"),
        ("message", "a message"),
        ("chat", "a message"),
        ("search", "a search query"),
        ("email", "an email"),
        ("mail", "an email"),
        ("document", "a document"),
        ("text area", "a document"),
        ("code", "code"),
        ("post", "a post"),
    ]
    return next(
        (phrase for marker, phrase in mappings if marker in lowered),
        "some text",
    )


def canonical_prompt(
    case: dict[str, Any],
    prefix: str,
    include_fixture_context: bool,
) -> str:
    context = case["context"]
    application = context.get("application_name")
    website = context.get("website") if include_fixture_context else None
    input_kind = input_noun_phrase(context.get("input_kind"))
    sections = [prompt_component("00-opening-instruction.md")]

    activity = prompt_component("01a-focused-activity-prefix.md")
    if input_kind:
        activity += f" {input_kind}"
    if website:
        activity += (
            f" {prompt_component('01b-focused-website-connector.md')}"
            f" {website}"
        )
    if application:
        activity += (
            f" {prompt_component('01c-focused-application-connector.md')}"
            f" {application}"
        )
    if application or website or input_kind:
        sections.append(
            prompt_component("01-focused-context-heading.md")
            + "\n\n"
            + activity
            + "."
        )

    marker = prompt_component("10a-writing-marker.md")
    seed_examples = sorted(
        (PROMPT_ROOT / "Seed" / "Examples").glob("*.md")
    )
    sections.append(
        prompt_component("02a-seed-fallback-heading.md")
        + "\n\n"
        + "\n\n".join(
            marker + path.read_text().removesuffix("\n")
            for path in seed_examples
        )
    )
    if include_fixture_context:
        assessment = context.get("user_voice")
        if isinstance(assessment, str) and assessment.strip():
            sections.append(
                prompt_component("04-assessment-heading.md")
                + "\n\n"
                + assessment.strip()
            )
    sections.append(prompt_component("06-perspective-fix.md"))
    if include_fixture_context:
        for filename, value in [
            ("07-ocr-heading.md", context.get("ocr_content")),
            ("08-clipboard-heading.md", context.get("clipboard_content")),
        ]:
            if isinstance(value, str) and value.strip():
                sections.append(
                    prompt_component(filename) + "\n\n" + value.strip()
                )
    sections.append(prompt_component("09-final-boundary.md"))
    suffix = case["text"].get("after_cursor", "")
    if suffix:
        sections.extend(
            [
                prompt_component("10b-midline-before-cursor-heading.md")
                + "\n"
                + marker
                + prefix,
                prompt_component("10c-midline-after-cursor-heading.md")
                + "\n"
                + suffix,
                prompt_component("10d-midline-current-part-heading.md")
                + "\n"
                + marker
                + prefix[-500:],
            ]
        )
    else:
        sections.append(
            prompt_component("10-writing-heading.md")
            + "\n"
            + marker
            + prefix
        )
    return "\n\n".join(sections)


def prompt_for_case(
    case: dict[str, Any],
    prefix: str,
    api_style: str,
    prompt_style: str,
) -> str:
    return canonical_prompt(
        case,
        prefix,
        include_fixture_context=prompt_style == "contextual",
    )


def raw_completion_prompt(
    case: dict[str, Any],
    prefix: str,
    api_style: str,
    prompt_style: str,
) -> str:
    if api_style == "gemmaChatPrefill":
        return (
            "<bos><|turn>user\n"
            "Continue the assistant text naturally. "
            "Return only the continuation.<turn|>\n"
            f"<|turn>model\n{prefix}"
        )
    return prompt_for_case(case, prefix, api_style, prompt_style)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = round((len(ordered) - 1) * fraction)
    return ordered[index]


def benchmark_once(
    url: str,
    model: str,
    api_style: str,
    prompt_style: str,
    system_instruction: str,
    case: dict[str, Any],
    prefix: str,
) -> tuple[float | None, float, float, str]:
    max_tokens = 6 if case["lane"] == "partial-word" else 16
    if api_style == "chatCompletions":
        endpoint = f"{url.rstrip('/')}/chat/completions"
        body = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_instruction},
                {
                    "role": "user",
                    "content": prompt_for_case(
                        case,
                        prefix,
                        api_style,
                        prompt_style,
                    ),
                },
            ],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stop": ["\n"],
            "stream": True,
        }
    else:
        endpoint = f"{url.rstrip('/')}/completions"
        raw_prompt = raw_completion_prompt(
            case,
            prefix,
            api_style,
            prompt_style,
        )
        body = {
            "model": model,
            "prompt": raw_prompt,
            "max_tokens": max_tokens,
            "temperature": 0,
            "stop": ["\n"],
            "stream": True,
        }

    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    first_token_at: float | None = None
    token_chunks = 0
    output = ""

    with urllib.request.urlopen(request, timeout=30) as response:
        for raw_line in response:
            line = raw_line.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            event = json.loads(payload)
            choice = (event.get("choices") or [{}])[0]
            piece = choice.get("text")
            if piece is None:
                piece = (choice.get("delta") or {}).get("content")
            if not piece:
                continue
            if first_token_at is None:
                first_token_at = time.perf_counter()
            token_chunks += 1
            output += piece

    finished = time.perf_counter()
    if first_token_at is None:
        return None, finished - started, 0, ""
    ttft = first_token_at - started
    total = finished - started
    decode_seconds = max(finished - first_token_at, 0.000_001)
    decode_tps = max(token_chunks - 1, 0) / decode_seconds
    return ttft, total, decode_tps, output


def quality_issues(
    case: dict[str, Any],
    prefix: str,
    output: str,
) -> list[str]:
    quality = case["quality"]
    issues = []
    if not output.strip():
        issues.append("returned an empty completion")
    lowered = output.lower()
    internal_prompt_markers = [
        "context:",
        "ocr content from snapshot:",
        "clipboard content:",
        "user voice:",
        "the user is typing in:",
        "kind of input:",
        "completion instructions",
        "insertion:",
    ]
    forbidden_substrings = [
        *quality.get("forbidden_substrings", []),
        *internal_prompt_markers,
    ]
    for forbidden in dict.fromkeys(forbidden_substrings):
        if forbidden.lower() in lowered:
            issues.append(f"contains forbidden text {forbidden!r}")

    maximum_words = quality.get("maximum_words")
    word_count = len(re.findall(r"\S+", output.strip()))
    if isinstance(maximum_words, int) and word_count > maximum_words:
        issues.append(f"has {word_count} words; maximum is {maximum_words}")

    exact_continuations = quality.get("exact_continuations", [])
    if exact_continuations and output.strip() not in exact_continuations:
        issues.append(
            "does not match an exact expected continuation "
            + repr(exact_continuations)
        )

    relevance_terms = quality.get("relevance_terms", [])
    if relevance_terms and not any(
        term.lower() in lowered for term in relevance_terms
    ):
        issues.append("has no expected relevance term")

    if quality.get("must_not_repeat_input"):
        normalized_output = output.strip().lower()
        normalized_prefix = prefix.strip().lower()
        if normalized_prefix and normalized_output.startswith(normalized_prefix):
            issues.append("repeats the input prefix")
        elif len(normalized_output) >= 4 and normalized_output in normalized_prefix:
            issues.append("repeats text already present before the cursor")
    return issues


def selected_cases(
    cases: list[dict[str, Any]],
    selected_ids: list[str],
) -> list[dict[str, Any]]:
    if not selected_ids:
        return [
            case
            for case in cases
            if case["lane"] in {"continuation", "partial-word"}
        ]
    by_id = {case["id"]: case for case in cases}
    missing = [case_id for case_id in selected_ids if case_id not in by_id]
    if missing:
        raise ValueError(f"Unknown fixture case(s): {', '.join(missing)}")
    return [by_id[case_id] for case_id in selected_ids]


def expanded_requests(
    cases: list[dict[str, Any]],
    use_cache_sequence: bool,
) -> list[tuple[dict[str, Any], str, str]]:
    requests = []
    for case in cases:
        if case["lane"] == "no-request":
            print(f"skip {case['id']}: fixture expects no inference request")
            continue
        prefixes = (
            case.get("cache_sequence", [])
            if use_cache_sequence
            else [case["text"]["before_cursor"]]
        )
        if not prefixes:
            prefixes = [case["text"]["before_cursor"]]
        for index, prefix in enumerate(prefixes):
            step = f"cache-{index + 1}" if use_cache_sequence else "final"
            requests.append((case, prefix, step))
    return requests


def rendered_request(
    model: str,
    api_style: str,
    prompt_style: str,
    system_instruction: str,
    case: dict[str, Any],
    prefix: str,
) -> dict[str, Any]:
    prompt = prompt_for_case(case, prefix, api_style, prompt_style)
    if api_style == "chatCompletions":
        return {
            "model": model,
            "messages": [
                {"role": "system", "content": system_instruction},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": 16,
            "temperature": 0,
            "stop": ["\n"],
            "stream": True,
        }
    return {
        "model": model,
        "prompt": raw_completion_prompt(
            case,
            prefix,
            api_style,
            prompt_style,
        ),
        "max_tokens": 6 if case["lane"] == "partial-word" else 16,
        "temperature": 0,
        "stop": ["\n"],
        "stream": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url")
    parser.add_argument("--model")
    parser.add_argument(
        "--api-style",
        choices=[
            "textCompletions",
            "chatCompletions",
            "gemmaChatPrefill",
        ],
    )
    parser.add_argument(
        "--prompt-style",
        choices=["contextual", "production"],
        default="contextual",
        help="contextual includes fixture OCR/clipboard/voice; production uses "
        "the canonical prompt with optional fixture sources disabled",
    )
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=DEFAULT_FIXTURES,
    )
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        help="fixture ID to run; repeat to select multiple cases",
    )
    parser.add_argument(
        "--cache-sequence",
        action="store_true",
        help="run each fixture's growing-prefix sequence in order",
    )
    parser.add_argument(
        "--trials",
        type=int,
        default=0,
        help="number of requests; zero runs each selected request once",
    )
    parser.add_argument("--list-cases", action="store_true")
    parser.add_argument("--print-prompts", action="store_true")
    args = parser.parse_args()

    system_instruction, all_cases = load_fixture_suite(args.fixtures)
    if args.list_cases:
        for case in all_cases:
            print(
                f"{case['id']:<30} "
                f"lane={case['lane']:<12} "
                f"category={case['category']}"
            )
        return

    if not args.api_style:
        parser.error("--api-style is required")
    if not args.model:
        parser.error("--model is required")

    cases = selected_cases(all_cases, args.case)
    requests = expanded_requests(cases, args.cache_sequence)
    if not requests:
        return

    if args.print_prompts:
        for case, prefix, step in requests:
            print(
                json.dumps(
                    {
                        "fixture": case["id"],
                        "step": step,
                        "request": rendered_request(
                            args.model,
                            args.api_style,
                            args.prompt_style,
                            system_instruction,
                            case,
                            prefix,
                        ),
                    },
                    indent=2,
                    ensure_ascii=False,
                )
            )
        return

    if not args.url:
        parser.error("--url is required unless --list-cases or --print-prompts")
    if args.trials < 0:
        parser.error("--trials cannot be negative")
    if args.trials:
        requests = [
            requests[index % len(requests)]
            for index in range(args.trials)
        ]

    results: list[tuple[float | None, float, float]] = []
    quality_failure_count = 0
    for trial, (case, prefix, step) in enumerate(requests, start=1):
        ttft, total, decode_tps, output = benchmark_once(
            args.url,
            args.model,
            args.api_style,
            args.prompt_style,
            system_instruction,
            case,
            prefix,
        )
        results.append((ttft, total, decode_tps))
        issues = quality_issues(case, prefix, output)
        quality_failure_count += bool(issues)
        quality_status = "PASS" if not issues else "FAIL: " + "; ".join(issues)
        ttft_status = (
            f"{ttft * 1000:>6.1f}ms"
            if ttft is not None
            else "   n/a "
        )
        print(
            f"{trial:>2} {case['id']:<30} {step:<8} "
            f"ttft={ttft_status} "
            f"total={total * 1000:>6.1f}ms "
            f"decode={decode_tps:>6.1f}tok/s "
            f"quality={quality_status} "
            f"output={output!r}"
        )

    ttfts = [result[0] for result in results if result[0] is not None]
    totals = [result[1] for result in results]
    throughputs = [result[2] for result in results]
    ttft_summary = (
        f"ttft_p50={statistics.median(ttfts) * 1000:.1f}ms "
        f"ttft_p95={percentile(ttfts, 0.95) * 1000:.1f}ms "
        if ttfts
        else "ttft_p50=n/a ttft_p95=n/a "
    )
    print(
        "summary "
        f"{ttft_summary}"
        f"total_p50={statistics.median(totals) * 1000:.1f}ms "
        f"decode_mean={statistics.mean(throughputs):.1f}tok/s "
        f"quality_failures={quality_failure_count}/{len(results)}"
    )


if __name__ == "__main__":
    main()
