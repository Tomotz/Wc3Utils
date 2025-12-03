#!/usr/bin/env python3
"""
End-to-End Tests for wc3_interpreter.py + Lua LiveCoding breakpoint system.

These tests run the Python interpreter functions and communicate with a Lua
process through real files, testing the complete breakpoint protocol.

Run with: python -m pytest test_wc3_interpreter_e2e.py -v
Or simply: python test_wc3_interpreter_e2e.py
"""

import os
import sys
import time
import tempfile
import subprocess
import threading
import unittest
from pathlib import Path

# Import the module under test
import wc3_interpreter
from wc3_interpreter import (
    set_files_root,
    create_file,
    load_file,
    load_nonloadable_file,
    get_breakpoint_threads,
    get_breakpoint_info,
    send_breakpoint_command,
    bp_command_indices,
)


def get_lua_harness_path() -> str:
    """Get the path to the Lua test harness."""
    # The harness is in tests/e2e_lua_harness.lua relative to this file
    this_dir = Path(__file__).parent
    harness_path = this_dir.parent / "tests" / "e2e_lua_harness.lua"
    if not harness_path.exists():
        # Try relative to current working directory
        harness_path = Path("tests") / "e2e_lua_harness.lua"
    return str(harness_path)


class EndToEndBreakpointTest(unittest.TestCase):
    """End-to-end tests for the breakpoint system."""

    def setUp(self):
        """Set up a temporary directory for file I/O.
        
        The directory structure mirrors the real WC3 environment:
        - temp_dir/ is the base (like CustomMapData/)
        - temp_dir/Interpreter/ is where Python looks for files (FILES_ROOT)
        - Lua's FILEIO_MIRROR_ROOT is set to temp_dir/, and LiveCoding.lua
          writes to "Interpreter\\bp_*.txt" which becomes temp_dir/Interpreter/bp_*.txt
        """
        self.temp_dir = tempfile.mkdtemp(prefix="wc3_e2e_test_")
        # Python's FILES_ROOT should point to the Interpreter subdirectory
        # (matching the real-world structure where FILES_ROOT = CustomMapData/Interpreter/)
        self.interpreter_dir = os.path.join(self.temp_dir, "Interpreter")
        os.makedirs(self.interpreter_dir, exist_ok=True)
        set_files_root(self.interpreter_dir)
        # Reset command indices for each test
        bp_command_indices.clear()
        self.lua_process = None
        self.lua_output = []
        self.lua_thread = None

    def tearDown(self):
        """Clean up the temporary directory and Lua process."""
        if self.lua_process and self.lua_process.poll() is None:
            self.lua_process.terminate()
            try:
                self.lua_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.lua_process.kill()
        
        # Clean up temp directory
        import shutil
        try:
            shutil.rmtree(self.temp_dir)
        except Exception:
            pass

    def _start_lua_harness(self, test_name: str) -> subprocess.Popen:
        """Start the Lua harness as a subprocess."""
        harness_path = get_lua_harness_path()
        if not os.path.exists(harness_path):
            self.skipTest(f"Lua harness not found at {harness_path}")
        
        # Start Lua process
        self.lua_process = subprocess.Popen(
            ["lua", harness_path, self.temp_dir, test_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        
        # Start a thread to read Lua output
        def read_output():
            for line in self.lua_process.stdout:
                self.lua_output.append(line.rstrip())
                print(f"[Lua] {line.rstrip()}")
        
        self.lua_thread = threading.Thread(target=read_output, daemon=True)
        self.lua_thread.start()
        
        return self.lua_process

    def _wait_for_breakpoint(self, timeout: float = 10.0) -> str:
        """Wait for a breakpoint to be hit and return the thread ID."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            threads = get_breakpoint_threads()
            if threads:
                return threads[0].decode('utf-8', errors='replace')
            time.sleep(0.1)
        self.fail(f"No breakpoint hit within {timeout} seconds")

    def _wait_for_no_breakpoint(self, timeout: float = 5.0) -> bool:
        """Wait for all breakpoints to be cleared."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            threads = get_breakpoint_threads()
            if not threads:
                return True
            time.sleep(0.1)
        return False

    def test_breakpoint_basic_inspect_locals(self):
        """Test basic breakpoint: hit breakpoint, inspect locals, continue."""
        # Start Lua harness with basic breakpoint test
        self._start_lua_harness("breakpoint_basic")
        
        # Wait for breakpoint to be hit
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)
        
        # Get breakpoint info
        info = get_breakpoint_info(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'basic_test')
        
        # Check that locals are available
        locals_values = info.get('locals_values', {})
        self.assertIn(b'gold', locals_values)
        self.assertIn(b'level', locals_values)
        self.assertEqual(locals_values[b'gold'], b'1000')
        self.assertEqual(locals_values[b'level'], b'5')
        
        # Inspect gold via command
        result = send_breakpoint_command(thread_id, "return gold")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "1000")
        
        # Inspect level via command
        result = send_breakpoint_command(thread_id, "return level")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "5")
        
        # Continue execution
        result = send_breakpoint_command(thread_id, "continue")
        
        # Wait for breakpoint to be cleared
        self.assertTrue(self._wait_for_no_breakpoint())
        
        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_breakpoint_modify_variable(self):
        """Test modifying a variable at a breakpoint."""
        # Start Lua harness with basic breakpoint test
        self._start_lua_harness("breakpoint_basic")
        
        # Wait for breakpoint to be hit
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)
        
        # Modify gold
        result = send_breakpoint_command(thread_id, "gold = 2000")
        self.assertIsNotNone(result)
        
        # Verify the change
        result = send_breakpoint_command(thread_id, "return gold")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "2000")
        
        # Continue execution
        send_breakpoint_command(thread_id, "continue")
        
        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_breakpoint_conditional_true(self):
        """Test conditional breakpoint that triggers (condition is true)."""
        # Start Lua harness with conditional breakpoint test (gold=600, condition: gold > 500)
        self._start_lua_harness("breakpoint_conditional_true")
        
        # Wait for breakpoint to be hit (condition is true, so it should trigger)
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)
        
        # Verify gold value
        info = get_breakpoint_info(thread_id)
        self.assertIsNotNone(info)
        locals_values = info.get('locals_values', {})
        self.assertEqual(locals_values.get(b'gold'), b'600')
        
        # Continue execution
        send_breakpoint_command(thread_id, "continue")
        
        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_breakpoint_conditional_false(self):
        """Test conditional breakpoint that doesn't trigger (condition is false)."""
        # Start Lua harness with conditional breakpoint test (gold=400, condition: gold > 500)
        self._start_lua_harness("breakpoint_conditional_false")
        
        # The breakpoint should NOT trigger because condition is false
        # The Lua process should complete without hitting a breakpoint
        
        # Wait a bit to make sure no breakpoint is hit
        time.sleep(1)
        threads = get_breakpoint_threads()
        self.assertEqual(len(threads), 0, "Breakpoint should not have triggered")
        
        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_breakpoint_disabled(self):
        """Test disabled breakpoint (should not trigger)."""
        # Start Lua harness with disabled breakpoint test
        self._start_lua_harness("breakpoint_disabled")
        
        # The breakpoint should NOT trigger because it's disabled
        
        # Wait a bit to make sure no breakpoint is hit
        time.sleep(1)
        threads = get_breakpoint_threads()
        self.assertEqual(len(threads), 0, "Disabled breakpoint should not have triggered")
        
        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)


class FileProtocolTest(unittest.TestCase):
    """Tests for the file protocol between Python and Lua."""

    def setUp(self):
        """Set up a temporary directory for file I/O."""
        self.temp_dir = tempfile.mkdtemp(prefix="wc3_e2e_protocol_")
        set_files_root(self.temp_dir)

    def tearDown(self):
        """Clean up the temporary directory."""
        import shutil
        try:
            shutil.rmtree(self.temp_dir)
        except Exception:
            pass

    def test_create_and_load_file_roundtrip(self):
        """Test that create_file and load_file work correctly together."""
        test_file = os.path.join(self.temp_dir, "test.txt")
        test_content = "hello world"
        
        create_file(test_file, test_content)
        result = load_file(test_file)
        
        self.assertEqual(result, test_content.encode())

    def test_create_file_long_content(self):
        """Test creating a file with content longer than 255 bytes."""
        test_file = os.path.join(self.temp_dir, "long_test.txt")
        test_content = "x" * 500
        
        create_file(test_file, test_content)
        result = load_file(test_file)
        
        self.assertEqual(result, test_content.encode())

    def test_breakpoint_threads_file_format(self):
        """Test reading bp_threads.txt format."""
        # Create a bp_threads.txt file with multiple thread IDs
        threads_file = os.path.join(self.temp_dir, "bp_threads.txt")
        with open(threads_file, 'w') as f:
            f.write("thread1\nthread2\nthread3")
        
        threads = get_breakpoint_threads()
        self.assertEqual(len(threads), 3)
        self.assertIn(b'thread1', threads)
        self.assertIn(b'thread2', threads)
        self.assertIn(b'thread3', threads)

    def test_breakpoint_data_file_format(self):
        """Test reading bp_data_<thread_id>.txt format."""
        # Create a bp_data file with the expected format
        FIELD_SEP = chr(31)  # ASCII 31 = unit separator
        data = f"bp_id{FIELD_SEP}test_bp{FIELD_SEP}stack{FIELD_SEP}stack trace here{FIELD_SEP}gold{FIELD_SEP}1000{FIELD_SEP}level{FIELD_SEP}5"
        
        data_file = os.path.join(self.temp_dir, "bp_data_test_thread.txt")
        with open(data_file, 'w') as f:
            f.write(data)
        
        info = get_breakpoint_info("test_thread")
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'test_bp')
        self.assertEqual(info.get('stack'), b'stack trace here')
        self.assertEqual(info.get('locals_values', {}).get(b'gold'), b'1000')
        self.assertEqual(info.get('locals_values', {}).get(b'level'), b'5')


if __name__ == '__main__':
    unittest.main(verbosity=2)
