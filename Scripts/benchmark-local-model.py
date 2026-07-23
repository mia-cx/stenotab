#!/usr/bin/python3
"""Measure autocomplete TTFT and decode throughput through the real HTTP API."""

from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.request


CASES = [
    (
        "short-message",
        "Autocomplete at <CURSOR>. Return only the natural text to insert, "
        "at most 8 words. Never repeat existing text. CONTEXT: "
        "Thank you for sending this over, I’ll<CURSOR>",
    ),
    (
        "reply-context",
        "Autocomplete at <CURSOR>. Return only the natural text to insert, "
        "at most 8 words. Never repeat existing text. CONTEXT: "
        "We discussed moving the design review. Thursday afternoon works "
        "for everyone, but Mia asked me to confirm after checking. REPLY: "
        "Thank you for sending this over, I’ll<CURSOR>",
    ),
    (
        "casual-message",
        "Autocomplete at <CURSOR>. Return only the natural text to insert, "
        "at most 8 words. Never repeat existing text. CONTEXT: "
        "lol yeah that’s exactly what I<CURSOR>",
    ),
]


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = round((len(ordered) - 1) * fraction)
    return ordered[index]


def benchmark_once(
    url: str,
    model: str,
    api_style: str,
    prompt: str,
) -> tuple[float, float, float, str]:
    if api_style == "chatCompletions":
        endpoint = f"{url.rstrip('/')}/chat/completions"
        body = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 16,
            "temperature": 0,
            "stream": True,
        }
    else:
        endpoint = f"{url.rstrip('/')}/completions"
        raw_prompt = prompt.rsplit("CONTEXT: ", 1)[-1].replace("<CURSOR>", "")
        body = {
            "model": model,
            "prompt": raw_prompt,
            "max_tokens": 16,
            "temperature": 0,
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

    with urllib.request.urlopen(request, timeout=10) as response:
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
        raise RuntimeError("Server returned no completion tokens")
    ttft = first_token_at - started
    total = finished - started
    decode_seconds = max(finished - first_token_at, 0.000_001)
    decode_tps = max(token_chunks - 1, 0) / decode_seconds
    return ttft, total, decode_tps, output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument(
        "--api-style",
        choices=["textCompletions", "chatCompletions"],
        required=True,
    )
    parser.add_argument("--trials", type=int, default=5)
    args = parser.parse_args()

    results: list[tuple[float, float, float]] = []
    for trial in range(args.trials):
        name, prompt = CASES[trial % len(CASES)]
        ttft, total, decode_tps, output = benchmark_once(
            args.url,
            args.model,
            args.api_style,
            prompt,
        )
        results.append((ttft, total, decode_tps))
        print(
            f"{trial + 1:>2} {name:<15} "
            f"ttft={ttft * 1000:>6.1f}ms "
            f"total={total * 1000:>6.1f}ms "
            f"decode={decode_tps:>6.1f}tok/s "
            f"output={output!r}"
        )

    ttfts = [result[0] for result in results]
    totals = [result[1] for result in results]
    throughputs = [result[2] for result in results]
    print(
        "summary "
        f"ttft_p50={statistics.median(ttfts) * 1000:.1f}ms "
        f"ttft_p95={percentile(ttfts, 0.95) * 1000:.1f}ms "
        f"total_p50={statistics.median(totals) * 1000:.1f}ms "
        f"decode_mean={statistics.mean(throughputs):.1f}tok/s"
    )


if __name__ == "__main__":
    main()
