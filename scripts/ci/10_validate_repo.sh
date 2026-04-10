#!/usr/bin/env bash
set -euo pipefail

GAOKUN_DIR="${GAOKUN_DIR:-$(pwd)}"

cd "$GAOKUN_DIR"

echo "==> Validate shell syntax"
while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts -type f -name '*.sh' | sort)

for script in \
  tools/monitors/gdm-monitor-sync \
  tools/touchscreen-tuner/touchscreen-tune
do
  bash -n "$script"
done

echo "==> Validate Python syntax"
python3 -m py_compile \
  tools/bluetooth/patch-nvm-bdaddr.py \
  tools/touchpad/huawei-tp-activate.py \
  tools/touchscreen-tuner/tune.py

echo "==> Validate workflow YAML"
python3 - <<'PY'
from pathlib import Path
import sys
import yaml

for path in sorted(Path(".github/workflows").glob("*.yml")):
    with path.open("r", encoding="utf-8") as fh:
        try:
            yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            print(f"YAML parse failed for {path}: {exc}", file=sys.stderr)
            raise
PY

echo "==> Validate local Markdown links"
python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path(".").resolve()
md_files = [Path("README.md"), *sorted(Path("docs").glob("*.md")), Path("tools/el2/README.md")]
link_re = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
bad = []

for md_path in md_files:
    text = md_path.read_text(encoding="utf-8")
    for raw_target in link_re.findall(text):
        target = raw_target.strip()
        if not target or "://" in target or target.startswith("#") or target.startswith("mailto:"):
            continue
        target_path = (md_path.parent / target).resolve()
        if not target_path.exists():
            bad.append((md_path, target))

if bad:
    for md_path, target in bad:
        print(f"Broken Markdown link in {md_path}: {target}", file=sys.stderr)
    sys.exit(1)
PY

echo "Validation completed successfully."
