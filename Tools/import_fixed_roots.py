#!/usr/bin/env python3
"""Import absent reviewed fixed lexical forms from the pinned source inventory.

Keep existing lexical identities and weights. Fixed roots cannot acquire noun
or verb suffixes. Reduplication components require an explicit reviewed surface list. A count of 10 is a declared calibration floor, not frequency.
"""
import argparse
import json
from pathlib import Path


def lower(text):
    return text.translate(str.maketrans({"I": "ı", "İ": "i"})).lower()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("inventory", "runtime", "roots", "wordlist", "plan"):
        p.add_argument("--" + name, required=True, type=Path)
    p.add_argument("--classes", nargs="+", choices=["Interj", "Conj", "Postp", "Dup"], default=["Interj", "Conj"])
    p.add_argument("--surfaces", nargs="+", help="Explicit reviewed source lemmas; required for Dup")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    if "Dup" in args.classes and not args.surfaces:
        p.error("Dup imports require an explicit reviewed --surfaces list")
    reviewed = set(args.surfaces) if args.surfaces else None
    source = json.loads(args.inventory.read_text())["entries"]
    recognized = {e["tested_surface"] for e in json.loads(args.runtime.read_text())["entries"] if e["recognized"]}
    original = args.roots.read_text()
    present = {line.split("\t")[0] for line in original.splitlines()
               if line and not line.startswith("#")}
    counts = {}
    for line in args.wordlist.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 2 and not line.startswith("#"):
            try:
                counts[fields[0]] = float(fields[1])
            except ValueError:
                pass
    changes = []
    deferred = []
    for entry in source:
        if reviewed is not None and lower(entry["lemma"]) not in reviewed:
            continue
        if entry["raw_pos"].split(",")[0] not in args.classes:
            continue
        if entry["source"] == "proper.dict" or entry["lemma"] == "afedersinin":
            deferred.append({"source": entry, "reason": "proper-source entry or suspected source typo; manual review required"})
            continue
        lemma = lower(entry["lemma"])
        for surface in dict.fromkeys((lemma, lemma.translate(str.maketrans("âîû", "aiu")))):
            if not surface.isalpha() or surface in present or surface in recognized:
                continue
            count = counts.get(surface, 10)
            if count <= 0:
                count = 10
            changes.append({"surface": surface, "pos": "fixed", "count": count,
                            "weight_source": "wordlist" if surface in counts else "calibration_floor_10",
                            "source": entry})
            present.add(surface)
    args.plan.write_text(json.dumps({"scope": "Absent surfaces from reviewed classes only", "classes": args.classes, "reviewed_surfaces": args.surfaces,
                                    "added_records": len(changes), "changes": changes, "deferred": deferred},
                                   ensure_ascii=False, indent=2) + "\n")
    if args.apply and changes:
        lines = [f"{c['surface']}\tfixed\t{c['count']:g}\tnone\t0" for c in changes]
        pending = args.roots.with_suffix(args.roots.suffix + ".fixed.tmp")
        pending.write_text(original.rstrip("\n") + "\n" + "\n".join(lines) + "\n")
        pending.replace(args.roots)
    print(json.dumps({"added_records": len(changes), "applied": args.apply}))


if __name__ == "__main__":
    main()
