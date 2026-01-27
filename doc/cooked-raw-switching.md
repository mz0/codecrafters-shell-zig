A typical Unix shell (like bash or zsh) is constantly switching the terminal between
_cooked_ (_canonical_) and _non-canonical_ modes, although the user only perceives
this as seamless, interactive command-line editing. 

Here is a breakdown of how this constant switching works:

* Default State (Cooked/Canonical): While waiting for you to type a command, the shell keeps the terminal in "cooked"
  mode. In this mode, the operating system kernel handles input buffering, allowing you to use Backspace
  to delete characters and only sending the command to the shell when you press Enter.
* The Switch: When you are typing, the line-editing library (like Readline) or the shell itself temporarily switches
  to a mode that behaves like raw mode (often called _cbreak_ or non-canonical) to process special keystrokes instantly
  (e.g., Tab completion, arrow keys for history).
* Running Commands (Back to Cooked): When you press Enter and the shell executes a command, the terminal
  is generally restored to canonical (cooked) mode so that the command receives your input line-by-line.

Text Editors (Full Raw Mode): When you open a program like `vi`, or `top`, the program takes full control and switches
the terminal into strict _raw_ mode. This means the program receives every single character (like arrow keys or Ctrl+C)
directly, and the terminal does not echo them automatically.

Upon Exit: When the program (e.g., `vi`) exits, the shell switches the terminal back
to cooked mode to handle your next command.

Summary: The terminal driver switches modes frequently—often with every command line entered,
and every time a full-screen application is launched — to balance the need for user-friendly line editing
with the need for immediate, character-by-character input processing.

So the following
```shell
cat > /tmp/aa.txt <Enter>
Hello <Enter>
^D
```
works in canonical mode: <Enter> and EOF are passed to `cat` via STDIN (??)

See `man 3 termios` (libc)
```
Canonical and noncanonical mode
    The setting of the ICANON canon flag in c_lflag determines whether the terminal is operating in canonical mode
    (ICANON set) or noncanonical mode (ICANON unset).  By default, ICANON is set.

    In canonical mode:

    •  Input is made available line by line.  An input line is available when one of the line delimiters is  typed
       (NL, EOL, EOL2; or EOF at the start of line).  Except in the case of EOF, the line delimiter is included in
       the buffer returned by read(2).

    •  Line  editing  is  enabled (ERASE, KILL; and if the IEXTEN flag is set: WERASE, REPRINT, LNEXT).  A read(2)
       returns at most one line of input; if the read(2) requested fewer bytes than are available in  the  current
       line  of  input, then only as many bytes as requested are read, and the remaining characters will be avail‐
       able for a future read(2).

    •  The maximum line length is 4096 chars (including the terminating newline character); lines longer than 4096
       chars are truncated.  After 4095 characters, input processing (e.g., ISIG and ECHO* processing)  continues,
       but  any  input  data after 4095 characters up to (but not including) any terminating newline is discarded.
       This ensures that the terminal can always receive more input until at least one line can be read.

    In noncanonical mode input is available immediately (without the user having to type a line-delimiter  charac‐
    ter),  no  input processing is performed, and line editing is disabled.  The read buffer will only accept 4095
    chars; this provides the necessary space for a newline char if the input mode is switched to  canonical.
```
