# Security

This repository is public. If you find a secret, an internal address or personal data in it, or in its history,
tell the code owners (`@qed-dcohen`, `@dg-QED`) privately at once and rotate the secret. Do not open a public issue.

GitHub secret scanning and push protection are on. `tools/check.py` also scans every file, including embedded
payloads, for credentials, private IP ranges, internal hostnames and email addresses.
