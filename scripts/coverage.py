#!/usr/bin/env python3
"""Summarize Julia .cov files and optionally compare a same-source baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent


def collect():
    result = {}
    for source in sorted((ROOT / 'src').rglob('*.jl')):
        reports = sorted(source.parent.glob(source.name + '.*.cov'))
        if not reports:
            continue
        counts = {}
        for report in reports:
            for index, line in enumerate(report.read_text().splitlines(), 1):
                match = re.match(r'^\s*(\d+|-)\s', line)
                if not match:
                    raise ValueError(f'Invalid coverage line: {report}:{index}')
                count = match.group(1)
                if count != '-':
                    counts[index] = counts.get(index, 0) + int(count)
        result[source.relative_to(ROOT).as_posix()] = {
            'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'executable': sorted(counts),
            'covered': sorted(index for index, count in counts.items() if count > 0),
        }
    if not result:
        raise ValueError('No Julia source coverage reports found. Run scripts/ci.jl --coverage first.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Save a JSON baseline or report')
    parser.add_argument('--baseline', type=Path, help='Fail if any previously covered line loses coverage')
    args = parser.parse_args()
    result = collect()
    covered = sum(len(item['covered']) for item in result.values())
    total = sum(len(item['executable']) for item in result.values())
    if not total:
        raise ValueError('Coverage reports have no instrumented source lines.')
    sources = {p.relative_to(ROOT).as_posix() for p in (ROOT / 'src').rglob('*.jl')}
    missing = sorted(sources - set(result))
    print(f'Julia source line coverage: {covered}/{total} ({100 * covered / total:.2f}%) across {len(result)} files')
    if missing:
        print(f'No coverage report for {len(missing)} source files: {", ".join(missing)}')
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        problems = []
        for path, old in baseline.items():
            current = result.get(path)
            if current is None or current['sha256'] != old['sha256']:
                problems.append(f'{path}: missing coverage or source changed; recapture baseline')
                continue
            lost = sorted(set(old['covered']) - set(current['covered']))
            if lost:
                problems.append(f'{path}: lost lines {", ".join(map(str, lost))}')
        if problems:
            print('\n'.join(problems), file=sys.stderr)
            return 1
        print('No previously covered source lines lost.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
