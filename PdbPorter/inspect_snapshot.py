"""Inspect snapshot quality before matching; no game process is touched."""
import argparse
import bisect
import hashlib
import json
import struct
from pathlib import Path


def text_section(data):
    if data[:2] != b'MZ':
        raise ValueError('Not a PE image')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe+4] != b'PE\0\0':
        raise ValueError('Invalid PE signature')
    count = struct.unpack_from('<H', data, pe+6)[0]
    optional = struct.unpack_from('<H', data, pe+20)[0]
    for i in range(count):
        section = pe + 24 + optional + 40*i
        if data[section:section+8].rstrip(b'\0') != b'.text':
            continue
        virtual_size, rva, raw_size, offset = struct.unpack_from('<IIII', data, section+8)
        size = min(virtual_size, raw_size)
        if not size or offset + size > len(data):
            raise ValueError('Truncated .text section')
        return rva, data[offset:offset+size]
    raise ValueError('No .text section')


def repeated_code_runs(text, rva):
    """Find long 128-byte runs with identical non-padding 64-byte prefixes.

    This flags suspicious repetition, not proof that any code is decrypted.
    Normal repeated short compiler stubs can still require human review.
    """
    result = []
    first = 0
    previous = None
    count = 0
    for offset in range(0, len(text) - 63, 128):
        prefix = text[offset:offset+64]
        if prefix == previous and len(set(prefix)) >= 8:
            count += 1
        else:
            if count >= 16:
                result.append({'rva': rva+first, 'blocks': count, 'bytes': count*128})
            first, count, previous = offset, 1, prefix
    if count >= 16:
        result.append({'rva': rva+first, 'blocks': count, 'bytes': count*128})
    return result


def range_is_readable(rva, size, unreadable_pages):
    """unreadable_pages must be sorted; ranges are half-open."""
    if size <= 0:
        return False
    index = bisect.bisect_left(unreadable_pages, (rva // 4096) * 4096)
    return index == len(unreadable_pages) or unreadable_pages[index] >= rva + size


def inspect(path, compare=None):
    path = Path(path)
    data = path.read_bytes()
    rva, text = text_section(data)
    result = {'path': str(path), 'sha256': hashlib.sha256(data).hexdigest(),
              'text_sha256': hashlib.sha256(text).hexdigest(), 'text_rva': rva,
              'text_size': len(text), 'suspicious_runs': repeated_code_runs(text, rva)}
    sidecar = Path(str(path)+'.json')
    if sidecar.exists():
        result['capture'] = json.loads(sidecar.read_text(encoding='utf-8-sig'))
    if compare:
        other_rva, other_text = text_section(Path(compare).read_bytes())
        if (rva, len(text)) != (other_rva, len(other_text)):
            raise ValueError('Cannot compare different .text layouts')
        result['changed_text_bytes'] = sum(a != b for a, b in zip(text, other_text))
    result['repeated_code_bytes'] = sum(run['bytes'] for run in result['suspicious_runs'])
    result['requires_review'] = bool(result['repeated_code_bytes'] >= max(65536, len(text) // 100) or result.get('capture', {}).get('unreadable_pages', 0))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot')
    parser.add_argument('--compare', help='Earlier snapshot of the same build')
    parser.add_argument('--json', action='store_true', help='Print full machine-readable details')
    args = parser.parse_args()
    result = inspect(args.snapshot, args.compare)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Snapshot: {result['path']}")
        print(f"SHA256: {result['sha256']}")
        print(f"Suspicious regions: {len(result['suspicious_runs'])}; unreadable pages: {result.get('capture', {}).get('unreadable_pages', 'not recorded')}")
        if 'changed_text_bytes' in result:
            print(f"Changed code bytes: {result['changed_text_bytes']}")
        print('REVIEW REQUIRED' if result['requires_review'] else 'No configured quality flags; real-code completeness still requires verification.')
    return 2 if result['requires_review'] else 0

if __name__ == '__main__':
    raise SystemExit(main())
