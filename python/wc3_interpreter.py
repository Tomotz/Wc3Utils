
# wc3_interpreter.py
VERSION = "1.5.0"

import os
import re
import time
import signal
import sys
import threading
from queue import Queue, Empty
from typing import Optional, Dict, List, Tuple

# Optional watchdog import for file watching functionality
try:
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    WATCHDOG_AVAILABLE = True
except ImportError:
    WATCHDOG_AVAILABLE = False

# You might need to change `D:` to your Warcraft III installation drive
def _get_username() -> str:
    try:
        return os.getlogin()
    except OSError:
        return os.environ.get('USER', os.environ.get('USERNAME', 'User'))

CUSTOM_MAP_DATA_PATH = r"D:\Users\{username}\Documents\Warcraft III\CustomMapData\\".format(username=_get_username())

# Check if we're running in wsl. If you're working in linux/wsl env, you need to manually change the next 2 lines
if os.path.exists("/mnt/d/Users/Tom"):
    CUSTOM_MAP_DATA_PATH = "/mnt/d/Users/Tom/Documents/Warcraft III/CustomMapData/"

# Allow overriding FILES_ROOT via environment variable for testing
FILES_ROOT = os.environ.get('WC3_INTERPRETER_FILES_ROOT', os.path.join(CUSTOM_MAP_DATA_PATH, "Interpreter"))

def set_files_root(path: str) -> None:
    """Set the FILES_ROOT directory. Useful for testing with a temp directory."""
    global FILES_ROOT
    FILES_ROOT = path
    os.makedirs(FILES_ROOT, exist_ok=True)

# find any pattern starting with `call Preload( "]]i([[` and ending with `]])--[[" )` and concatenate the innter strings
REGEX_PATTERN = rb'call Preload\( "\]\]i\(\[\[(.*?)\]\]\)--\[\[" \)'
# find any pattern starting with `call Preload( "` and ending with `" )` and concatenate the innter strings
READ_REGEX_PATTERN = rb'call Preload\( "(.*?)" \)'

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
# The wrapper also captures and returns the result of the file's return statement
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

local __wc3_interpreter_result
local function __wc3_interpreter_run()
    __wc3_interpreter_result = (function()
"""

ONINIT_IMMEDIATE_WRAPPER_END = """
    end)()
end

local ok, err = pcall(__wc3_interpreter_run)
OnInit = _savedOnInit

if not ok then
    error(err)
end

return __wc3_interpreter_result
end"""

# Global state for breakpoint handling
bp_command_indices: Dict[str, int] = {}  # Maps thread_id to next command index (per-thread counters)

# Unified interface state for breakpoint handling
# When a breakpoint is hit, it becomes the current context and commands go to it
# Additional breakpoints are queued and handled after the current one is continued
# Main thread owns all state - no locks needed
current_breakpoint: Optional[Tuple[str, Dict]] = None  # (thread_id, info) of current breakpoint being handled
pending_breakpoints: List[Tuple[str, Dict]] = []  # Queue of breakpoints waiting to be handled

thread_state_is_bp: Dict[str, bool] = {}  # Maps thread_id to whether it's currently in a breakpoint

# Queues for inter-thread communication (thread-safe by design)
# Other threads push to these, main thread reads from them
stdin_queue: Queue[str] = Queue()  # User input from stdin reader thread
file_change_queue: Queue = Queue()  # File change events from watchdog

# Stdin reader thread
stdin_reader_thread: Optional[threading.Thread] = None
stdin_reader_stop_event: threading.Event = threading.Event()

# Field separator for breakpoint data files (ASCII 31 = unit separator)
FIELD_SEP = bytes([31])

if WATCHDOG_AVAILABLE:
    class FileChangeHandler(FileSystemEventHandler):
        """Handler for file change events that pushes to a queue for main thread processing"""
        def __init__(self, filepath: str, queue: Queue):
            super().__init__()
            self.filepath = os.path.abspath(filepath)
            self.queue = queue
            self.last_modified = 0

        def on_modified(self, event) -> None:
            if event.is_directory:
                return
            # Check if this is the file we're watching
            if os.path.abspath(event.src_path) == self.filepath:
                # Debounce: ignore events within 0.5 seconds of each other
                current_time = time.time()
                if current_time - self.last_modified < 0.5:
                    return
                self.last_modified = current_time
                # Push to queue - main thread will handle the actual work
                self.queue.put(self.filepath)

class FileWatcher:
    """File watcher that pushes change events to a queue for main thread processing.

    No locks needed - this class is only called from the main thread.
    The watchdog Observer threads only push to the queue via FileChangeHandler.
    """
    # Global state for file watching
    watched_files: Dict[str, any] = {}  # filepath -> Observer

    def start_watching(self, filepath: str, queue: Queue) -> bool:
        """Start watching a file for changes. Returns True if successful.

        Args:
            filepath: Path to the file to watch
            queue: Queue to push file change events to
        """
        if not WATCHDOG_AVAILABLE:
            print("watch: watchdog is not installed. Install it with `pip install watchdog` to use watch/unwatch.")
            return False

        filepath = os.path.abspath(filepath)

        if not os.path.exists(filepath):
            print(f"Error: File does not exist: {filepath}")
            return False

        if filepath in self.watched_files:
            print(f"Already watching: {filepath}")
            return False

        directory = os.path.dirname(filepath)
        handler = FileChangeHandler(filepath, queue)
        observer = Observer()
        observer.schedule(handler, directory, recursive=False)
        observer.start()
        self.watched_files[filepath] = observer
        print(f"Now watching: {filepath}")
        return True

    def stop_watching(self, filepath: str) -> bool:
        """Stop watching a file. Returns True if successful."""
        filepath = os.path.abspath(filepath)

        if filepath not in self.watched_files:
            print(f"Not watching: {filepath}")
            return False

        observer = self.watched_files.pop(filepath)
        observer.stop()
        observer.join(timeout=1.0)
        print(f"Stopped watching: {filepath}")
        return True

    def stop_all_watchers(self) -> None:
        """Stop all file watchers."""
        for filepath, observer in list(self.watched_files.items()):
            observer.stop()
            observer.join(timeout=1.0)
        self.watched_files.clear()

    def list_watched_files(self) -> None:
        """List all currently watched files."""
        if not self.watched_files:
            print("No files being watched.")
        else:
            print("Currently watching:")
            for filepath in self.watched_files:
                print(f"  {filepath}")

file_watcher = FileWatcher()

# ============================================================================
# Dynamic breakpoint related code:
# ============================================================================

def load_lua_directory(path: str) -> Dict[str, str]:
    lua_files: Dict[str, str] = {}
    for root, _, files in os.walk(path):
        for f in files:
            if f.endswith('.lua'):
                full_path = os.path.join(root, f)
                with open(full_path, 'r', encoding='utf-8') as file:
                    lua_files[full_path] = file.read()
    return lua_files

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


# ============================================================================
# File I/O Functions (create/load files in wc3 preload format)
# ============================================================================

def load_file(filename: str) -> Optional[bytes]:
    """loads a file in wc3 preload format (saved by FileIO) and parses it"""
    if not os.path.exists(filename):
        return None
    with open(filename, 'rb') as file:
        data = file.read()
    # First try the i([[ ... ]])--[[ pattern used by create_file/FileIO
    matches = re.findall(REGEX_PATTERN, data, flags=re.DOTALL)
    if matches:
        return b''.join(matches)
    # Fallback to simpler pattern for legacy/simple format
    matches = re.findall(READ_REGEX_PATTERN, data, flags=re.DOTALL)
    if matches:
        return b''.join(matches)
    return b''

def create_file(filename: str, content) -> None:
    """
    creates a file in wc3 preload format (that can be loaded by FileIO)
    @content: The data that will be returned from FileIO after loading this file.
              Accepts both str and bytes.
    """
    assert len(content) > 0
    # Convert to bytes if needed for internal processing
    if isinstance(content, str):
        content_bytes = content.encode('utf-8')
    else:
        content_bytes = content

    # Build the file content as bytes
    data = FILE_PREFIX.encode('utf-8')
    line_prefix_bytes = LINE_PREFIX.encode('utf-8')
    line_postfix_bytes = LINE_POSTFIX.encode('utf-8')

    # Split content into 255 byte chunks
    for i in range(0, len(content_bytes), 255):
        chunk = content_bytes[i : i+255]
        data += line_prefix_bytes + chunk + line_postfix_bytes
    data += FILE_POSTFIX.encode('utf-8')
    with open(filename, 'wb') as file:
        file.write(data)

def remove_all_files() -> None:
    """Removes all input and output files from the FILES_ROOT directory.
    If we leave the files there, the next game might read and run them"""
    if not os.path.isdir(FILES_ROOT):
        return
    for filename in os.listdir(FILES_ROOT):
        file_path = os.path.join(FILES_ROOT, filename)
        # Remove regular files and breakpoint files
        if filename.endswith(".txt") and os.path.isfile(file_path):
            # Match: in*.txt, out.txt, bp_in.txt, bp_out.txt, bp_threads.txt, bp_data_*.txt
            if (filename.startswith("in") or filename == "out.txt" or
                filename.startswith("bp_")):
                try:
                    os.unlink(file_path)
                except Exception as e:
                    print(f"Error deleting file {file_path}: {e}")

def parse_nonloadable_file(filename: str) -> Optional[bytes]:
    """Read payload from files saved via FileIO.Save(..., isLoadable=False) in the test environment.

    In WC3, these files go through the Preload mechanism and are wrapped in a standard format:
        function PreloadFiles takes nothing returns nothing

            call PreloadStart()
            call Preload( "payload_chunk1" )
            call Preload( "payload_chunk2" )
            call PreloadEnd( 0.0 )

        endfunction

    This function parses the preload wrapper and extracts the concatenated payload from all
    Preload() calls.

    This function is used for breakpoint metadata files (bp_threads.txt, bp_data_*.txt, bp_out.txt)
    which are saved with isLoadable=False by LiveCoding.lua.
    """
    if not os.path.exists(filename):
        return None
    with open(filename, 'rb') as file:
        content = file.read()

    # Parse the preload wrapper and extract payload from call Preload( "..." ) lines
    # Pattern matches: call Preload( "..." ) and allows double quotes inside the payload
    # stopping only at the closing " ) sequence
    pattern = rb'call Preload\( "(.+?)" \)'
    matches = re.findall(pattern, content, flags=re.DOTALL)
    if matches:
        return b''.join(matches)

    # Check if this looks like a preload wrapper (has PreloadStart/PreloadEnd but no Preload calls)
    # This happens when FileIO.Save is called with empty data
    assert b'call PreloadStart()' in content and b'call PreloadEnd(' in content
    return None

# ============================================================================
# LiveCode output parsers
# ============================================================================

def parse_indexed_output(content: bytes) -> Tuple[Optional[bytes], Optional[bytes]]:
    """Parse output file with format 'index FIELD_SEP result'. Returns (index, result)."""
    if not content:
        return None, None
    lines = content.split(FIELD_SEP, 1)
    if len(lines) >= 2:
        assert len(lines) == 2, f"unexpected file format - too many separators {content}"
        return lines[0], lines[1]
    elif len(lines) == 1:
        return lines[0], b''
    return None, None

def parse_bp_threads_file() -> List[bytes]:
    """Get list of thread IDs currently in a breakpoint by reading bp_threads.txt."""
    bp_threads_file = os.path.join(FILES_ROOT, "bp_threads.txt")
    if not os.path.exists(bp_threads_file):
        return []
    content = parse_nonloadable_file(bp_threads_file)
    if not content or not content.strip():
        return []
    return [t.strip() for t in content.split(FIELD_SEP) if t.strip()]

def parse_bp_data_file(thread_id: str) -> Optional[Dict[str, any]]:
    """Get breakpoint info for a specific thread by reading bp_data_<thread_id>.txt.

    File format is a single FIELD_SEP-separated record:
    bp_id<SEP>value<SEP>stack<SEP>stacktrace<SEP>var1<SEP>val1<SEP>var2<SEP>val2...

    Fields are parsed in pairs: key, value, key, value, ...
    - bp_id: breakpoint identifier
    - stack: stacktrace
    - other keys: local variable names with their values

    Returns a dict with keys: bp_id, stack, locals_values (dict of name->value).
    The 'locals' list is derived from locals_values keys.
    """
    bp_data_file = os.path.join(FILES_ROOT, f"bp_data_{thread_id}.txt")
    if not os.path.exists(bp_data_file):
        return None
    content = parse_nonloadable_file(bp_data_file)
    if not content:
        return None
    text = content.strip()
    if not text:
        return None

    # Split by FIELD_SEP and parse in pairs
    parts = text.split(FIELD_SEP)
    info = {'thread_id': thread_id, 'locals_values': {}}

    i = 0
    while i + 1 < len(parts):
        key, value = parts[i], parts[i + 1]
        i += 2
        if key == b'bp_id':
            info['bp_id'] = value
        elif key == b'stack':
            # Unescape newlines in stacktrace
            info['stack'] = value
        else:
            # Local variable value
            info['locals_values'][key] = value

    # Derive locals list from locals_values keys
    info['locals'] = list(info['locals_values'].keys())
    return info

# ============================================================================
# Breakpoint Related Functions
# ============================================================================

def bp_show_info(thread_id: str):
    """Show detailed breakpoint info for a specific thread."""
    info = parse_bp_data_file(thread_id)
    if not info:
        print(f"No breakpoint info found for thread '{thread_id}'")
        return

    print(f"Thread: {thread_id}")
    print(f"Breakpoint ID: {info.get('bp_id', 'unknown')}")

    locals_list = info.get('locals', [])
    if locals_list:
        print(f"Local variables: {b', '.join(locals_list)}")
        for var in locals_list:
            if var in info.get('locals_values', {}):
                print(f"  {var} = {info['locals_values'][var]}")

    stack = info.get('stack', '')
    if stack:
        print(f"Stack trace:\n{stack}")

def check_for_new_breakpoints() -> None:
    """Check for new breakpoints and handle them on the main thread.

    This function is called from the main event loop to poll for new breakpoints.
    Since it runs on the main thread, no locks are needed.
    """
    for thread_id_bytes in parse_bp_threads_file():
        thread_id = thread_id_bytes.decode('utf-8', errors='replace')
        info = parse_bp_data_file(thread_id)
        if not info:
            continue

        if thread_state_is_bp.get(thread_id, False):
            # Thread is already in a breakpoint (we haven't continued yet)
            continue

        # Mark thread as in breakpoint and handle the event
        thread_state_is_bp[thread_id] = True
        handle_breakpoint_event(thread_id, info)

def stdin_reader_thread_func() -> None:
    """Background thread that reads stdin and pushes to queue.

    Uses blocking input() since this runs in a separate thread.
    """
    while not stdin_reader_stop_event.is_set():
        try:
            line = input()
            stdin_queue.put(line)
        except EOFError:
            break
        except Exception as e:
            # If stdin is closed or there's an error, exit the thread
            print("Stdin reader thread exiting due to error.", e)
            break

def start_stdin_reader() -> None:
    """Start the background stdin reader thread."""
    global stdin_reader_thread
    if stdin_reader_thread is not None and stdin_reader_thread.is_alive():
        return
    stdin_reader_stop_event.clear()
    stdin_reader_thread = threading.Thread(target=stdin_reader_thread_func, daemon=True)
    stdin_reader_thread.start()

def stop_stdin_reader() -> None:
    """Stop the background stdin reader thread."""
    global stdin_reader_thread
    stdin_reader_stop_event.set()
    if stdin_reader_thread is not None:
        stdin_reader_thread.join(timeout=1.0)
        stdin_reader_thread = None

def print_breakpoint_hit(thread_id: str, info: Dict[str, any]) -> None:
    """Print a message when a breakpoint is hit.

    Uses flush=True to ensure immediate output when called from background thread.
    """
    bp_id = info.get('bp_id', 'unknown')
    locals_list = info.get('locals', [])

    print("\n" + "=" * 60)
    print(f"BREAKPOINT HIT: {bp_id}")
    print(f"Thread: {thread_id}")
    if locals_list:
        print(f"Local variables: {b', '.join(locals_list)}")
    print("Type 'help' for commands, 'continue' to resume, or enter Lua code")
    print("=" * 60)
    print(f"{nextFile} >>> ", flush=True, end='')

def get_prompt()-> str:
    """Get the appropriate prompt based on current context.

    No lock needed - only called from main thread.
    """
    if current_breakpoint is not None:
        thread_id = current_breakpoint[0]
        short_id = thread_id[:8] if len(thread_id) > 8 else thread_id
        return f"bp:{short_id}... >>> "
    else:
        return f"{nextFile} >>> "

def clear_state():
    """Clean up all state and stop background threads."""
    stop_stdin_reader()
    file_watcher.stop_all_watchers()
    remove_all_files()

def signal_handler(sig: int, frame) -> None:
    """On any termination of the program we want to remove the input and output files and stop watchers"""
    clear_state()
    sys.exit(0)

nextFile: int = 0

def send_data_to_game(data: str, print_prompt_after: bool = False) -> Optional[str]:
    """Send data to the game and wait for response.

    This is the unified interface for both normal and breakpoint modes.
    - In normal mode: Uses in{N}.txt and out.txt with format "{index}FIELD_SEP{result}"
    - In breakpoint mode: Uses bp_in_{thread_id}_{idx}.txt and bp_out.txt with format "{thread_id}:{cmd_index}FIELD_SEP{result}"

    No locks needed - only called from main thread.

    Args:
        data: The Lua code to send to the game
        print_prompt_after: If True, print the prompt after the result (used for file/watch commands)

    Returns:
        The result string from the game, or None if no response/timeout
    """
    global nextFile, bp_command_indices
    if data == "":
        return None

    # Check if we're in breakpoint context
    in_breakpoint = current_breakpoint is not None
    if in_breakpoint:
        thread_id = current_breakpoint[0]
        cmd_index = bp_command_indices.get(thread_id, 0)
        bp_command_indices[thread_id] = cmd_index + 1
        expected_prefix = f"{thread_id}:{cmd_index}"
        # Breakpoint mode: use bp_in/bp_out files
        in_file = os.path.join(FILES_ROOT, f"bp_in_{thread_id}_{cmd_index}.txt")
        out_file = os.path.join(FILES_ROOT, "bp_out.txt")
    else:
        thread_id = ""
        cmd_index = nextFile
        nextFile += 1
        expected_prefix = f"{cmd_index}"
        # Normal mode: use in/out files
        in_file = os.path.join(FILES_ROOT, f"in{cmd_index}.txt")
        out_file = os.path.join(FILES_ROOT, "out.txt")

    create_file(in_file, data)
    debug = os.environ.get('WC3_E2E_DEBUG')
    if debug:
        print(f"[DEBUG] send_data_to_game thread_id={thread_id}, cmd_index={cmd_index}. Wrote command to: {in_file}. Waiting for response with prefix: {expected_prefix}")

    start_time = time.time()
    timeout = 20
    while time.time() - start_time < timeout:
        if os.path.exists(out_file):
            content = parse_nonloadable_file(out_file)
            if content:
                index, result = parse_indexed_output(content)
                if debug:
                    print(f"[DEBUG] {out_file} content (first 100 bytes): {content[:100]}. Parsed index: {index}, expected: {expected_prefix}")
                if index and index.decode('utf-8', errors='replace') == expected_prefix:
                    if debug:
                        print(f"[DEBUG] Got matching response!")
                    result_str = result.decode('utf-8', errors='replace') if result else None
                    if result_str and result_str != "nil":
                        print(result_str)
                    if print_prompt_after:
                        print(get_prompt(), end="", flush=True)
                    return result_str
        time.sleep(0.1)

    if debug:
        print(f"[DEBUG] TIMEOUT waiting for {expected_prefix}. {out_file} exists: {os.path.exists(out_file)}")
        if os.path.exists(out_file):
            content = parse_nonloadable_file(out_file)
            print(f"[DEBUG] Final {out_file} content: {content}")

    print(f"Timeout waiting for response")
    if print_prompt_after:
        print(get_prompt(), end="", flush=True)
    return None

def wrap_with_oninit_immediate(content: str) -> str:
    """Wraps Lua content with OnInit immediate execution wrapper"""
    return ONINIT_IMMEDIATE_WRAPPER + content + ONINIT_IMMEDIATE_WRAPPER_END

def send_file_to_game(filepath: str) -> None:
    """Send a file to the game with OnInit wrapper applied. Used by both 'file' command and watch callbacks."""
    if not os.path.exists(filepath):
        print(f"Error: File does not exist: {filepath}")
        return

    with open(filepath, 'r', encoding='utf-8') as f:
        data = f.read()

    # Wrap with OnInit immediate execution wrapper
    data = wrap_with_oninit_immediate(data)

    print(f"Sending file {filepath} to game")
    send_data_to_game(data, print_prompt_after=True)

def handle_continue_command() -> None:
    """Handle the 'continue' command to resume execution of current breakpoint thread.

    No locks needed - only called from main thread.
    """
    global current_breakpoint, pending_breakpoints

    if current_breakpoint is None:
        print("Not in a breakpoint context.")
        return
    thread_id = current_breakpoint[0]

    # Send continue command to game via unified interface
    send_data_to_game("continue")
    print(f"Resuming thread {thread_id}...")

    # Clean up state for this thread
    if thread_id in thread_state_is_bp:
        del thread_state_is_bp[thread_id]

    # Move to next pending breakpoint if any
    if pending_breakpoints:
        next_bp = pending_breakpoints.pop(0)
        current_breakpoint = next_bp
        print_breakpoint_hit(next_bp[0], next_bp[1])
        if pending_breakpoints:
            print(f"[{len(pending_breakpoints)} more breakpoint(s) pending]")
    else:
        # No more breakpoints - clear current context
        current_breakpoint = None
        print("[Returned to normal command mode]")


def handle_thread_command(new_thread_id: str) -> None:
    """Handle the 'thread <id>' command to switch to a different breakpoint thread.

    No locks needed - only called from main thread.
    """
    global current_breakpoint

    threads = parse_bp_threads_file()
    threads_str = [t.decode('utf-8', errors='replace') for t in threads]
    if new_thread_id in threads_str:
        new_info = parse_bp_data_file(new_thread_id)
        if new_info:
            current_breakpoint = (new_thread_id, new_info)
            print(f"Switched to thread {new_thread_id}")
            print(f"Breakpoint: {new_info.get('bp_id', 'unknown')}")
            new_locals = new_info.get('locals', [])
            if new_locals:
                print(f"Local variables: {b', '.join(new_locals)}")
        else:
            print(f"Switched to thread {new_thread_id} (no info available)")
            current_breakpoint = (new_thread_id, {'thread_id': new_thread_id})
    else:
        print(f"Thread '{new_thread_id}' not found in breakpoint.")
        print(f"Available threads: {', '.join(threads_str) if threads_str else 'none'}")

def handle_command(cmd: str) -> bool:
    """Handle a single command from the user. Returns False to exit."""
    global nextFile, bp_command_indices, current_breakpoint, pending_breakpoints
    # Check if we're in breakpoint context for context-aware help
    in_bp_mode = current_breakpoint is not None
    if in_bp_mode:
        thread_id = current_breakpoint[0]

    splitted = cmd.strip().split()
    if len(splitted) == 0:
        return True

    main_cmd = splitted[0]

    args = " ".join(splitted[1:]) # note that these are just general args, they do not apply to all commands

    # Unified command handling - same commands work in both modes
    if main_cmd in ("quit", "q", "exit"):
        clear_state()
        return False
    if main_cmd == "help" or main_cmd == "h":
        print("Available commands:")
        print("  help/h - Show this help message")
        print("  quit/q - Exit the program")
        print("  restart/r - Cleans the state to allow a new game to be started (this is the same as exiting and restarting the script)")
        print("  jump/j <number> - use in case of closing the interpreter (or crashing) while game is still running. Starts sending commands from a specific file index. Should use the index printed in the prompt before the `>>>`")
        print("  file <full file path> - send a file with lua commands to the game. end the file with `return <data>` to print the data to the console")
        print("  watch <full file path> - watch a file for changes and automatically send it to the game on each update")
        print("  unwatch <full file path> - stop watching a file")
        print("  watching - list all files currently being watched")
        print("  list/l - list all threads currently in a breakpoint (current marked with *)")
        print("  thread/t <id> - switch to a different breakpoint thread")
        print("  info/i - show detailed info for current breakpoint thread")
        print("  continue/c - resume execution of current breakpoint thread")
        print("  enable/e <breakpoint_id> - enable a breakpoint by its ID")
        print("  disable/d <breakpoint_id> - disable a breakpoint by its ID")
        print("  b/break <function_name> - set a dynamic breakpoint on a global function. When the function is called, execution will pause and you can inspect/modify arguments")
        print("  bl <file>:<line> - set a line breakpoint at a specific line in a Lua file. The file will be modified and sent to the game with a breakpoint at that line")
        print("  <lua command> - run a lua command in the game. If the command is a `return` statement, the result will be printed to the console.")
        print("** Note: exiting or restarting the script while the game is running will cause it to stop working until the game is also restarted **")
        print("** Note: OnInit calls in files sent via 'file' or 'watch' are automatically executed immediately **")
        if in_bp_mode:
            print(f"\n[Currently in breakpoint context: thread {thread_id}]")
        return True
    if main_cmd == "restart":
        clear_state()
        nextFile = 0
        bp_command_indices = {}
        current_breakpoint = None
        pending_breakpoints = []
        thread_state_is_bp.clear()
        start_stdin_reader()
        print("State reset. You can start a new game now.")
        return True
    if main_cmd == "jump" or main_cmd == "j":
        nextFile = int(args)
        return True
    if main_cmd == "watch":
        filepath = args
        file_watcher.start_watching(filepath, file_change_queue)
        return True
    if main_cmd == "unwatch":
        filepath = args
        file_watcher.stop_watching(filepath)
        return True
    if main_cmd == "watching":
        file_watcher.list_watched_files()
        return True
    if main_cmd == "file":
        filepath = args
        send_file_to_game(filepath)
        return True
    if main_cmd == "list" or main_cmd == "l":
        # List all threads in breakpoint (with current marked)
        threads = parse_bp_threads_file()
        if not threads:
            print("No threads currently in a breakpoint.")
        else:
            print(f"Threads in breakpoint ({len(threads)}):")
            for tid in threads:
                tid_str = tid.decode('utf-8', errors='replace')
                bp_info = parse_bp_data_file(tid_str)
                bp_name = bp_info.get('bp_id', 'unknown') if bp_info else 'unknown'
                marker = " *" if in_bp_mode and tid_str == thread_id else ""
                print(f"  {tid_str}: breakpoint '{bp_name}'{marker}")
        return True
    if main_cmd == "thread" or main_cmd == "t":
        new_thread_id = args
        handle_thread_command(new_thread_id)
        return True
    if main_cmd == "info" or main_cmd == "i":
        if in_bp_mode:
            bp_show_info(thread_id)
        else:
            print("Not in a breakpoint context. Use 'list' to see available threads.")
        return True
    if main_cmd == "continue" or main_cmd == "c":
        if in_bp_mode:
            handle_continue_command()
        else:
            print("Not in a breakpoint context.")
        return True
    if main_cmd == "enable" or main_cmd == "e":
        if not args:
            print("Usage: enable <breakpoint_id>")
            return True
        lua_cmd = f'EnabledBreakpoints["{args}"] = true'
        send_data_to_game(lua_cmd)
        print(f"Enabled breakpoint '{args}'")
        return True
    if main_cmd == "disable" or main_cmd == "d":
        if not args:
            print("Usage: disable <breakpoint_id>")
            return True
        lua_cmd = f'EnabledBreakpoints["{args}"] = false'
        send_data_to_game(lua_cmd)
        print(f"Disabled breakpoint '{args}'")
        return True
    if main_cmd == "b" or main_cmd == "break":
        if not args:
            print("Usage: b/break <global_function_name>")
            return True
        func_name = args.strip()
        bp_id = f"bp:{func_name}"
        # Generate Lua code to wrap the global function with a breakpoint
        # The wrapper:
        # 1. Captures all arguments
        # 2. Creates local variable pairs for Breakpoint()
        # 3. Calls Breakpoint() which returns (potentially modified) values
        # 4. Calls the original function with the modified arguments
        lua_cmd = f'''do
    local _orig_func = _G["{func_name}"]
    if _orig_func == nil then
        print("Error setting breakpoint: function '{func_name}' does not exist")
        return
    end
    _G["{func_name}"] = function(...)
        local args = {{...}}
        local localVars = {{}}
        for i, v in ipairs(args) do
            table.insert(localVars, {{"arg" .. i, v}})
        end
        local modified = {{Breakpoint("{bp_id}", localVars)}}
        return _orig_func(table.unpack(modified))
    end
end'''
        send_data_to_game(lua_cmd)
        print(f"Set breakpoint on function '{func_name}' (id: {bp_id})")
        return True
    if main_cmd == "bl":
        # Line-based breakpoint: bl <file>:<line> or bl <file> <line>
        if not args:
            print("Usage: bl <file>:<line> or bl <file> <line>")
            return True
        # Parse file:line or file line format
        if ':' in args:
            parts = args.rsplit(':', 1)
            filepath = parts[0].strip()
            try:
                line_num = int(parts[1].strip())
            except ValueError:
                print(f"Error: Invalid line number '{parts[1]}'")
                return True
        else:
            parts = args.split()
            if len(parts) < 2:
                print("Usage: bl <file>:<line> or bl <file> <line>")
                return True
            filepath = parts[0].strip()
            try:
                line_num = int(parts[1].strip())
            except ValueError:
                print(f"Error: Invalid line number '{parts[1]}'")
                return True
        
        # Resolve relative paths
        if not os.path.isabs(filepath):
            filepath = os.path.abspath(filepath)
        
        if not os.path.exists(filepath):
            print(f"Error: File does not exist: {filepath}")
            return True
        
        # Read the file
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find the function containing the specified line
        result = find_lua_function(content, line_number=line_num)
        if not result:
            print(f"Error: Could not find a function containing line {line_num}")
            return True
        
        start, end, func_body = result
        
        # Calculate the relative line number within the function
        # First, find which line the function starts on
        lines_before_func = content[:start].count('\n')
        relative_line = line_num - lines_before_func - 1  # -1 because line numbers are 1-indexed
        
        # Create breakpoint ID
        basename = os.path.basename(filepath)
        bp_id = f"line:{basename}:{line_num}"
        
        # Inject the breakpoint call at the specified line
        inject_str = f'Breakpoint("{bp_id}")'
        new_content = inject_into_function(content, start, end, inject_str, after_line=relative_line)
        
        # Extract just the modified function to send to the game
        # We need to find the function again in the new content since positions changed
        new_result = find_lua_function(new_content, line_number=line_num)
        if not new_result:
            print(f"Error: Could not re-locate function after injection")
            return True
        
        _, _, new_func_body = new_result
        
        # Send the modified function to the game
        # Wrap with OnInit immediate wrapper to ensure it executes
        lua_cmd = wrap_with_oninit_immediate(new_func_body)
        send_data_to_game(lua_cmd)
        print(f"Set line breakpoint at {basename}:{line_num} (id: {bp_id})")
        return True

    # Send Lua command to game via unified interface
    send_data_to_game(cmd)
    return True


def handle_breakpoint_event(thread_id: str, info: Dict[str, any]) -> None:
    """Handle a new breakpoint event.

    Called by check_for_new_breakpoints() when a new breakpoint is detected.
    """
    global current_breakpoint, pending_breakpoints

    # Update state
    if current_breakpoint is None:
        current_breakpoint = (thread_id, info)
    else:
        pending_breakpoints.append((thread_id, info))

    # Print the BREAKPOINT HIT message
    print_breakpoint_hit(thread_id, info)

    # If this is a queued breakpoint, add a note about context
    if current_breakpoint[0] != thread_id:
        print(f"[Note: this breakpoint is queued; current context stays at {current_breakpoint[0][:8]}... until you 'continue']", flush=True)

def handle_file_change_event(filepath: str) -> None:
    """Handle a file change event from the queue.

    Called by main thread when file_change_queue has data.
    """
    print(f"\n[watch] File changed: {filepath}")
    send_file_to_game(filepath)
    print(get_prompt(), end="", flush=True)

def main() -> None:
    """Main event loop.

    The main thread does all the work:
    - Processes user input from stdin_queue (stdin reader thread pushes to queue)
    - Processes file change events from file_change_queue (watchdog threads push to queue)
    - Polls for new breakpoints directly (no separate thread needed)

    No locks needed since breakpoint monitoring runs on the main thread.
    """
    global current_breakpoint, pending_breakpoints

    remove_all_files()
    # add a signal handler that handles all signals by removing all files and calling the default handler

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGABRT, signal_handler)
    signal.signal(signal.SIGSEGV, signal_handler)
    signal.signal(signal.SIGILL, signal_handler)

    # Start background stdin reader thread
    start_stdin_reader()

    print(f"Wc3 Interpreter {VERSION}. For help, type `help`.")
    print(get_prompt(), end="", flush=True)

    while True:
        # Check for new breakpoints
        check_for_new_breakpoints()

        # Check for file changes
        while not file_change_queue.empty():
            filepath = file_change_queue.get_nowait()
            handle_file_change_event(filepath)

        # Check for user input (with short timeout to stay responsive)
        if not stdin_queue.empty():
            command = stdin_queue.get()

            cmd = command.strip()
            if cmd == "":
                print(get_prompt(), end="", flush=True)
                continue

            if not handle_command(cmd):
                break

            print(get_prompt(), end="", flush=True)

if __name__ == "__main__":
    main()
