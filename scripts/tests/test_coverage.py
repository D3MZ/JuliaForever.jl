import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'coverage.py'
spec = importlib.util.spec_from_file_location('coverage_report', SCRIPT)
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.src = self.root / 'src'
        self.src.mkdir()
        self.source = self.src / 'example.jl'
        self.source.write_text('first()\nsecond()\n')
        self.report = self.src / 'example.jl.123.cov'
        self.report.write_text('  1 first()\n  0 second()\n')
        self.baseline = self.root / 'baseline.json'

    def run_report(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(coverage, 'ROOT', self.root), patch('sys.argv', ['coverage.py', *map(str, args)]), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = coverage.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_baseline_detects_lost_lines(self):
        self.assertEqual(self.run_report('--output', self.baseline)[0], 0)
        self.assertEqual(json.loads(self.baseline.read_text())['src/example.jl']['covered'], [1])
        self.report.write_text('  0 first()\n  1 second()\n')
        status, _, error = self.run_report('--baseline', self.baseline)
        self.assertEqual(status, 1)
        self.assertIn('lost lines 1', error)

    def test_baseline_accepts_additional_coverage(self):
        self.run_report('--output', self.baseline)
        (self.src / 'example.jl.456.cov').write_text('  0 first()\n  2 second()\n')
        status, output, _ = self.run_report('--baseline', self.baseline)
        self.assertEqual(status, 0)
        self.assertIn('2/2', output)

    def test_changed_source_invalidates_comparison(self):
        self.run_report('--output', self.baseline)
        self.source.write_text('changed()\nsecond()\n')
        status, _, error = self.run_report('--baseline', self.baseline)
        self.assertEqual(status, 1)
        self.assertIn('source changed', error)

    def test_missing_reports_fail_or_are_reported(self):
        self.run_report('--output', self.baseline)
        (self.src / 'other.jl').write_text('other()\n')
        _, output, _ = self.run_report()
        self.assertIn('No coverage report for 1 source files: src/other.jl', output)
        self.report.unlink()
        with self.assertRaisesRegex(ValueError, 'No Julia source coverage'):
            self.run_report('--baseline', self.baseline)

    def test_missing_baseline_file_fails_comparison(self):
        self.run_report('--output', self.baseline)
        self.source.rename(self.src / 'renamed.jl')
        (self.src / 'renamed.jl.123.cov').write_text('  1 first()\n  0 second()\n')
        status, _, error = self.run_report('--baseline', self.baseline)
        self.assertEqual(status, 1)
        self.assertIn('missing coverage or source changed', error)


if __name__ == '__main__':
    unittest.main()
