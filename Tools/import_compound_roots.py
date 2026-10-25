#!/usr/bin/env python3
"""Review pinned dictionary compounds; apply only explicitly supported mappings.

The inventory retains source filename, line and entry. Existing weights are
preserved; absent corpus counts use a declared floor, not an invented frequency.
No dictionary instructions are executed. Run without --apply to review the plan.
"""
import argparse
import collections
import json
from pathlib import Path
import re

VOWELS = "aeıioöuüâîû"


def lower(word):
    return word.translate(str.maketrans({"I": "ı", "İ": "i"})).lower()


def plain(word):
    return word.translate(str.maketrans("âîû", "aiu"))


def supported_surface(lemma, stem):
    if not lemma.isalpha() or not stem.isalpha() or lemma[-1:] not in "ıiuü":
        return False
    vowels = [c for c in stem if c in VOWELS]
    if not vowels:
        return False
    harmony = dict(zip("aâıeiîouûöü", "ıııiiiuuuüü"))
    if lemma[-1] != harmony[vowels[-1]]:
        return False
    target = lemma[:-1]
    if stem[-1] in VOWELS:
        return target == stem + "s"
    variants = {stem}
    if len(stem) > 2 and stem[-2] in VOWELS:
        variants.add(stem[:-2] + stem[-1])
    for variant in tuple(variants):
        for final in {"p": "b", "ç": "c", "t": "d", "k": "ğg"}.get(variant[-1], ""):
            variants.add(variant[:-1] + final)
    return target in variants


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("inventory", "roots", "wordlist", "plan"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    entries = json.loads(args.inventory.read_text())["entries"]
    lines = args.roots.read_text().splitlines()
    existing = collections.defaultdict(list)
    for index, line in enumerate(lines):
        if line and not line.startswith("#"):
            row = line.split("\t")
            existing[(row[0], row[1])].append((index, row))
    counts = {}
    for line in args.wordlist.read_text().splitlines():
        if line and not line.startswith("#"):
            word, count = line.split("\t")[:2]
            counts[word] = count
    candidates = collections.defaultdict(list)
    skipped = []
    for entry in entries:
        if "CompoundP3sg" not in entry["entry"]:
            continue
        raw = entry["entry"]
        attrs = re.search(r"A:([^;\]]+)", raw)
        names = {a.strip() for a in attrs.group(1).split(",")} if attrs else set()
        parts = re.search(r"Roots:([^;\]]+)", raw)
        if not parts or names - {"CompoundP3sg", "Ext", "Informal"} or entry["pos"] not in {"noun", "adjective", "adverb"}:
            skipped.append({"entry": entry, "reason": "unsupported_source_attributes"})
            continue
        lemma, stem = lower(entry["lemma"]), lower(parts.group(1).replace("-", ""))
        for surface, base in sorted({(lemma, stem), (plain(lemma), plain(stem))}):
            if not supported_surface(surface, base):
                skipped.append({"entry": entry, "surface": surface, "stem": base,
                                "reason": "requires_specific_stem_review"})
            else:
                candidates[(surface, entry["pos"])].append((base, entry))
    changes = []
    for (surface, pos), sources in sorted(candidates.items()):
        bases = {base for base, _ in sources}
        rows = existing[(surface, pos)]
        if len(bases) != 1 or len(rows) > 1:
            skipped.append({"surface": surface, "reason": "ambiguous_source_or_existing_root"})
            continue
        base = next(iter(bases))
        before = rows[0][1] if rows else None
        if before:
            after = before + [""] * (10 - len(before))
            features = set(filter(None, after[8].split(",")))
            if after[1] == "verb" or after[3:5] != ["none", "0"] or after[7] or features - {"possessiveCompound", "inverseHarmony"}:
                skipped.append({"surface": surface, "reason": "existing_metadata_needs_review"})
                continue
            if after[9] and after[9] != base:
                skipped.append({"surface": surface, "reason": "conflicting_compound_stem"})
                continue
            features.add("possessiveCompound")
            after[8], after[9] = ",".join(sorted(features)), base
            weight_source = "preserved existing root weight"
        else:
            after = [surface, pos, counts.get(surface, "10"), "none", "0", "", "", "", "possessiveCompound", base]
            weight_source = "wordlist.tsv" if surface in counts else "calibration floor 10; not measured frequency"
        if before == after:
            continue
        changes.append({"surface": surface, "pos": pos, "before": before, "after": after,
                        "weight_source": weight_source, "sources": [entry for _, entry in sources]})
    report = {"scope": "Source-backed compound lemmas and underlying stems; ambiguous/unsupported entries deferred.",
              "changes": changes, "skipped": skipped}
    args.plan.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if args.apply:
        additions = []
        for change in changes:
            if change["before"] is None:
                additions.append("\t".join(change["after"]))
            else:
                index, row = existing[(change["surface"], change["pos"])][0]
                assert row == change["before"]
                lines[index] = "\t".join(change["after"])
        if additions:
            lines.extend(["", "# Source-reviewed lexical compounds; explicit underlying stems.",
                          "# Provenance and weight sources are retained in the compound import plan."] + additions)
        temporary = args.roots.with_suffix(".tsv.tmp")
        temporary.write_text("\n".join(lines) + "\n")
        temporary.replace(args.roots)
    print(json.dumps({"changes": len(changes), "added": sum(c["before"] is None for c in changes),
                      "skipped": len(skipped), "applied": args.apply}))


if __name__ == "__main__":
    main()
