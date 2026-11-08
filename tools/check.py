"""Repository checks (run by CI and before every PR):  python3 tools/check.py

1. Every script parses: Python on 3.9 (the oldest python3 on supported Macs) and the running Python;
   shell scripts with `bash -n` (or `sh -n` for #!/bin/sh).
2. Nothing that must stay private: credentials, private IP addresses, internal QED hostnames, email addresses.
   Embedded zlib/base64 payloads are unpacked and scanned too.
3. Embedded payloads match their recorded sha256.
"""
from __future__ import annotations

import ast
import base64
import hashlib
import re
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"LICENSE", "check.py"}
FORBIDDEN = [
    (r"ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|ghs_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}", "GitHub token"),
    (r"AKIA[0-9A-Z]{16}", "AWS access key"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key"),
    (r"xox[abprs]-[A-Za-z0-9-]{10,}", "Slack token"),
    (r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b", "private IP address"),
    (r"\b[\w-]+(?:\.[\w-]+)*\.(?:qed\.ventures|qed\.internal|lan|local)\b", "internal hostname"),
    (r"\b[\w.+-]+@(?!users\.noreply\.github\.com)[\w-]+\.[\w.-]+\b", "email address"),
]


def payloads(text: str):
    for m in re.finditer(r'^(\w+)_B64 = "([A-Za-z0-9+/=]{40,})"$', text, re.M):
        data = zlib.decompress(base64.b64decode(m.group(2)))
        sha = re.search(rf'^{m.group(1)}_SHA256 = "([0-9a-f]{{64}})"$', text, re.M)
        yield m.group(1), data, sha.group(1) if sha else None


def main() -> int:
    errors = []
    files = [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts and p.name not in SKIP]
    for p in files:
        rel = p.relative_to(ROOT)
        try:
            text = p.read_text()
        except UnicodeDecodeError:
            errors.append(f"{rel}: binary files are not allowed")
            continue
        blobs = [(str(rel), text)]
        if p.suffix == ".sh":
            shell = "sh" if text.startswith("#!/bin/sh") else "bash"
            if shutil.which(shell):
                r = subprocess.run([shell, "-n", str(p)], capture_output=True, text=True)
                if r.returncode:
                    errors.append(f"{rel}: {shell} -n failed: {r.stderr.strip()[:200]}")
            else:
                errors.append(f"{rel}: {shell} not found to syntax-check it")
            if not text.startswith("#!"):
                errors.append(f"{rel}: needs a #! line")
        if p.suffix == ".py":
            for v in ((3, 9), sys.version_info[:2]):
                try:
                    ast.parse(text, filename=str(rel), feature_version=v)
                except SyntaxError as e:
                    errors.append(f"{rel}: does not parse on Python {v[0]}.{v[1]}: {e}")
            for name, data, sha in payloads(text):
                if sha is None or hashlib.sha256(data).hexdigest() != sha:
                    errors.append(f"{rel}: embedded {name} does not match {name}_SHA256")
                blobs.append((f"{rel} (embedded {name})", data.decode("utf-8", "replace")))
        for where, body in blobs:
            for pat, what in FORBIDDEN:
                for m in re.finditer(pat, body):
                    errors.append(f"{where}: {what}: {m.group(0)[:40]}")
    for e in errors:
        print("FAIL", e)
    print(f"checked {len(files)} files: {'ok' if not errors else f'{len(errors)} problem(s)'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
