# Module Design

## terminal.zig

Handles low-level terminal I/O in raw mode.

```zig
pub const Terminal = struct {
    original_termios: std.posix.termios,

    pub fn init() !Terminal;          // save termios, enter raw mode
    pub fn deinit(self: *Terminal) void;  // restore termios

    pub fn readKey() !Key;            // blocking read, decode escape sequences
    pub fn write(bytes: []const u8) !void;
    pub fn bell() void;               // write '\a'
};

pub const Key = union(enum) {
    char: u8,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    backspace,
    delete,
    tab,
    enter,
    ctrl_c,
    ctrl_d,
    unknown,
};
```

## line_editor.zig

Editable line buffer with cursor, history storage/navigation, and completion.

```zig
// --- History (embedded in this module) ---
pub const History = struct {
    entries: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) History;
    pub fn deinit(self: *History) void;

    pub fn add(self: *History, line: []const u8) !void;
    pub fn get(self: *History, index: usize) ?[]const u8;
    pub fn len(self: *History) usize;

    pub fn loadFromFile(self: *History, path: []const u8) !void;
    pub fn appendToFile(self: *History, path: []const u8) !void;    // -a
    pub fn writeToFile(self: *History, path: []const u8) !void;     // -w
    pub fn appendFromFile(self: *History, path: []const u8) !void;  // -r (appended to current)
};

// --- Line Editor ---
pub const LineEditor = struct {
    buffer: std.ArrayList(u8),
    cursor: usize,
    history: History,
    history_index: ?usize,           // null = editing new line
    completer: *PathResolver,

    pub fn init(allocator: Allocator, completer: *PathResolver) LineEditor;
    pub fn deinit(self: *LineEditor) void;

    pub fn handleKey(self: *LineEditor, key: Key) !Action;
    pub fn getLine(self: *LineEditor) []const u8;
    pub fn clear(self: *LineEditor) void;
    pub fn getHistory(self: *LineEditor) *History;
};

pub const Action = enum {
    continue_editing,
    submit,         // Enter pressed
    cancel,         // Ctrl+C
    eof,            // Ctrl+D on empty line
};
```

## tokenizer.zig

Splits input string into tokens, handling quotes and escapes.

```zig
pub const TokenKind = enum {
    word,
    pipe,               // |
    redirect_out,       // > or 1>
    redirect_append,    // >> or 1>>
    redirect_err,       // 2>
    redirect_err_append,// 2>>
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

pub const Tokenizer = struct {
    pub fn init(input: []const u8, allocator: Allocator) Tokenizer;
    pub fn next() !?Token;
    pub fn tokenize() ![]Token;       // all tokens at once
};

pub const TokenizeError = error{
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
    UnexpectedEOF,
};
```

## executor.zig

Parses tokens into commands, sets up pipes/redirects, runs commands.

```zig
pub const Command = struct {
    argv: []const []const u8,
    stdout_file: ?[]const u8,
    stdout_append: bool,
    stderr_file: ?[]const u8,
    stderr_append: bool,
};

pub const Pipeline = struct {
    commands: []Command,
};

pub fn parse(tokens: []const Token, allocator: Allocator) !Pipeline;
pub fn execute(pipeline: Pipeline, builtins: *Builtins, path_resolver: *PathResolver) !u8;
```

## builtins.zig

Implementation of shell builtins.

```zig
const line_editor = @import("line_editor.zig");

pub const Builtins = struct {
    history: *line_editor.History,    // reference to LineEditor's history
    path_resolver: *PathResolver,
    allocator: Allocator,

    pub fn init(allocator: Allocator, history: *line_editor.History, path_resolver: *PathResolver) Builtins;

    /// Returns exit code, or null if not a builtin
    pub fn run(self: *Builtins, argv: []const []const u8, stdout: anytype, stderr: anytype) ?u8;

    // Individual builtins
    fn builtin_cd(args: []const []const u8) u8;
    fn builtin_echo(args: []const []const u8, stdout: anytype) u8;
    fn builtin_exit(args: []const []const u8) noreturn;
    fn builtin_pwd(stdout: anytype) u8;
    fn builtin_type(self: *Builtins, args: []const []const u8, stdout: anytype) u8;

    // history [<N>] | -a <file> | -r <file> | -w <file>
    //   (no args)  - print all history, numbered
    //   <N>        - print last N entries, numbered from (total-N+1)
    //   -a <file>  - append current history to file
    //   -r <file>  - append file contents to current history
    //   -w <file>  - overwrite file with current history
    fn builtin_history(self: *Builtins, args: []const []const u8, stdout: anytype) u8;
};
```

## path.zig

PATH environment parsing, command lookup, and completion.

```zig
pub const PathResolver = struct {
    dirs: []const []const u8,
    command_cache: std.StringHashMap([]const u8),  // command name -> full path
    allocator: Allocator,

    pub fn init(allocator: Allocator) !PathResolver;
    pub fn deinit(self: *PathResolver) void;

    pub fn resolve(self: *PathResolver, command: []const u8) ?[]const u8;
    pub fn getCompletions(self: *PathResolver, prefix: []const u8) ![]const []const u8;
    pub fn longestCommonPrefix(candidates: []const []const u8) []const u8;
};
```

## main.zig

Entry point and main loop.

```zig
pub fn main() !void {
    // 1. Initialize GPA allocator
    // 2. Initialize PathResolver (parse PATH, build command cache)
    // 3. Initialize LineEditor (includes History)
    // 4. Load history from HISTFILE env var
    // 5. Initialize Builtins (pass history reference, path resolver)
    // 6. Setup terminal raw mode
    // 7. REPL:
    //    a. Print prompt "$ "
    //    b. Read/edit line via LineEditor
    //    c. On submit: tokenize, execute, add to history
    //    d. On Ctrl+C/Ctrl+D: break loop
    // 8. Save history to HISTFILE
    // 9. Restore terminal, cleanup
}
```

## Dependencies Between Modules

```
main
 ├── terminal
 ├── line_editor (includes History)
 │    └── path (for completion)
 ├── tokenizer
 ├── executor
 │    ├── builtins
 │    │    └── line_editor.History (reference)
 │    └── path (for resolution)
 └── path
```
