# MiShell

This repository is a solution to the
["Build Your Own Shell" Challenge](https://app.codecrafters.io/courses/shell/overview)
by lautitux (github.com/lautitux).  
It implements a very basic shell with support for running builtins (exit, echo, type, pwd, cd, history)
as well as executables that are in the PATH.

The currently supported features are:
* Strings without variable interpolation.
* Stdout and stderr redirection via the `>` and `>>` operators.
* Command pipelines via the `|` operator.
* Basic tab completion for builtins and executable files in $PATH only for the first word.
* Up and down arrow history navigation.

On the user input side, cursor movement is limited because the author decided not to use
a readline-like library and implement the basics themselves.

Currently apart from Tab-completion and history navigation it implements some basic keybord controls:   
`Ctrl-C` - _ETX_, `Ctrl-D` - _EOD_ (same as `exit` builtin), `Ctrl-L` - _FF_ (clear the screen).

## How to run it?

To run the project make sure to have **zig** version 0.15.2 installed, then clone the repo and run `zig build run`.
It should compile and run on Linux (and probably on other POSIX operating systems).

2026-01-27 12:47:52 -0300 lautitux

2026-01-30 14:22:52 +0400 mz0 fix BUG: upon exit on **Ctrl-D** terminal is not usable (input is not echoed)
