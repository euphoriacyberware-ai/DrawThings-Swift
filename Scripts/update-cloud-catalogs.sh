#!/usr/bin/env bash
#
# Refreshes DrawThingsKit's bundled Draw Things+ model catalogs
# (Sources/DrawThingsKit/Resources/official_models.json and community_models.json) from the
# lists kcjerrell/dt-models compiles from Draw Things' ModelZoo and community-models repository
# (https://github.com/kcjerrell/dt-models). Only the keys DrawThingsKit reads are kept, in
# snake_case, so diffs only show real changes. CI runs it on a schedule and opens a PR.
#
# Usage: Scripts/update-cloud-catalogs.sh [base-url]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${1:-https://kcjerrell.github.io/dt-models}"
DEST="$ROOT/Sources/DrawThingsKit/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for list in official_models official_loras official_controlnets \
            community_models community_loras community_controlnets community_embeddings; do
    curl --fail --silent --show-error --location --max-time 60 "$BASE/$list.json" -o "$TMP/$list.json"
done

python3 - "$TMP" "$DEST" <<'PY'
import json, re, sys
source, dest = sys.argv[1], sys.argv[2]

# The keys each DrawThingsKit model type decodes (see Sources/DrawThingsKit/Models/ModelsManager.swift).
KEYS = {
    "checkpoints": ["name", "file", "version", "prefix", "modifier", "note", "default_scale",
                    "autoencoder", "text_encoder", "clip_encoder", "deprecated"],
    "loras": ["name", "file", "version", "prefix", "is_lo_ha", "is_consistency_model"],
    "controlNets": ["name", "file", "version", "prefix", "deprecated"],
    "textualInversions": ["name", "file", "keyword", "version", "length", "deprecated"],
}
CATALOGS = {
    "official_models": {"checkpoints": "official_models", "loras": "official_loras",
                        "controlNets": "official_controlnets"},
    "community_models": {"checkpoints": "community_models", "loras": "community_loras",
                         "controlNets": "community_controlnets",
                         "textualInversions": "community_embeddings"},
}
MINIMUM = {"official_models": 50, "community_models": 50}  # checkpoints; guards against a broken feed

def snake(key):
    return re.sub(r"(?<!^)([A-Z])", r"_\1", key).lower()

def load(name, kind):
    with open(f"{source}/{name}.json", encoding="utf-8") as f:
        entries = json.load(f)
    if not isinstance(entries, list):
        sys.exit(f"error: {name}.json is a {type(entries).__name__}, expected an array")
    models = []
    for entry in entries:
        entry = {snake(k): v for k, v in entry.items()} if isinstance(entry, dict) else {}
        if not isinstance(entry.get("name"), str) or not isinstance(entry.get("file"), str):
            print(f"  skipping an entry without name/file in {name}.json", file=sys.stderr)
            continue
        if not entry.get("deprecated"):
            entry.pop("deprecated", None)
        models.append({k: entry[k] for k in KEYS[kind] if entry.get(k) is not None})
    return sorted(models, key=lambda m: (m["name"].lower(), m["file"]))

for catalog, lists in CATALOGS.items():
    path = f"{dest}/{catalog}.json"
    try:
        with open(path, encoding="utf-8") as f:
            previous = json.load(f)
    except FileNotFoundError:
        previous = {}
    result = {kind: (load(lists[kind], kind) if kind in lists else []) for kind in KEYS}
    result["upscalers"] = previous.get("upscalers", [])
    if len(result["checkpoints"]) < MINIMUM[catalog]:
        sys.exit(f"error: {catalog} has only {len(result['checkpoints'])} checkpoints")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{catalog}.json")
    for kind in KEYS:
        old = {m["file"] for m in previous.get(kind, [])}
        new = {m["file"] for m in result[kind]}
        added, removed = sorted(new - old), sorted(old - new)
        print(f"  {kind}: {len(new)} ({len(added)} added, {len(removed)} removed)")
        for name in added: print(f"    + {name}")
        for name in removed: print(f"    - {name}")
PY
