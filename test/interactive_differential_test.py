import os
import unittest
from types import SimpleNamespace

from interactive_differential import compare, completion_present, cursor_differs, depot_path, pad, page, parse, report, screenshots, selected, setting


class InteractiveComparison(unittest.TestCase):
    def test_compares_text_and_visual_attributes(self):
        pi = parse('\x1b[1;31moption\x1b[0m\nnext\n')
        self.assertEqual(compare(pi, parse('\x1b[1;31moption\x1b[0m\nnext\n')), [])
        self.assertIn('style', compare(pi, parse('\x1b[31moption\x1b[0m\nnext\n'))[0])
        self.assertIn('text', compare(pi, parse('\x1b[1;31moption\x1b[0m\nmissing\n'))[0])
        self.assertEqual(compare(parse('\x1b[38;2;1;2;3mcolor'), parse('\x1b[38;2;1;2;3mcolor')), [])
        self.assertIn('style', compare(parse('\x1b[38;5;42mcolor'), parse('\x1b[38;5;43mcolor'))[0])
        self.assertEqual(compare(pad(parse('界\n'), 4, 1), pad(parse('界  \n'), 4, 1)), [])
        self.assertFalse(cursor_differs('0 1 2', '0 4 5'))
        self.assertTrue(cursor_differs('1 1 2', '1 4 5'))

    def test_missing_menu_and_selection_are_reported(self):
        screen = '  → Auto-compact                      true\n  (1/33)\n'
        self.assertEqual(selected(screen), ('Auto-compact', 1, 33))
        self.assertEqual(setting(screen), ('Auto-compact', 'true', 1, 33))
        self.assertIsNone(selected('Unknown command: /settings\n'))
        result = report('settings', parse(screen), parse('Unknown command: /settings\n'), required='Auto-compact')
        self.assertFalse(result['match'])
        self.assertIn('missing', ' '.join(result['differences']).lower())

    def test_completion_and_screenshot_are_escaped(self):
        self.assertTrue(completion_present('→ settings  Open settings menu', 'settings'))
        self.assertFalse(completion_present('> /settings', 'settings'))
        rendered = page('one', parse('<script>\n'), parse('safe\n'), [], 'monospace')
        self.assertIn('&lt;script&gt;', rendered)
        self.assertNotIn('<script>', rendered)
        rendered = page('cursor', parse('界x\n'), parse('safe\n'), [], 'monospace', {'pi': '1 2 0'})
        self.assertIn('class="cursor"', rendered)
        rendered = page('size', parse('a'), parse('b'), [], 'monospace', dimensions={'pi': (100, 30), 'jf': (100, 30)})
        self.assertEqual(rendered.count('width:100ch;height:540px'), 2)
        result = SimpleNamespace(errors=[])
        screenshots(result, None)
        self.assertIn('Chromium', result.errors[0])

    def test_isolated_home_retains_julia_depot(self):
        self.assertEqual(depot_path({'HOME': '/original'}), os.path.join('/original', '.julia') + os.pathsep)
        self.assertEqual(depot_path({'JULIA_DEPOT_PATH': '/custom'}), '/custom')


if __name__ == '__main__':
    unittest.main()
