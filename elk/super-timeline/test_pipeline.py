#!/usr/bin/env python3
"""Check the super-timeline pipeline against samples of every worker's output.

Runs the pipeline from pipeline.painless, rules.json and descriptions.json with Elasticsearch's simulate API,
so nothing is installed or indexed. Needs a running Elasticsearch (ES, default
http://localhost:9200) and only the Python standard library.

Usage: python3 elk/super-timeline/test_pipeline.py
"""

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
ES = os.environ.get("ES", "http://localhost:9200")


def pipeline() -> dict:
    return {
        "processors": [{
            "script": {
                "lang": "painless",
                "source": (HERE / "pipeline.painless").read_text(),
                "params": {
                    "rules": json.loads((HERE / "rules.json").read_text()),
                    "descriptions": json.loads((HERE / "descriptions.json").read_text()),
                },
            }
        }]
    }


def simulate(docs: list[dict]) -> list[dict]:
    body = json.dumps({"pipeline": pipeline(), "docs": [{"_source": d} for d in docs]})
    request = urllib.request.Request(
        f"{ES}/_ingest/pipeline/_simulate", data=body.encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = json.loads(error.read() or b"{}").get("error", {})
        cause = detail.get("root_cause", [{}])[0]
        sys.exit(
            "Elasticsearch refused the pipeline: "
            + json.dumps({k: cause.get(k) for k in ("reason", "script_stack") if cause.get(k)})
            + f"\n{detail.get('caused_by', {}).get('reason', '')}"
        )
    return [d.get("doc", {}).get("_source") or d for d in result["docs"]]


def get(doc: dict, path: str):
    for part in path.split("."):
        if not isinstance(doc, dict) or part not in doc:
            return None
        doc = doc[part]
    return doc


def main() -> int:
    cases = json.loads((HERE / "samples.json").read_text())
    results = simulate([case["doc"] for case in cases])
    failures = 0
    for case, result in zip(cases, results):
        problems = []
        if "error" in result:
            problems.append(f"pipeline error: {result['error']}")
        for path, want in case["expect"].items():
            got = get(result, path)
            if got != want:
                problems.append(f"{path}: want {want!r}, got {got!r}")
        status = "FAIL" if problems else "ok"
        print(f"{status:4} {case['name']}")
        for problem in problems:
            print(f"       {problem}")
        failures += bool(problems)
    print(f"\n{len(cases) - failures}/{len(cases)} samples ok")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
