import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from quick_match import MatchCache, make_cache_key

class CacheTests(unittest.TestCase):
    def test_content_and_options_invalidate_same_size_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            pdb = Path(folder) / 'reference.pdb'
            pdb.write_bytes(b'pdb1')
            key = make_cache_key(b'old1', b'new1', pdb, 6)
            self.assertEqual(key, make_cache_key(b'old1', b'new1', pdb, 6))
            for old, new, minimum in [(b'old2', b'new1', 6), (b'old1', b'new2', 6), (b'old1', b'new1', 7)]:
                self.assertNotEqual(key, make_cache_key(old, new, pdb, minimum))
            pdb.write_bytes(b'pdb2')
            self.assertNotEqual(key, make_cache_key(b'old1', b'new1', pdb, 6))

    def test_roundtrip_corrupt_and_disabled_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = MatchCache(folder, 'content-key')
            data = ({42: ('name', 42, 55, 9, 'exact')}, [('other', 2, 3, b'abc')], [])
            cache.save('pass1', data)
            self.assertEqual(cache.load('pass1'), data)
            self.assertEqual(len(list(Path(folder).iterdir())), 1)
            (Path(folder) / 'content-key_pass1.pkl').write_bytes(b'broken')
            self.assertIsNone(cache.load('pass1'))
            disabled = MatchCache(str(Path(folder) / 'disabled'), 'key', False)
            disabled.save('pass1', data)
            self.assertIsNone(disabled.load('pass1'))
            self.assertFalse((Path(folder) / 'disabled').exists())

if __name__ == '__main__':
    unittest.main()
