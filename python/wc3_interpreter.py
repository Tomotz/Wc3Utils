
# wc3_interpreter.py
VERSION = "1.1.0"

import os
import re
import time
import signal
import sys
import traceback
import threading
from typing import Optional
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# You might need to change `D:` to your Warcraft III installation drive
CUSTOM_MAP_DATA_PATH = r"D:\Users\{username}\Documents\Warcraft III\CustomMapData\\".format(username=os.getlogin())
FILES_ROOT = CUSTOM_MAP_DATA_PATH + "Interpreter" + "\\" # This should match the folder defined in the lua code

# find any pattern starting with `call Preload( "]]i([[` and ending with `]])--[[" )` and concatenate the innter strings
REGEX_PATTERN = rb'call Preload\( "\]\]i\(\[\[(.*?)\]\]\)--\[\[" \)'

FILE_PREFIX = """function PreloadFiles takes nothing returns nothing

	call PreloadStart()
	call Preload( "")
endfunction
//!beginusercode
local p={} local i=function(s) table.insert(p,s) end--[[" )
	"""

FILE_POSTFIX = """\n	call Preload( "]]BlzSetAbilityTooltip(1095656547, table.concat(p), 0)
//!endusercode
function a takes nothing returns nothing
//" )
	call PreloadEnd( 0.1 )

endfunction

"""

LINE_PREFIX = '\n	call Preload( "]]i([['
LINE_POSTFIX = ']])--[[" )'

# Lua wrapper to make OnInit and its submethods execute immediately instead of registering for later
# This is needed because when running code via the interpreter, the OnInit phase has already passed
ONINIT_IMMEDIATE_WRAPPER = """do
local function _immediateExec(nameOrFunc, func)
    local f = func or nameOrFunc
    if type(f) == 'function' then f() end
end
local _savedOnInit = OnInit
OnInit = setmetatable({}, {
    __call = function(_, ...) _immediateExec(...) end,
    __index = function() return _immediateExec end
})
pcall(function()
"""

ONINIT_IMMEDIATE_WRAPPER_END = """
end)
OnInit = _savedOnInit
end"""

# Global state for file watching
watched_files = {}  # filepath -> Observer
file_watch_lock = threading.Lock()

class FileChangeHandler(FileSystemEventHandler):
    """Handler for file change events that sends the file to the game"""
    def __init__(self, filepath: str, send_callback):
        super().__init__()
        self.filepath = os.path.abspath(filepath)
        self.send_callback = send_callback
        self.last_modified = 0
    
    def on_modified(self, event):
        if event.is_directory:
            return
        # Check if this is the file we're watching
        if os.path.abspath(event.src_path) == self.filepath:
            # Debounce: ignore events within 0.5 seconds of each other
            current_time = time.time()
            if current_time - self.last_modified < 0.5:
                return
            self.last_modified = current_time
            print(f"\n[watch] File changed: {self.filepath}")
            self.send_callback(self.filepath)

def wrap_with_oninit_immediate(content: str) -> str:
    """Wraps Lua content with OnInit immediate execution wrapper"""
    return ONINIT_IMMEDIATE_WRAPPER + content + ONINIT_IMMEDIATE_WRAPPER_END

def start_watching(filepath: str, send_callback) -> bool:
    """Start watching a file for changes. Returns True if successful."""
    filepath = os.path.abspath(filepath)
    
    if not os.path.exists(filepath):
        print(f"Error: File does not exist: {filepath}")
        return False
    
    with file_watch_lock:
        if filepath in watched_files:
            print(f"Already watching: {filepath}")
            return False
        
        directory = os.path.dirname(filepath)
        handler = FileChangeHandler(filepath, send_callback)
        observer = Observer()
        observer.schedule(handler, directory, recursive=False)
        observer.start()
        watched_files[filepath] = observer
        print(f"Now watching: {filepath}")
        return True

def stop_watching(filepath: str) -> bool:
    """Stop watching a file. Returns True if successful."""
    filepath = os.path.abspath(filepath)
    
    with file_watch_lock:
        if filepath not in watched_files:
            print(f"Not watching: {filepath}")
            return False
        
        observer = watched_files.pop(filepath)
        observer.stop()
        observer.join(timeout=1.0)
        print(f"Stopped watching: {filepath}")
        return True

def stop_all_watchers():
    """Stop all file watchers."""
    with file_watch_lock:
        for filepath, observer in list(watched_files.items()):
            observer.stop()
            observer.join(timeout=1.0)
        watched_files.clear()

def list_watched_files():
    """List all currently watched files."""
    with file_watch_lock:
        if not watched_files:
            print("No files being watched.")
        else:
            print("Currently watching:")
            for filepath in watched_files:
                print(f"  {filepath}")

def load_lua_directory(path: str):
    lua_files = {}
    for root, _, files in os.walk(path):
        for f in files:
            if f.endswith('.lua'):
                full_path = os.path.join(root, f)
                with open(full_path, 'r', encoding='utf-8') as file:
                    lua_files[full_path] = file.read()
    return lua_files

import re

def find_lua_function(content: str, func_name: str=None, line_number: int=None):
    """
    Returns (start_index, end_index, body_text)
    """
    lines = content.splitlines(keepends=True)
    if line_number is not None:
        # Find the nearest 'function ' line before the given line
        for i in range(line_number - 1, -1, -1):
            if re.match(r'\s*function\b', lines[i]):
                func_line = i
                break
        else:
            return None
    elif func_name:
        # Find by function name
        pattern = rf'\bfunction\s+{re.escape(func_name)}\b'
        for i, line in enumerate(lines):
            if re.search(pattern, line):
                func_line = i
                break
        else:
            return None
    else:
        return None

    # Find the matching 'end'
    depth = 0
    for j in range(func_line, len(lines)):
        if re.match(r'\s*function\b', lines[j]):
            depth += 1
        elif re.match(r'\s*end\b', lines[j]):
            depth -= 1
            if depth == 0:
                start = sum(len(l) for l in lines[:func_line])
                end = sum(len(l) for l in lines[:j + 1])
                return start, end, ''.join(lines[func_line:j + 1])
    return None

def inject_into_function(content: str, start: int, end: int, inject_str: str, after_line: int=None):
    func = content[start:end]
    func_lines = func.splitlines(keepends=True)
    if after_line is None:
        # Insert after first line (after function header)
        func_lines.insert(1, inject_str + '\n')
    else:
        func_lines.insert(after_line, inject_str + '\n')

    new_func = ''.join(func_lines)
    return content[:start] + new_func + content[end:]

def modify_function(lua_files: dict[str,str], func_name: Optional[str] = None, target_file: str='', target_line: Optional[int]=None, inject_str: str=''):
    if target_file != '':
        content = lua_files[target_file]
    else:
        # Search for name across all files
        for f, c in lua_files.items():
            if func_name in c:
                target_file = f
                content = c
                break
        else:
            raise ValueError("Function not found")

    match = find_lua_function(content, func_name=func_name, line_number=target_line)
    if not match:
        raise ValueError("Could not locate function boundaries")

    start, end, _ = match
    new_content = inject_into_function(content, start, end, inject_str)
    return new_content

def load_file(filename: str):
    """loads a file in wc3 preload format (saved by FileIO) and parses it"""
    if not os.path.exists(filename):
        return None
    with open(filename, 'rb') as file:
        data = file.read()
    matches = re.findall(REGEX_PATTERN, data, flags=re.DOTALL)
    if matches:
        return b''.join(matches)
    return b''

def create_file(filename: str, content: str):
    """
    creates a file in wc3 preload format (that can be loaded by FileIO)
    @content: The data that will be returned from FileIO after loading this file
    """
    assert len(content) > 0
    data = FILE_PREFIX
    # Split content into 255 char chunks
    for i in range(0, len(content), 255):
        chunk = content[i : i+255]
        data += LINE_PREFIX + chunk + LINE_POSTFIX
    data += FILE_POSTFIX
    with open(filename, 'w', encoding='utf-8') as file:
        file.write(data)

def remove_all_files():
    """Removes all input and output files from the FILES_ROOT directory.
    If we leave the files there, the next game might read and run them"""
    if not os.path.isdir(FILES_ROOT):
        return
    for filename in os.listdir(FILES_ROOT):
        file_path = os.path.join(FILES_ROOT, filename)
        if (filename.startswith("in") or filename.startswith("out")) and filename.endswith(".txt") and os.path.isfile(file_path):
            try:
                os.unlink(file_path)
            except Exception as e:
                print(f"Error deleting file {file_path}: {e}")

def signal_handler(sig, frame):
    """On any termination of the program we want to remove the input and output files and stop watchers"""
    stop_all_watchers()
    remove_all_files()
    sys.exit(0)

nextFile = 0

def send_file_to_game(filepath: str):
    """Send a file to the game with OnInit wrapper applied. Used by both 'file' command and watch callbacks."""
    global nextFile
    
    if not os.path.exists(filepath):
        print(f"Error: File does not exist: {filepath}")
        return
    
    with open(filepath, 'r', encoding='utf-8') as f:
        data = f.read()
    
    # Wrap with OnInit immediate execution wrapper
    data = wrap_with_oninit_immediate(data)
    
    print(f"Sending file {filepath} to game as in{nextFile}.txt")
    create_file(FILES_ROOT + f"in{nextFile}.txt", data)
    
    # Wait for response
    while not os.path.exists(FILES_ROOT + f"out{nextFile}.txt"):
        time.sleep(0.1)
    
    try:
        result = load_file(FILES_ROOT + f"out{nextFile}.txt")
        if result != b"nil" and result != "nil":
            print(result)
    except Exception as e:
        print("failed. Got exception: ", e)
        traceback.print_exc()
    
    nextFile += 1

def main():
    global nextFile
    remove_all_files()
    # add a signal handler that handles all signals by removing all files and calling the default handler

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGABRT, signal_handler)
    signal.signal(signal.SIGSEGV, signal_handler)
    signal.signal(signal.SIGILL, signal_handler)

    print(f"Wc3 Interpreter {VERSION}. For help, type `help`.")
    while True:
        # get console input
        try:
            command = input(str(nextFile) + " >>> ")
        except EOFError:
            break
        
        if command == "exit":
            stop_all_watchers()
            remove_all_files()
            break
        elif command == "help":
            print("Available commands:")
            print("  help - Show this help message")
            print("  exit - Exit the program")
            print("  restart - Cleans the state to allow a new game to be started (this is the same as exiting and restarting the script)")
            print("  jump <number> - use in case of closing the interpreter (or crashing) while game is still running. Starts sending commands from a specific file index. Should use the index printed in the prompt before the `>>>`")
            print("  file <full file path> - send a file with lua commands to the game. end the file with `return <data>` to print the data to the console")
            print("  watch <full file path> - watch a file for changes and automatically send it to the game on each update")
            print("  unwatch <full file path> - stop watching a file")
            print("  watching - list all files currently being watched")
            print("  <lua command> - run a lua command in the game. If the command is a `return` statement, the result will be printed to the console.")
            print("** Note: exiting or restarting the script while the game is running will cause it to stop working until the game is also restarted **")
            print("** Note: OnInit calls in files sent via 'file' or 'watch' are automatically executed immediately **")
            continue
        elif command == "restart":
            stop_all_watchers()
            remove_all_files()
            nextFile = 0
            print("State reset. You can start a new game now.")
            continue
        elif command.startswith("jump "):
            nextFile = int(command[5:].strip())
            continue
        elif command.startswith("watch "):
            filepath = command[6:].strip()
            start_watching(filepath, send_file_to_game)
            continue
        elif command.startswith("unwatch "):
            filepath = command[8:].strip()
            stop_watching(filepath)
            continue
        elif command == "watching":
            list_watched_files()
            continue
        elif command.startswith("file "):
            filepath = command[5:].strip()
            send_file_to_game(filepath)
            continue
        else:
            data = command
        if data == "":
            continue
        create_file(FILES_ROOT + f"in{nextFile}.txt", data)
        while not os.path.exists(FILES_ROOT + f"out{nextFile}.txt"):
            time.sleep(0.1)
        try:
            result = load_file(FILES_ROOT + f"out{nextFile}.txt")
            if result != b"nil" and result != "nil":
                print(result)
        except Exception as e:
            print("failed. Got exception: ", e)
            traceback.print_exc()
        nextFile += 1

if __name__ == "__main__":
    main()
