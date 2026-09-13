import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from inspect_snapshot import repeated_code_runs, text_section, range_is_readable

class SnapshotTests(unittest.TestCase):
    def test_repetition_and_padding(self):
        pattern = bytes(range(64)) + b'X'*64
        self.assertEqual(repeated_code_runs(pattern*32, 4096), [{'rva': 4096, 'blocks': 32, 'bytes': 4096}])
        self.assertEqual(repeated_code_runs(b'\xcc'*8192, 4096), [])
        self.assertEqual(repeated_code_runs(pattern*2, 4096), [])
    def test_unreadable_page_boundaries(self):
        bad = [8192, 16384]
        self.assertTrue(range_is_readable(4096, 4096, bad))
        self.assertFalse(range_is_readable(8191, 2, bad))
        self.assertFalse(range_is_readable(8192, 1, bad))
        self.assertFalse(range_is_readable(9000, 50, bad))
        self.assertTrue(range_is_readable(12288, 4096, bad))
        self.assertFalse(range_is_readable(0, 0, bad))
    def test_invalid_image(self):
        with self.assertRaises(ValueError): text_section(b'not a PE')

if __name__ == '__main__': unittest.main()
