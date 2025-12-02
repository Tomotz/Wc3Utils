#!/usr/bin/env python3
"""
Tests for wc3_interpreter.py

These tests can run on any Linux machine without WC3.
Run with: python -m pytest test_wc3_interpreter.py -v
Or simply: python test_wc3_interpreter.py
"""

import os
import sys
import tempfile
import unittest

# Import the module under test
from wc3_interpreter import (
    load_file,
    create_file,
    wrap_with_oninit_immediate,
    find_lua_function,
    inject_into_function,
    modify_function,
    REGEX_PATTERN,
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
