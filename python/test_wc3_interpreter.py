#!/usr/bin/env python3
"""
Tests for wc3_interpreter.py

These tests can run on any Linux machine without WC3.
Run with: python -m pytest test_wc3_interpreter.py -v
Or simply: python test_wc3_interpreter.py
"""

import os
import tempfile
import unittest
from contextlib import contextmanager
from unittest.mock import patch

# Import the module under test
import wc3_interpreter
from wc3_interpreter import (
    load_file,
    parse_nonloadable_file,
    create_file,
    wrap_with_oninit_immediate,
    find_lua_function,
    inject_into_function,
    modify_function,
    send_file_to_game,
    FILE_PREFIX,
    FILE_POSTFIX,
    LINE_PREFIX,
    LINE_POSTFIX,
    ONINIT_IMMEDIATE_WRAPPER,
    ONINIT_IMMEDIATE_WRAPPER_END,
)


class TestLoadFile(unittest.TestCase):
    """Tests for the load_file function that parses WC3 preload format files."""

    def test_load_file_nonexistent(self):
        """Test that load_file returns None for non-existent files."""
        result = load_file("/nonexistent/path/to/file.txt")
        self.assertIsNone(result)

    def test_load_file_empty_content(self):
        """Test loading a file with no matching preload content."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write("some random content without preload format")
            temp_path = f.name
        try:
            result = load_file(temp_path)
            self.assertEqual(result, b'')
        finally:
            os.unlink(temp_path)

    def test_load_file_single_chunk(self):
        """Test loading a file with a single preload chunk."""
        with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
            # Create content in the expected preload format
            content = b'call Preload( "]]i([[hello world]])--[[" )'
            f.write(content)
            temp_path = f.name
        try:
            result = load_file(temp_path)
            self.assertEqual(result, b'hello world')
        finally:
            os.unlink(temp_path)

    def test_load_file_multiple_chunks(self):
        """Test loading a file with multiple preload chunks."""
        with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
            content = b'call Preload( "]]i([[hello]])--[[" )\ncall Preload( "]]i([[ world]])--[[" )'
            f.write(content)
            temp_path = f.name
        try:
            result = load_file(temp_path)
            self.assertEqual(result, b'hello world')
        finally:
            os.unlink(temp_path)


class TestCreateFile(unittest.TestCase):
    """Tests for the create_file function that creates WC3 preload format files."""

    def test_create_file_short_content(self):
        """Test creating a file with short content (single chunk)."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            temp_path = f.name
        try:
            create_file(temp_path, "hello world")
            # Verify the file was created and can be loaded back
            result = load_file(temp_path)
            self.assertEqual(result, b'hello world')
        finally:
            os.unlink(temp_path)

    def test_create_file_long_content(self):
        """Test creating a file with long content (multiple chunks)."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            temp_path = f.name
        try:
            # Create content longer than 255 chars to force multiple chunks
            long_content = "x" * 300
            create_file(temp_path, long_content)
            result = load_file(temp_path)
            self.assertEqual(result, long_content.encode())
        finally:
            os.unlink(temp_path)

    def test_create_file_special_characters(self):
        """Test creating a file with special characters."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            temp_path = f.name
        try:
            content = "hello\nworld\ttab"
            create_file(temp_path, content)
            result = load_file(temp_path)
            self.assertEqual(result, content.encode())
        finally:
            os.unlink(temp_path)

    def test_create_load_roundtrip(self):
        """Test that create_file and load_file are inverse operations."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            temp_path = f.name
        try:
            test_cases = [
                "simple text",
                "with\nnewlines",
                "a" * 255,  # exactly one chunk
                "b" * 256,  # just over one chunk
                "c" * 1000,  # multiple chunks
                "special chars: !@#$%^&*()",
            ]
            for content in test_cases:
                create_file(temp_path, content)
                result = load_file(temp_path)
                self.assertEqual(result, content.encode(), f"Failed for content: {content[:50]}...")
        finally:
            os.unlink(temp_path)


class TestWrapWithOninitImmediate(unittest.TestCase):
    """Tests for the wrap_with_oninit_immediate function."""

    def test_wrap_simple_content(self):
        """Test wrapping simple Lua content."""
        content = "print('hello')"
        result = wrap_with_oninit_immediate(content)
        self.assertTrue(result.startswith(ONINIT_IMMEDIATE_WRAPPER))
        self.assertTrue(result.endswith(ONINIT_IMMEDIATE_WRAPPER_END))
        self.assertIn(content, result)

    def test_wrap_with_return(self):
        """Test wrapping content with a return statement."""
        content = "return 42"
        result = wrap_with_oninit_immediate(content)
        self.assertIn(content, result)
        # The wrapper should capture the return value
        self.assertIn("__wc3_interpreter_result", result)

    def test_wrap_multiline_content(self):
        """Test wrapping multiline Lua content."""
        content = """local x = 1
local y = 2
return x + y"""
        result = wrap_with_oninit_immediate(content)
        self.assertIn(content, result)


class TestFindLuaFunction(unittest.TestCase):
    """Tests for the find_lua_function function."""

    def test_find_by_name_simple(self):
        """Test finding a simple function by name."""
        content = """function hello()
    print("hello")
end"""
        result = find_lua_function(content, func_name="hello")
        self.assertIsNotNone(result)
        start, end, body = result
        self.assertIn("function hello()", body)
        self.assertIn("print", body)
        self.assertIn("end", body)

    def test_find_by_name_not_found(self):
        """Test that None is returned when function is not found."""
        content = """function hello()
    print("hello")
end"""
        result = find_lua_function(content, func_name="goodbye")
        self.assertIsNone(result)

    def test_find_by_line_number(self):
        """Test finding a function by line number."""
        content = """-- comment
function hello()
    print("hello")
end
function world()
    print("world")
end"""
        # Line 3 is inside the hello function
        result = find_lua_function(content, line_number=3)
        self.assertIsNotNone(result)
        _, _, body = result
        self.assertIn("function hello()", body)

    def test_find_nested_function(self):
        """Test finding a function with nested functions."""
        content = """function outer()
    function inner()
        print("inner")
    end
    print("outer")
end"""
        result = find_lua_function(content, func_name="outer")
        self.assertIsNotNone(result)
        _, _, body = result
        self.assertIn("function outer()", body)
        self.assertIn("function inner()", body)
        # Should include both ends
        self.assertEqual(body.count("end"), 2)

    def test_find_with_local_function_by_name_not_supported(self):
        """Test that local functions cannot be found by name (limitation of current implementation)."""
        content = """local function myFunc()
    return 42
end"""
        # The regex pattern is `function\s+{func_name}` which doesn't match `local function`
        result = find_lua_function(content, func_name="myFunc")
        self.assertIsNone(result)

    def test_find_local_function_by_line_number_not_supported(self):
        """Test that local functions cannot be found by line number either (limitation).

        The implementation uses regex `r'\\s*function\\b'` which doesn't match
        `local function` because `local ` comes before `function`.
        """
        content = """local function myFunc()
    return 42
end"""
        # Line 2 is inside the function, but the regex won't match
        result = find_lua_function(content, line_number=2)
        self.assertIsNone(result)


class TestInjectIntoFunction(unittest.TestCase):
    """Tests for the inject_into_function function."""

    def test_inject_after_header(self):
        """Test injecting code after the function header."""
        content = """function hello()
    print("hello")
end"""
        result = find_lua_function(content, func_name="hello")
        self.assertIsNotNone(result)
        start, end, _ = result

        new_content = inject_into_function(content, start, end, "    -- injected")
        self.assertIn("-- injected", new_content)
        # The injected line should come before print
        inject_pos = new_content.find("-- injected")
        print_pos = new_content.find("print")
        self.assertLess(inject_pos, print_pos)

    def test_inject_at_specific_line(self):
        """Test injecting code at a specific line."""
        content = """function hello()
    local x = 1
    local y = 2
    return x + y
end"""
        result = find_lua_function(content, func_name="hello")
        self.assertIsNotNone(result)
        start, end, _ = result

        # Inject after line 2 (after local x = 1)
        new_content = inject_into_function(content, start, end, "    -- injected", after_line=2)
        self.assertIn("-- injected", new_content)


class TestModifyFunction(unittest.TestCase):
    """Tests for the modify_function function."""

    def test_modify_function_by_name(self):
        """Test modifying a function by name."""
        lua_files = {
            "test.lua": """function hello()
    print("hello")
end"""
        }
        new_content = modify_function(lua_files, func_name="hello", inject_str="    -- modified")
        self.assertIn("-- modified", new_content)

    def test_modify_function_in_specific_file(self):
        """Test modifying a function in a specific file."""
        lua_files = {
            "file1.lua": "function foo() end",
            "file2.lua": """function hello()
    print("hello")
end"""
        }
        new_content = modify_function(
            lua_files,
            func_name="hello",
            target_file="file2.lua",
            inject_str="    -- modified"
        )
        self.assertIn("-- modified", new_content)

    def test_modify_function_not_found(self):
        """Test that ValueError is raised when function is not found."""
        lua_files = {
            "test.lua": "function hello() end"
        }
        with self.assertRaises(ValueError):
            modify_function(lua_files, func_name="nonexistent", inject_str="-- test")


class TestFileFormat(unittest.TestCase):
    """Tests for the file format constants and structure."""

    def test_file_prefix_structure(self):
        """Test that FILE_PREFIX has the expected structure."""
        self.assertIn("PreloadFiles", FILE_PREFIX)
        self.assertIn("PreloadStart", FILE_PREFIX)
        self.assertIn("beginusercode", FILE_PREFIX)

    def test_file_postfix_structure(self):
        """Test that FILE_POSTFIX has the expected structure."""
        self.assertIn("BlzSetAbilityTooltip", FILE_POSTFIX)
        self.assertIn("endusercode", FILE_POSTFIX)
        self.assertIn("PreloadEnd", FILE_POSTFIX)

    def test_line_prefix_suffix(self):
        """Test the line prefix and suffix format."""
        self.assertIn("Preload", LINE_PREFIX)
        self.assertIn("i([[", LINE_PREFIX)
        self.assertIn("]])", LINE_POSTFIX)


class TestLoadNonloadableFile(unittest.TestCase):
    """Tests for the parse_nonloadable_file function that parses WC3 nonloadable preload format files."""

    def test_parse_nonloadable_file_nonexistent(self):
        """Test that parse_nonloadable_file returns None for non-existent files."""
        result = parse_nonloadable_file("/nonexistent/path/to/file.txt")
        self.assertIsNone(result)

    def test_parse_nonloadable_file_single_chunk(self):
        """Test loading a nonloadable file with a single Preload chunk."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            # Create content in the expected nonloadable preload format
            content = '''function PreloadFiles takes nothing returns nothing

\tcall PreloadStart()
\tcall Preload( "hello world" )
\tcall PreloadEnd( 0.0 )

endfunction'''
            f.write(content)
            temp_path = f.name
        try:
            result = parse_nonloadable_file(temp_path)
            self.assertEqual(result, b'hello world')
        finally:
            os.unlink(temp_path)

    def test_parse_nonloadable_file_multiple_chunks(self):
        """Test loading a nonloadable file with multiple Preload chunks."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            content = '''function PreloadFiles takes nothing returns nothing

\tcall PreloadStart()
\tcall Preload( "hello " )
\tcall Preload( "world" )
\tcall PreloadEnd( 0.0 )

endfunction'''
            f.write(content)
            temp_path = f.name
        try:
            result = parse_nonloadable_file(temp_path)
            self.assertEqual(result, b'hello world')
        finally:
            os.unlink(temp_path)

    def test_parse_nonloadable_file_with_newlines_in_payload(self):
        """Test loading a nonloadable file with newlines in the payload."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            # Newlines within the payload should be preserved
            content = '''function PreloadFiles takes nothing returns nothing

\tcall PreloadStart()
\tcall Preload( "line1" )
\tcall Preload( "line2" )
\tcall PreloadEnd( 0.0 )

endfunction'''
            f.write(content)
            temp_path = f.name
        try:
            result = parse_nonloadable_file(temp_path)
            self.assertEqual(result, b'line1line2')
        finally:
            os.unlink(temp_path)

    def test_parse_nonloadable_file_expected_format(self):
        """Test that parse_nonloadable_file correctly parses the expected WC3 nonloadable format.

        The expected format is:
        function PreloadFiles takes nothing returns nothing

            call PreloadStart()
            call Preload( "payload_chunk1" )
            call Preload( "payload_chunk2" )
            call PreloadEnd( 0.0 )

        endfunction
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            # Create content matching the exact expected format from the user
            content = '''function PreloadFiles takes nothing returns nothing

\tcall PreloadStart()
\tcall Preload( "0:|c00750508testMap_007|r" )
\tcall Preload( "0:Testing log" )
\tcall PreloadEnd( 11.3 )

endfunction'''
            f.write(content)
            temp_path = f.name
        try:
            result = parse_nonloadable_file(temp_path)
            self.assertEqual(result, b'0:|c00750508testMap_007|r0:Testing log')
        finally:
            os.unlink(temp_path)

    def test_parse_nonloadable_file_with_double_quotes_in_payload(self):
        """Test that parse_nonloadable_file correctly handles double quotes inside the payload.

        In JASS/WC3, double quotes inside strings are represented as "" (doubled quotes).
        The regex pattern should match these and include them in the payload.
        """
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            # Create content with doubled quotes inside the payload
            content = '''function PreloadFiles takes nothing returns nothing

\tcall PreloadStart()
\tcall Preload( "He said ""hello"" to me" )
\tcall PreloadEnd( 0.0 )

endfunction'''
            f.write(content)
            temp_path = f.name
        try:
            result = parse_nonloadable_file(temp_path)
            # The doubled quotes should be preserved in the payload
            self.assertEqual(result, b'He said ""hello"" to me')
        finally:
            os.unlink(temp_path)


@contextmanager
def mock_main_environment(commands, capture_print=False, track_calls=False):
    """Context manager to set up common mocks for testing main().

    Args:
        commands: List of commands to feed to stdin_queue (new queue-based architecture)
        capture_print: If True, captures print output and yields it as a list
        track_calls: If True, tracks calls to remove_all_files and stop_all_watchers

    Yields:
        dict with 'output' (if capture_print), 'remove_calls' and 'stop_calls' (if track_calls)
    """
    from queue import Queue
    result = {}

    # Create a pre-populated queue with the test commands
    test_queue = Queue()
    for cmd in commands:
        test_queue.put(cmd)

    patches = [
        patch.object(wc3_interpreter, 'stdin_queue', test_queue),
        patch.object(wc3_interpreter.signal, 'signal'),
        patch.object(wc3_interpreter, 'start_stdin_reader'),  # Don't start real stdin reader
        patch.object(wc3_interpreter, 'stop_stdin_reader'),   # Don't stop real stdin reader
    ]

    if capture_print:
        result['output'] = []
        def fake_print(*args, **kwargs):
            result['output'].append(' '.join(str(a) for a in args))
        patches.append(patch('builtins.print', side_effect=fake_print))
    else:
        patches.append(patch('builtins.print'))

    if track_calls:
        result['remove_calls'] = []
        result['stop_calls'] = []
        def mock_remove():
            result['remove_calls'].append(True)
        def mock_stop():
            result['stop_calls'].append(True)
        patches.append(patch.object(wc3_interpreter, 'remove_all_files', side_effect=mock_remove))
        patches.append(patch.object(wc3_interpreter.file_watcher, 'stop_all_watchers', side_effect=mock_stop))
    else:
        patches.append(patch.object(wc3_interpreter, 'remove_all_files'))
        patches.append(patch.object(wc3_interpreter.file_watcher, 'stop_all_watchers'))

    with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6]:
        yield result


class TestMainCommand(unittest.TestCase):
    """Tests for the main() function and command handling."""

    def test_main_handles_exit_command(self):
        """Test that main() exits cleanly when 'exit' is entered."""
        with mock_main_environment(["exit"]):
            wc3_interpreter.main()

    def test_main_handles_help_command(self):
        """Test that main() handles the 'help' command."""
        with mock_main_environment(["help", "exit"], capture_print=True) as ctx:
            wc3_interpreter.main()

        help_output = '\n'.join(ctx['output'])
        self.assertIn("Available commands", help_output)
        self.assertIn("file", help_output)

    def test_main_handles_restart_command(self):
        """Test that main() handles the 'restart' command."""
        with mock_main_environment(["restart", "exit"], track_calls=True) as ctx:
            wc3_interpreter.main()

        # restart calls remove_all_files and stop_all_watchers, plus initial remove_all_files
        # and exit also calls them
        self.assertGreaterEqual(len(ctx['remove_calls']), 2)
        self.assertGreaterEqual(len(ctx['stop_calls']), 1)

    def test_main_handles_jump_command(self):
        """Test that main() handles the 'jump' command."""
        with mock_main_environment(["jump 5", "exit"]):
            wc3_interpreter.main()

        # After jump 5, nextFile should be 5
        self.assertEqual(wc3_interpreter.nextFile, 5)


class TestFileCommand(unittest.TestCase):
    """Tests for the 'file' command and send_file_to_game function."""

    def test_send_file_to_game_nonexistent_file(self):
        """Test that send_file_to_game handles non-existent files gracefully."""
        output_lines = []

        def fake_print(*args, **kwargs):
            output_lines.append(' '.join(str(a) for a in args))

        with patch('builtins.print', side_effect=fake_print):
            send_file_to_game("/nonexistent/path/to/file.lua")

        # Should print an error message
        error_output = '\n'.join(output_lines)
        self.assertIn("Error", error_output)
        self.assertIn("does not exist", error_output)

    def test_send_file_to_game_wraps_with_oninit(self):
        """Test that send_file_to_game wraps file content with OnInit wrapper."""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
            f.write("print('hello')")
            temp_path = f.name

        try:
            sent_data = []

            def mock_send_data_to_game(data, print_prompt_after=False):
                sent_data.append(data)

            with patch.object(wc3_interpreter, 'send_data_to_game', side_effect=mock_send_data_to_game), \
                 patch('builtins.print'):
                send_file_to_game(temp_path)

            # Check that the data was wrapped with OnInit wrapper
            self.assertEqual(len(sent_data), 1)
            self.assertIn(ONINIT_IMMEDIATE_WRAPPER, sent_data[0])
            self.assertIn("print('hello')", sent_data[0])
            self.assertIn(ONINIT_IMMEDIATE_WRAPPER_END, sent_data[0])
        finally:
            os.unlink(temp_path)

    def test_main_handles_file_command(self):
        """Test that main() handles the 'file' command."""
        from queue import Queue
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
            f.write("return 42")
            temp_path = f.name

        try:
            # Create a pre-populated queue with the test commands
            test_queue = Queue()
            test_queue.put(f"file {temp_path}")
            test_queue.put("exit")
            sent_files = []

            def mock_send_file_to_game(filepath):
                sent_files.append(filepath)

            with patch.object(wc3_interpreter, 'stdin_queue', test_queue), \
                 patch.object(wc3_interpreter, 'remove_all_files'), \
                 patch.object(wc3_interpreter.file_watcher, 'stop_all_watchers'), \
                 patch.object(wc3_interpreter, 'send_file_to_game', side_effect=mock_send_file_to_game), \
                 patch.object(wc3_interpreter.signal, 'signal'), \
                 patch.object(wc3_interpreter, 'start_stdin_reader'), \
                 patch.object(wc3_interpreter, 'stop_stdin_reader'), \
                 patch('builtins.print'):
                wc3_interpreter.main()

            # Check that send_file_to_game was called with the correct path
            self.assertEqual(len(sent_files), 1)
            self.assertEqual(sent_files[0], temp_path)
        finally:
            os.unlink(temp_path)


if __name__ == '__main__':
    unittest.main(verbosity=2)
