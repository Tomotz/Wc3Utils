
# wc3_interpreter.py
VERSION = "1.4.0"

import os
import re
import time
import signal
import sys
import traceback
import threading
from typing import Optional, Callable, Dict, List, Tuple

# Optional watchdog import for file watching functionality
try:
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    WATCHDOG_AVAILABLE = True
except ImportError:
    Observer = None
    class FileSystemEventHandler:
        """Fallback base class when watchdog is not installed."""
        pass
    WATCHDOG_AVAILABLE = False

# You might need to change `D:` to your Warcraft III installation drive
def _get_username() -> str:
    try:
        return os.getlogin()
    except OSError:
        return os.environ.get('USER', os.environ.get('USERNAME', 'User'))

CUSTOM_MAP_DATA_PATH = r"D:\Users\{username}\Documents\Warcraft III\CustomMapData\\".format(username=_get_username())

#check if we're running in wsl
if os.path.exists("/mnt/d/Users/"):
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

# Global state for file watching
watched_files: Dict[str, any] = {}  # filepath -> Observer
file_watch_lock: threading.Lock = threading.Lock()

# Global state for breakpoint handling
bp_monitor_thread: Optional[threading.Thread] = None  # Background thread for monitoring breakpoints
bp_monitor_stop_event: threading.Event = threading.Event()  # Event to signal thread to stop
bp_command_indices: Dict[str, int] = {}  # Maps thread_id to next command index (per-thread counters)

# Unified interface state for breakpoint handling
# When a breakpoint is hit, it becomes the current context and commands go to it
# Additional breakpoints are queued and handled after the current one is continued
# These are accessed from both the monitor thread and main thread, so we use a lock
bp_state_lock: threading.Lock = threading.Lock()  # Lock for breakpoint state
current_breakpoint: Optional[Tuple[str, Dict]] = None  # (thread_id, info) of current breakpoint being handled
pending_breakpoints: List[Tuple[str, Dict]] = []  # Queue of breakpoints waiting to be handled

# Field separator for breakpoint data files (ASCII 31 = unit separator)
FIELD_SEP = bytes([31])

class FileChangeHandler(FileSystemEventHandler):
    """Handler for file change events that sends the file to the game"""
    def __init__(self, filepath: str, send_callback: Callable[[str], None]):
        super().__init__()
        self.filepath = os.path.abspath(filepath)
        self.send_callback = send_callback
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
            print(f"\n[watch] File changed: {self.filepath}")
            self.send_callback(self.filepath)

def wrap_with_oninit_immediate(content: str) -> str:
    """Wraps Lua content with OnInit immediate execution wrapper"""
    return ONINIT_IMMEDIATE_WRAPPER + content + ONINIT_IMMEDIATE_WRAPPER_END

def start_watching(filepath: str, send_callback: Callable[[str], None]) -> bool:
    """Start watching a file for changes. Returns True if successful."""
    if not WATCHDOG_AVAILABLE:
        print("watch: watchdog is not installed. Install it with `pip install watchdog` to use watch/unwatch.")
        return False

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

def stop_all_watchers() -> None:
    """Stop all file watchers."""
    with file_watch_lock:
        for filepath, observer in list(watched_files.items()):
            observer.stop()
            observer.join(timeout=1.0)
        watched_files.clear()

def list_watched_files() -> None:
    """List all currently watched files."""
    with file_watch_lock:
        if not watched_files:
            print("No files being watched.")
        else:
            print("Currently watching:")
            for filepath in watched_files:
                print(f"  {filepath}")

def load_lua_directory(path: str) -> Dict[str, str]:
    lua_files: Dict[str, str] = {}
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


# ============================================================================
# Breakpoint Query Functions (read data without game interaction)
# ============================================================================

def parse_indexed_output(content: bytes) -> Tuple[Optional[bytes], Optional[bytes]]:
    """Parse output file with format 'index\\nresult'. Returns (index, result)."""
    if not content:
        return None, None
    lines = content.split(b'\n', 1)
    if len(lines) >= 2:
        return lines[0], lines[1]
    elif len(lines) == 1:
        return lines[0], b''
    return None, None


def load_nonloadable_file(filename: str) -> Optional[bytes]:
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
    # The pattern ((?:""|[^"])*) matches either doubled quotes "" or non-quote chars,
    # stopping only at the closing " ) sequence
    pattern = rb'call Preload\( "((?:""|[^"])*)" \)'
    matches = re.findall(pattern, content)
    if matches:
        return b''.join(matches)

    # Check if this looks like a preload wrapper (has PreloadStart/PreloadEnd but no Preload calls)
    # This happens when FileIO.Save is called with empty data
    if b'call PreloadStart()' in content and b'call PreloadEnd(' in content:
        return None

    # Fallback: return raw content if no preload wrapper found (for backwards compatibility)
    return content


def get_breakpoint_threads() -> List[bytes]:
    """Get list of thread IDs currently in a breakpoint by reading bp_threads.txt."""
    bp_threads_file = os.path.join(FILES_ROOT, "bp_threads.txt")
    if not os.path.exists(bp_threads_file):
        return []
    # Breakpoint metadata files are saved with isLoadable=False and mirrored to disk by the test harness
    content = load_nonloadable_file(bp_threads_file)
    if not content:
        return []
    if not content.strip():
        return []
    return [t.strip() for t in content.strip().split(b'\n') if t.strip()]


def get_breakpoint_info(thread_id: str) -> Optional[Dict[str, any]]:
    """Get breakpoint info for a specific thread by reading bp_data_<thread_id>.txt.

    File format is a single FIELD_SEP-separated record:
    bp_id<SEP>value<SEP>stack<SEP>stacktrace<SEP>var1<SEP>val1<SEP>var2<SEP>val2...

    Fields are parsed in pairs: key, value, key, value, ...
    - bp_id: breakpoint identifier
    - stack: stacktrace (with \\n for newlines)
    - other keys: local variable names with their values

    Returns a dict with keys: bp_id, stack, locals_values (dict of name->value).
    The 'locals' list is derived from locals_values keys.
    """
    bp_data_file = os.path.join(FILES_ROOT, f"bp_data_{thread_id}.txt")
    if not os.path.exists(bp_data_file):
        return None
    # Breakpoint metadata files are saved with isLoadable=False and mirrored to disk by the test harness
    content = load_nonloadable_file(bp_data_file)
    if not content:
        return None
    content_str = content
    text = content_str.strip()
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


def bp_list_threads() -> None:
    """List all threads currently in a breakpoint."""
    threads = get_breakpoint_threads()
    if not threads:
        print("No threads currently in a breakpoint.")
        return
    print(f"Threads in breakpoint ({len(threads)}):")
    for thread_id in threads:
        info = get_breakpoint_info(thread_id.decode('utf-8', errors='replace'))
        if info:
            bp_id = info.get('bp_id', 'unknown')
            print(f"  {thread_id}: breakpoint '{bp_id}'")
        else:
            print(f"  {thread_id}: (no info available)")


def bp_show_info(thread_id: str):
    """Show detailed breakpoint info for a specific thread."""
    info = get_breakpoint_info(thread_id)
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


# ============================================================================
# Breakpoint Command Functions (interact with game)
# ============================================================================

def send_breakpoint_command(thread_id: str, command: str) -> Optional[str]:
    """Send a command to a specific breakpoint thread and wait for response.

    Uses per-thread incrementing bp_in_<thread_id>_<idx>.txt files due to WC3 file caching.
    File content is just the raw command (no prefix needed since thread_id is in filename).
    Response: thread_id:cmd_index\\nresult <- bp_out.txt
    """
    global bp_command_indices

    if thread_id not in bp_command_indices:
        bp_command_indices[thread_id] = 0

    cmd_index = bp_command_indices[thread_id]

    # Write command to bp_in_<thread_id>_<cmd_index>.txt
    # File content is just the raw command (thread_id is in filename)
    filename = os.path.join(FILES_ROOT, f"bp_in_{thread_id}_{cmd_index}.txt")
    create_file(filename, command)

    # Wait for response in bp_out.txt
    expected_prefix = f"{thread_id}:{cmd_index}"
    start_time = time.time()
    timeout = 60  # Large timeout for reliability - actual response should be much faster
    debug = os.environ.get('WC3_E2E_DEBUG')

    if debug:
        print(f"[DEBUG] send_breakpoint_command: thread_id={thread_id}, cmd_index={cmd_index}")
        print(f"[DEBUG] Wrote command to: {filename}")
        print(f"[DEBUG] Waiting for response with prefix: {expected_prefix}")

    while time.time() - start_time < timeout:
        bp_out_file = os.path.join(FILES_ROOT, "bp_out.txt")
        if os.path.exists(bp_out_file):
            # Breakpoint output files are saved with isLoadable=False and mirrored to disk by the test harness
            content = load_nonloadable_file(bp_out_file)
            if content:
                index, result = parse_indexed_output(content)
                if debug:
                    print(f"[DEBUG] bp_out.txt content (first 100 bytes): {content[:100]}")
                    print(f"[DEBUG] Parsed index: {index}, expected: {expected_prefix}")
                if index and index.decode('utf-8', errors='replace') == expected_prefix:
                    bp_command_indices[thread_id] = cmd_index + 1
                    if debug:
                        print(f"[DEBUG] Got matching response!")
                    return result.decode('utf-8', errors='replace') if result else None
        time.sleep(0.1)

    if debug:
        print(f"[DEBUG] TIMEOUT waiting for {expected_prefix}")
        print(f"[DEBUG] bp_out.txt exists: {os.path.exists(bp_out_file)}")
        if os.path.exists(bp_out_file):
            content = load_nonloadable_file(bp_out_file)
            print(f"[DEBUG] Final bp_out.txt content: {content}")

    assert(time.time() - start_time < timeout)
    return None


def breakpoint_monitor_thread() -> None:
    """Background thread that monitors for new breakpoint threads.

    This thread handles breakpoint state management and prints BREAKPOINT HIT messages
    immediately when breakpoints are detected, without waiting for user input.
    """
    global current_breakpoint, pending_breakpoints
    known_threads: set[bytes] = set()
    while not bp_monitor_stop_event.is_set():
        current_threads: set[bytes] = set(get_breakpoint_threads())
        new_threads = current_threads - known_threads

        for thread_id_bytes in new_threads:
            thread_id = thread_id_bytes.decode('utf-8', errors='replace')
            info = get_breakpoint_info(thread_id)
            if not info:
                continue

            with bp_state_lock:
                # Update state
                if current_breakpoint is None:
                    current_breakpoint = (thread_id, info)
                else:
                    pending_breakpoints.append((thread_id, info))

                # Always print the BREAKPOINT HIT message immediately
                # Use the same format for both current and queued breakpoints
                print_breakpoint_hit(thread_id, info)

                # If this is a queued breakpoint, add a note about context
                if current_breakpoint[0] != thread_id:
                    print(f"[Note: this breakpoint is queued; current context stays at {current_breakpoint[0][:8]}... until you 'continue']", flush=True)

        known_threads = current_threads
        time.sleep(0.2)  # Check every 200ms


def start_breakpoint_monitor() -> None:
    """Start the background breakpoint monitoring thread."""
    global bp_monitor_thread
    if bp_monitor_thread is not None and bp_monitor_thread.is_alive():
        return
    bp_monitor_stop_event.clear()
    bp_monitor_thread = threading.Thread(target=breakpoint_monitor_thread, daemon=True)
    bp_monitor_thread.start()


def stop_breakpoint_monitor() -> None:
    """Stop the background breakpoint monitoring thread."""
    global bp_monitor_thread
    bp_monitor_stop_event.set()
    if bp_monitor_thread is not None:
        bp_monitor_thread.join(timeout=1.0)
        bp_monitor_thread = None


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


def handle_breakpoint_command(cmd: str) -> bool:
    """Handle a command in breakpoint context.

    Returns True if we should continue in breakpoint mode, False if exiting to normal mode.
    """
    global current_breakpoint, pending_breakpoints

    with bp_state_lock:
        if current_breakpoint is None:
            return False

        thread_id, info = current_breakpoint

    if cmd == "help":
        print("Breakpoint mode commands:")
        print("  list      - List all threads in breakpoint (current marked with *)")
        print("  thread <id> - Switch to a different breakpoint thread")
        print("  info      - Show detailed info for current thread")
        print("  continue  - Resume execution of current thread")
        print("  help      - Show this help message")
        print("  <lua>     - Execute Lua code in the breakpoint environment")
        return True

    if cmd == "list":
        threads = get_breakpoint_threads()
        if not threads:
            print("No threads currently in a breakpoint.")
        else:
            print(f"Threads in breakpoint ({len(threads)}):")
            for tid in threads:
                tid_str = tid.decode('utf-8', errors='replace')
                bp_info = get_breakpoint_info(tid_str)
                bp_name = bp_info.get('bp_id', 'unknown') if bp_info else 'unknown'
                marker = " *" if tid_str == thread_id else ""
                print(f"  {tid_str}: breakpoint '{bp_name}'{marker}")
        return True

    if cmd.startswith("thread "):
        new_thread_id = cmd[7:].strip()
        threads = get_breakpoint_threads()
        threads_str = [t.decode('utf-8', errors='replace') for t in threads]
        if new_thread_id in threads_str:
            new_info = get_breakpoint_info(new_thread_id)
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
        return True

    if cmd == "info":
        bp_show_info(thread_id)
        return True

    if cmd == "continue":
        response = send_breakpoint_command(thread_id, "continue")
        print(f"Resuming thread {thread_id}...")

        # Move to next pending breakpoint if any
        with bp_state_lock:
            if pending_breakpoints:
                next_bp = pending_breakpoints.pop(0)
                current_breakpoint = next_bp
                print_breakpoint_hit(next_bp[0], next_bp[1])
                if pending_breakpoints:
                    print(f"[{len(pending_breakpoints)} more breakpoint(s) pending]")
                return True
            else:
                # No more breakpoints - return to normal mode
                current_breakpoint = None
                print("[Returning to normal command mode]")
                return False

    # Send Lua command to game
    response = send_breakpoint_command(thread_id, cmd)
    if response is not None:
        print(response)
    else:
        print("(no response or timeout)")
    return True


def get_prompt() -> str:
    """Get the appropriate prompt based on current context."""
    with bp_state_lock:
        if current_breakpoint is not None:
            thread_id = current_breakpoint[0]
            short_id = thread_id[:8] if len(thread_id) > 8 else thread_id
            return f"bp:{short_id}... >>> "
        else:
            return f"{nextFile} >>> "

def signal_handler(sig: int, frame) -> None:
    """On any termination of the program we want to remove the input and output files and stop watchers"""
    stop_breakpoint_monitor()
    stop_all_watchers()
    remove_all_files()
    sys.exit(0)

nextFile: int = 0
send_lock: threading.Lock = threading.Lock()  # Thread safety for nextFile and file I/O

def send_data_to_game(data: str, print_prompt_after: bool = False):
    """Send data to the game and wait for response. Thread-safe.

    Uses single out.txt file with format: "{index}\\n{result}"

    Args:
        data: The Lua code to send to the game
        print_prompt_after: If True, print the prompt after the result (used for file/watch commands)
    """
    global nextFile
    if data == "":
        return
    with send_lock:
        create_file(os.path.join(FILES_ROOT, f"in{nextFile}.txt"), data)

        # Wait for response in out.txt with matching index
        out_file = os.path.join(FILES_ROOT, "out.txt")
        start_time = time.time()
        timeout = 60.0  # 60 second timeout

        while time.time() - start_time < timeout:
            if os.path.exists(out_file):
                try:
                    content = load_file(out_file)
                    if content:
                        index, result = parse_indexed_output(content)
                        if index == str(nextFile).encode('utf-8'):
                            if result != b"nil":
                                print(result.decode('utf-8', errors='replace'))
                            nextFile += 1
                            if print_prompt_after:
                                print(f"{nextFile} >>> ", end="", flush=True)
                            return
                except Exception as e:
                    print("failed. Got exception: ", e)
                    traceback.print_exc()
                    nextFile += 1
                    return
            time.sleep(0.1)

        print(f"Timeout waiting for response to command {nextFile}")
        nextFile += 1
        if print_prompt_after:
            print(f"{nextFile} >>> ", end="", flush=True)

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

def main() -> None:
    global nextFile, bp_command_indices, current_breakpoint, pending_breakpoints
    remove_all_files()
    # add a signal handler that handles all signals by removing all files and calling the default handler

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGABRT, signal_handler)
    signal.signal(signal.SIGSEGV, signal_handler)
    signal.signal(signal.SIGILL, signal_handler)

    # Start the breakpoint monitor thread
    start_breakpoint_monitor()

    print(f"Wc3 Interpreter {VERSION}. For help, type `help`.")
    while True:
        # Breakpoint state is managed by the background monitor thread
        # which prints BREAKPOINT HIT messages immediately when detected

        # get console input with context-appropriate prompt
        try:
            command = input(get_prompt())
        except EOFError:
            break

        cmd = command.strip()
        if cmd == "":
            continue

        # If we're in breakpoint context, route commands there
        with bp_state_lock:
            in_bp_mode = current_breakpoint is not None
        if in_bp_mode:
            # Handle breakpoint-specific commands
            handle_breakpoint_command(cmd)
            continue

        # Normal mode command handling
        if cmd == "exit":
            stop_breakpoint_monitor()
            stop_all_watchers()
            remove_all_files()
            break
        elif cmd == "help":
            print("Available commands:")
            print("  help - Show this help message")
            print("  exit - Exit the program")
            print("  restart - Cleans the state to allow a new game to be started (this is the same as exiting and restarting the script)")
            print("  jump <number> - use in case of closing the interpreter (or crashing) while game is still running. Starts sending commands from a specific file index. Should use the index printed in the prompt before the `>>>`")
            print("  file <full file path> - send a file with lua commands to the game. end the file with `return <data>` to print the data to the console")
            print("  watch <full file path> - watch a file for changes and automatically send it to the game on each update")
            print("  unwatch <full file path> - stop watching a file")
            print("  watching - list all files currently being watched")
            print("  bp list - list all threads currently in a breakpoint")
            print("  bp info <thread_id> - show detailed info for a breakpoint thread")
            print("  <lua command> - run a lua command in the game. If the command is a `return` statement, the result will be printed to the console.")
            print("** Note: exiting or restarting the script while the game is running will cause it to stop working until the game is also restarted **")
            print("** Note: OnInit calls in files sent via 'file' or 'watch' are automatically executed immediately **")
            print("\nBreakpoint support:")
            print("  When a Breakpoint() is hit in your Lua code, the prompt will change to 'bp:...'.")
            print("  In breakpoint mode, type 'help' for available commands (list, thread, info, continue).")
            print("  You can also query breakpoint data without entering breakpoint mode using 'bp list' and 'bp info'.")
            continue
        elif cmd == "restart":
            stop_breakpoint_monitor()
            stop_all_watchers()
            remove_all_files()
            nextFile = 0
            bp_command_indices = {}
            current_breakpoint = None
            pending_breakpoints = []
            start_breakpoint_monitor()
            print("State reset. You can start a new game now.")
            continue
        elif cmd.startswith("jump "):
            nextFile = int(cmd[5:].strip())
            continue
        elif cmd.startswith("watch "):
            filepath = cmd[6:].strip()
            start_watching(filepath, send_file_to_game)
            continue
        elif cmd.startswith("unwatch "):
            filepath = cmd[8:].strip()
            stop_watching(filepath)
            continue
        elif cmd == "watching":
            list_watched_files()
            continue
        elif cmd.startswith("file "):
            filepath = cmd[5:].strip()
            send_file_to_game(filepath)
            continue
        elif cmd == "bp list":
            bp_list_threads()
            continue
        elif cmd.startswith("bp info "):
            thread_id = cmd[8:].strip()
            bp_show_info(thread_id)
            continue
        else:
            # Send Lua command to game
            send_data_to_game(cmd)

if __name__ == "__main__":
    main()
