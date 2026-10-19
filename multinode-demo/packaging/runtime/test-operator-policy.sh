#!/usr/bin/env bash
set -euo pipefail

# Uses the existing loopback operator API without saving or applying policy.
python3 - <<'PY'
import json
import urllib.error
import urllib.request

base = "http://127.0.0.1:8787"
with urllib.request.urlopen(base + "/api/policy", timeout=10) as response:
    catalog = json.load(response)
assert catalog["configured"] and catalog["compiler_ready"], catalog
with urllib.request.urlopen(base + "/api/snapshot", timeout=15) as response:
    assert json.load(response)["api_status"] == "connected"
cases = [
    ("valid", "Define OciWeb as a service with device.zpr.adapter.cn:'ociweb.demo'.\n"
     "provide OciWeb at ociweb.demo over TCP 80.\n  allow access:cloud users.\n", 200),
    ("invalid", "this is not valid ZPR policy !!!\n", 422),
]
for label, source, expected in cases:
    request = urllib.request.Request(
        base + "/api/policy/check", data=json.dumps({"source": source}).encode(),
        headers={"Content-Type": "application/json", "Origin": base})
    try:
        response = urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        result = json.load(response)
        assert response.code == expected, (response.code, result)
    assert result["valid"] == (expected == 200), result
    assert result["diagnostics"], result
    if expected == 422:
        assert "line 1" in result["diagnostics"] and "column" in result["diagnostics"], result
    print(f"PASS: {label} source returned HTTP {expected}; diagnostics preserved")
print("PASS: live topology and compiler-backed validation; no draft or policy changes")
PY
