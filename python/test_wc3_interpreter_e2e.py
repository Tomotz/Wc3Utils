#!/usr/bin/env python3
"""
End-to-End Tests for wc3_interpreter.py + Lua LiveCoding breakpoint system.

These tests run the Python interpreter functions and communicate with a Lua
process through real files, testing the complete breakpoint protocol.

Run with: python -m pytest test_wc3_interpreter_e2e.py -v
Or simply: python test_wc3_interpreter_e2e.py
"""

import os
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
    thread_state_is_bp,
    parse_bp_data_file,
    send_data_to_game,
    bp_command_indices,
    handle_command,
    create_file,
    load_file,
    check_for_new_breakpoints,
)


def send_breakpoint_command(thread_id: str, command: str):
    """Test helper that sets breakpoint context and calls send_data_to_game.

    In tests we don't have the monitor thread; we drive the context directly.
    This helper sets current_breakpoint to the given thread_id, then calls
    send_data_to_game which will route via bp_in/bp_out based on that context.

    No lock needed - in the new architecture, all state is owned by the main thread.
    """
    wc3_interpreter.current_breakpoint = (thread_id, {"thread_id": thread_id})
    return send_data_to_game(command)


def wait_for_new_breakpoint(timeout: float = 30.0):
    """Wait for a new breakpoint to be hit and return the thread ID.

    Returns the thread_id (str) if a new breakpoint is detected, None on timeout.
    """
    start = time.time()
    while time.time() - start < timeout:
        # Drain any pending breakpoint events from the queue
        # This updates thread_state_is_bp on the test thread (acting as main thread)
        check_for_new_breakpoints()

        threads = thread_state_is_bp.keys()
        current_threads = set(threads)
        for thread_id in current_threads:
            info = parse_bp_data_file(thread_id)
            if not info:
                continue
            if thread_state_is_bp[thread_id]:
                return thread_id
        time.sleep(0.1)
    return None


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
        thread_state_is_bp.clear()
        # Reset breakpoint context for each test to ensure clean slate
        wc3_interpreter.current_breakpoint = None
        wc3_interpreter.pending_breakpoints = []
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

    def _wait_for_breakpoint(self, timeout: float = 30.0) -> str:
        """Wait for a new breakpoint to be hit and return the thread ID.

        Uses wait_for_new_breakpoint from wc3_interpreter.py to ensure the test
        uses the same breakpoint detection logic as the production code. This
        detects breakpoints by checking if the bp_id for a thread has changed,
        not just if the thread is present - fixing the bug where a second
        breakpoint from the same thread was not detected.

        Uses a large timeout for reliability - actual response should be much faster.
        """
        thread_id = wait_for_new_breakpoint(timeout)
        if thread_id is None:
            self.fail(f"No breakpoint hit within {timeout} seconds")
        return thread_id

    def _wait_for_no_breakpoint(self, timeout: float = 5.0) -> bool:
        """Wait for all breakpoints to be cleared."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            if thread_state_is_bp == dict():
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
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'basic_test')

        # Check that locals are available
        locals_values = info.get('locals_values', {})
        self.assertIn(b'gold', locals_values)
        self.assertIn(b'level', locals_values)
        self.assertEqual(locals_values[b'gold'], b'1000')
        self.assertEqual(locals_values[b'level'], b'5')

        # Inspect gold via command
        result = send_data_to_game("return gold")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "1000")

        # Inspect level via command
        result = send_data_to_game("return level")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "5")

        # Continue execution
        handle_command("continue")

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
        handle_command("continue")

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
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        locals_values = info.get('locals_values', {})
        self.assertEqual(locals_values.get(b'gold'), b'600')

        # Continue execution
        handle_command("continue")

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
        self.assertEqual(len(thread_state_is_bp), 0, "Breakpoint should not have triggered")

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
        self.assertEqual(len(thread_state_is_bp), 0, "Disabled breakpoint should not have triggered")

        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_breakpoint_enable_disable(self):
        """Test dynamically enabling and disabling breakpoints.

        This test verifies that:
        1. A breakpoint can be disabled before it's hit (preventing it from triggering)
        2. A breakpoint can be re-enabled after being disabled (making it trigger again)

        The Lua test has 4 steps with 3 different breakpoints:
        - bp_first: triggers first, then Python disables bp_second
        - bp_second: should NOT trigger (disabled)
        - bp_third: triggers, then Python enables bp_second
        - bp_second (again): should trigger (re-enabled)
        """
        # Start Lua harness with enable/disable breakpoint test
        self._start_lua_harness("breakpoint_enable_disable")

        # 1) Hit bp_first (enabled by default)
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)

        # Verify we're at bp_first
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'bp_first')
        locals_values = info.get('locals_values', {})
        self.assertEqual(locals_values.get(b'step'), b'1')

        # Disable bp_second before continuing (so it won't trigger in step 2)
        handle_command("disable bp_second")

        # Continue execution
        handle_command("continue")

        # 2) bp_second should be skipped (disabled), we should hit bp_third next
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)

        # Verify we're at bp_third (bp_second was skipped)
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'bp_third')
        locals_values = info.get('locals_values', {})
        self.assertEqual(locals_values.get(b'step'), b'3')

        # Re-enable bp_second before continuing (so it will trigger in step 4)
        handle_command("enable bp_second")

        # Continue execution
        handle_command("continue")

        # 3) bp_second should now trigger (re-enabled)
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)

        # Verify we're at bp_second with step=4
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'bp_second')
        locals_values = info.get('locals_values', {})
        self.assertEqual(locals_values.get(b'step'), b'4')

        # Continue execution
        handle_command("continue")

        # Wait for breakpoint to be cleared
        self.assertTrue(self._wait_for_no_breakpoint())

        # Wait for Lua process to finish
        self.lua_process.wait(timeout=5)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_dynamic_breakpoint(self):
        """Test dynamic breakpoint wrapper on a global function.

        This test verifies the dynamic breakpoint wrapper code (same as generated by 'b' command):
        1. Lua harness defines MyGlobalFunction(x, y) and wraps it with breakpoint wrapper
        2. When the function is called with (10, 20), the breakpoint triggers
        3. Verifies the breakpoint is hit with arg1=10, arg2=20
        4. Modifies arg1 to 100
        5. Continues and verifies the function returns 100+20=120
        """
        # Start Lua harness with dynamic breakpoint test
        # The harness sets up the breakpoint wrapper directly (same code as 'b' command generates)
        self._start_lua_harness("dynamic_breakpoint")

        handle_command("break MyGlobalFunction")

        # Wait for breakpoint to be hit when Lua calls MyGlobalFunction(10, 20)
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)

        # Get breakpoint info
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'bp:MyGlobalFunction')

        # Check that args are available (arg1=10, arg2=20)
        locals_values = info.get('locals_values', {})
        self.assertIn(b'arg1', locals_values)
        self.assertIn(b'arg2', locals_values)
        self.assertEqual(locals_values[b'arg1'], b'10')
        self.assertEqual(locals_values[b'arg2'], b'20')

        # Inspect args via command
        result = send_data_to_game("return arg1")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "10")

        result = send_data_to_game("return arg2")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "20")

        # Modify arg1 to 100 - this should change the argument passed to the original function
        result = send_breakpoint_command(thread_id, "arg1 = 100")
        self.assertIsNotNone(result)

        # Verify the change
        result = send_breakpoint_command(thread_id, "return arg1")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "100")

        # Continue execution - the original function should receive (100, 20) and return 120
        handle_command("continue")

        # Wait for breakpoint to be cleared
        self.assertTrue(self._wait_for_no_breakpoint())

        # Wait for Lua process to finish
        self.lua_process.wait(timeout=10)
        self.assertEqual(self.lua_process.returncode, 0)

    def test_breakpoint_four_sequential_with_conditions(self):
        """Test 4 sequential breakpoints with conditions.

        bp1: no condition - should hit
        bp2: condition always true - should hit
        bp3: condition always false - should be skipped
        bp4: no condition - should hit
        bp4 should be hit twice

        Verifies:
        - Breakpoints are hit in order
        - Breakpoints are not skipped before we send continue
        - Local values can be queried and modified at each breakpoint
        - Modified values persist to the next breakpoint
        """
        # Start Lua harness with four-breakpoint test
        self._start_lua_harness("breakpoint_four_sequential")

        # 1) Hit bp1
        thread_id = self._wait_for_breakpoint()
        self.assertIsNotNone(thread_id)
        info = parse_bp_data_file(thread_id)
        self.assertIsNotNone(info)
        self.assertEqual(info.get('bp_id'), b'bp1')
        locals_values = info.get('locals_values', {})
        self.assertEqual(locals_values.get(b'counter'), b'0')
        self.assertEqual(locals_values.get(b'message'), b'start')

        # Modify locals at bp1
        result = send_breakpoint_command(thread_id, "counter = 1")
        self.assertIsNotNone(result)
        result = send_breakpoint_command(thread_id, "message = 'bp1'")
        self.assertIsNotNone(result)

        # Verify the changes via return
        result = send_breakpoint_command(thread_id, "return counter")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "1")
        result = send_breakpoint_command(thread_id, "return message")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "bp1")

        # Continue from bp1
        handle_command("continue")

        # 2) Hit bp2 (condition true, should block)
        thread_id2 = self._wait_for_breakpoint()
        self.assertEqual(thread_id2, thread_id)  # same coroutine/thread
        info2 = parse_bp_data_file(thread_id2)
        self.assertIsNotNone(info2)
        self.assertEqual(info2.get('bp_id'), b'bp2')
        locals_values2 = info2.get('locals_values', {})
        # Values should be what we set at bp1
        self.assertEqual(locals_values2.get(b'counter'), b'1')
        self.assertEqual(locals_values2.get(b'message'), b'bp1')

        # Modify locals at bp2
        result = send_breakpoint_command(thread_id2, "counter = 2")
        self.assertIsNotNone(result)
        result = send_breakpoint_command(thread_id2, "message = 'bp2'")
        self.assertIsNotNone(result)

        # Verify the changes
        result = send_breakpoint_command(thread_id2, "return counter")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "2")
        result = send_breakpoint_command(thread_id2, "return message")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "bp2")

        # Continue from bp2
        handle_command("continue")

        # 3) bp3 has condition false, so it should be skipped.
        # We should go directly to bp4 without seeing a new breakpoint in between.
        thread_id4 = self._wait_for_breakpoint()
        self.assertEqual(thread_id4, thread_id)  # same coroutine/thread
        info4 = parse_bp_data_file(thread_id4)
        self.assertIsNotNone(info4)
        self.assertEqual(info4.get('bp_id'), b'bp4')  # bp3 was skipped
        locals_values4 = info4.get('locals_values', {})
        # Values should be what we set at bp2 (bp3 was skipped)
        self.assertEqual(locals_values4.get(b'counter'), b'2')
        self.assertEqual(locals_values4.get(b'message'), b'bp2')

        # Modify locals at bp4
        result = send_breakpoint_command(thread_id4, "counter = 3")
        self.assertIsNotNone(result)
        result = send_breakpoint_command(thread_id4, "message = 'bp4'")
        self.assertIsNotNone(result)

        # Verify the changes
        result = send_breakpoint_command(thread_id4, "return counter")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "3")
        result = send_breakpoint_command(thread_id4, "return message")
        self.assertIsNotNone(result)
        self.assertEqual(result.strip(), "bp4")

        # Continue from bp4
        handle_command("continue")

        # 4) Hit bp4 again (no condition, should hit)
        thread_id4 = self._wait_for_breakpoint()
        self.assertEqual(thread_id4, thread_id)  # same coroutine/thread
        info4 = parse_bp_data_file(thread_id4)
        self.assertIsNotNone(info4)
        self.assertEqual(info4.get('bp_id'), b'bp4')  # bp3 was skipped
        locals_values4 = info4.get('locals_values', {})
        # Values should be what we set at bp2 (bp3 was skipped)
        self.assertEqual(locals_values4.get(b'counter'), b'3')
        self.assertEqual(locals_values4.get(b'message'), b'bp4')

        # Continue from bp4
        handle_command("continue")

        # Finally, ensure no breakpoints remain and Lua exits successfully
        self.assertTrue(self._wait_for_no_breakpoint())
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
