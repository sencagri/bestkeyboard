"""Compile the repository's exact ZipReader in an isolated macOS subprocess.
Synthetic ZIP data only; no app files or user imports are accessed.
"""
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
reader = (root / 'Packages/KeyboardCore/Sources/KBFoundation/BoundedZIPReader.swift').read_text()
with tempfile.TemporaryDirectory(prefix='keyboard-zip-audit-') as temp:
    temp = Path(temp)
    swift = temp / 'main.swift'
    swift.write_text('import Foundation\nimport Compression\n' + reader + '''
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let result = BoundedZIPReader.firstEntry(in: data, matching: { $0.hasSuffix(".txt") })
print(result.map { String(decoding: $0, as: UTF8.self) } ?? "nil")
''')
    exe = temp / 'probe'
    subprocess.run(['swiftc', str(swift), '-o', str(exe)], check=True, capture_output=True)
    valid = io.BytesIO()
    with zipfile.ZipFile(valid, 'w', compression=zipfile.ZIP_STORED) as archive:
        archive.writestr('chat.txt', 'synthetic control')
    malformed = bytearray(68)
    struct.pack_into('<I', malformed, 0, 0x02014B50)
    struct.pack_into('<H', malformed, 28, 4096)  # name extends past archive
    struct.pack_into('<I', malformed, 46, 0x06054B50)
    struct.pack_into('<H', malformed, 56, 1)
    struct.pack_into('<I', malformed, 62, 0)
    results = []
    for name, data in [('valid_stored_zip', valid.getvalue()), ('truncated_directory_name', malformed)]:
        fixture = temp / (name + '.zip')
        fixture.write_bytes(data)
        p = subprocess.run([str(exe), str(fixture)], capture_output=True, text=True)
        results.append({'case': name, 'fixture_bytes': len(data), 'returncode': p.returncode,
                        'stdout': p.stdout.strip(), 'stderr_first_lines': p.stderr.splitlines()[:5]})
    output = root / 'audits/implementation-phase1-zip.json'
    output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(results, ensure_ascii=False, indent=2))
