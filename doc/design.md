## Overall goal: Build a Shell as specified by [Codecrafters Challenge](https://app.codecrafters.io/courses/shell/overview) in Zig
* Builtins
  * cd [~]
  * echo
  * exit
  * history [-a|-r|-w|<last-N>]
  * pwd
  * type
* External commands on PATH environment variable
  * shell resolves command path via PATH lookup (subject to is_file and is_executable checks; also for`type` builtin)
  * child process receives original command name as `argv[0]` (e.g., `ls` sees `argv[0]="ls"`, not `/usr/bin/ls`)
  * partial command expanded to the full name on TAB, when that's the only candidate (`lsu` -> `lsusb ` - appending space)
  * when more than 1 candidate found (`ls`, `lsusb`, `lscpu`)
    * partial command expanded to the longest common prefix on TAB, also sends BEL '\a' (bell) to terminal (`ls` for above case)
    * print candidates on the next line in alphabetical order, separated by "  " (two spaces)
* Single ('quoted') and double quotes ("quoted") work as expected in Shell:
    * Escape  character is interpreted only unquoted ("a\ coommand" == "a command"), and in double-quotes,
    but only for a small set of chars ('$' | '`' | '"' | '\\' | '\n' ). So "\"a\ coommand\"" == "a\ command").
    * In single quotes only '\'' matters.
* STDOUT, STDERR >, 1>, >>, 1>>, 2>, 2>>
* Pipes (arbitrary number, builtins STDOUT is piped)
* Command _history_
  * is read from a file pointed by HISTFILE env. variable on startup
  * is read from `history -r <file-path>` <file-path> argument and appended to in-memory _history_
  * is appended to a file pointed by HISTFILE env. variable on shutdown
  * is appended to `history -a <file-path>` <file-path> argument. Running history -a multiple times should only append commands
    that have been executed since the last time history -a was run
  * is written to `history -w <file-path>` <file-path> argument
  * is shown on `history` command one command per line in two columns e.g. `    9 echo "Boo!"`
  * `history <N>` shows the last N commands (numbered like before, i.e. if there are 8 commands in history, the last line printed on `history 3` is `    9 history 3`)
  * previous commands displayed on ArrowUp / ArrowDown keypresses

## Goals for this project:
* Use no external library (though I may copy from well-known projects with liberal licenses provided there's only a handful of those)
* build a minimal terminal control library + line editor (TAB operates on pre-filled map of commands, found in PATH, history kept in global list, displayed on ArrowUp/Down)
* tokenizer should work as close to real shell as possible, e.g. "pwd|grep home" == "pwd | grep home", "pwd>/tmp/pwd" == "pwd > /tmp/pwd"
* ^C - exits shell (printing "^C" is nice but may be skipped), ^D - exits silently
