# Implementation Plan

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Main Loop                            │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐               │
│  │ Terminal │───▶│  Line    │───▶│ Tokenizer│               │
│  │  (raw)   │◀───│  Editor  │    │          │               │
│  └──────────┘    └──────────┘    └────┬─────┘               │
│                                       │                     │
│                                       ▼                     │
│                               ┌──────────────┐              │
│                               │   Executor   │              │
│                               │  ┌────────┐  │              │
│                               │  │Builtins│  │              │
│                               │  └────────┘  │              │
│                               │  ┌────────┐  │              │
│                               │  │External│  │              │
│                               │  └────────┘  │              │
│                               └──────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

## Modules

| Module | Responsibility |
|--------|----------------|
| `main.zig` | Entry point, main REPL loop, signal setup |
| `terminal.zig` | Raw mode, read keypress, write output |
| `line_editor.zig` | Line buffer, cursor, history (list + navigation + file I/O), TAB completion |
| `tokenizer.zig` | Split input into tokens, handle quotes/escapes |
| `executor.zig` | Dispatch to builtin or spawn external, setup pipes/redirects |
| `builtins.zig` | cd, echo, exit, history, pwd, type |
| `path.zig` | PATH parsing, command lookup, completion candidates |

## Data Structures

### Token
```zig
const Token = struct {
    kind: enum { word, pipe, redirect_out, redirect_out_append, redirect_err, redirect_err_append },
    value: []const u8,  // for word: the text; for redirect: the fd or filename
};
```

### Command (single command in a pipeline)
```zig
const Command = struct {
    argv: []const []const u8,
    stdout_file: ?[]const u8 = null,
    stdout_append: bool = false,
    stderr_file: ?[]const u8 = null,
    stderr_append: bool = false,
};
```

### Pipeline
```zig
const Pipeline = struct {
    commands: []Command,
};
```

## Implementation Phases

### Phase 1: Minimal REPL
- `main.zig`: Print prompt, read line (cooked mode, std.io), print "command not found"
- `exit` builtin with exit code
- **Milestone**: Pass `codecrafters test` steps 1-3

### Phase 2: Builtins + External Commands
- `builtins.zig`: echo, pwd, cd, type
- `path.zig`: Parse PATH, lookup executable
- `executor.zig`: Fork/exec external commands (std.process.Child)
- **Milestone**: Run commands like `ls`, `cat /etc/passwd`

### Phase 3: Terminal Raw Mode + Basic Line Editor
- `terminal.zig`: Enter/exit raw mode, read single keypress
- `line_editor.zig`: Buffer, backspace, enter (no arrows/TAB yet)
- Main loop structure stabilizes here
- **Milestone**: Editable command line in raw mode

### Phase 4: Tokenizer
- `tokenizer.zig`: Split on whitespace, handle `|`, `>`, `>>`, `2>`, `2>>`
- Handle single quotes, double quotes, escape sequences
- **Milestone**: `echo "hello world"`, `echo 'it'\''s'`

### Phase 5: Redirections
- `executor.zig`: Open files, dup2 for stdout/stderr
- **Milestone**: `ls > /tmp/out`, `ls 2> /tmp/err`

### Phase 8: TAB Completion
- TAB-completion should work for builtins too
- `path.zig`: Build command map from PATH on startup
- `line_editor.zig`: Single match → complete; multiple → bell, second TAB → longest common prefix
- **Milestone 1**: `echo hello^H^H^H^Hbye!` → `echo bye!`, Tab, Del, Arrows - send BEL (\a)
- **Milestone 2**: `ec<TAB>` → `echo `
- **Milestone 3**: `lsu<TAB>` → `lsusb `
- **Milestone 4**: `ls<TAB>` → BEL`ls` / <TAB2> → print candidates

### Phase 6: Pipes
- `executor.zig`: Create pipes, connect commands
- **Milestone**: `cat /etc/passwd | grep root | wc -l`

### Phase 7: History + Arrow Navigation
- `line_editor.zig`: In-memory history list, ArrowUp/Down navigation, cursor left/right
- Load from HISTFILE on startup, save on exit
- `history` builtin with -a/-r/-w flags
- **Milestone**: Navigate previous commands, persist across sessions

### Phase 9: Signals
- Ctrl+C exits (raw mode catches it directly), Ctrl+D exits silently (on empty line)
- **Milestone**: Clean exit on signals

## File Layout
```
src/
├── builtins.zig
├── executor.zig
├── line_editor.zig   (includes history)
├── main.zig
├── path.zig
├── terminal.zig
└── tokenizer.zig
```

## Testing Strategy
- Unit tests in each module (`test` blocks in Zig)
- Tokenizer: Test quote handling, escapes, edge cases
- Integration: Use Codecrafters test harness
- Manual: Interactive testing for line editor, completion

## Decisions
1. **History module**: Lives inside `line_editor.zig` (keep under ~500 lines)
2. **Error handling**: Print to STDERR and continue
3. **Memory management**: General purpose allocator (GPA)
