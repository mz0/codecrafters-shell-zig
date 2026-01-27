const std = @import("std");
const posix = std.posix;

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
    home,
    end,
    unknown,
};

pub const Terminal = struct {
    original_termios: ?posix.termios,
    raw_termios: ?posix.termios,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    is_tty: bool,

    pub fn init() Terminal {
        const stdin_fd = posix.STDIN_FILENO;
        const stdout_fd = posix.STDOUT_FILENO;

        // Check if stdin is a terminal
        const original = posix.tcgetattr(stdin_fd) catch {
            // Not a terminal - use cooked mode
            return .{
                .original_termios = null,
                .raw_termios = null,
                .stdin_fd = stdin_fd,
                .stdout_fd = stdout_fd,
                .is_tty = false,
            };
        };

        // Enter raw mode
        var raw = original;
        // Input flags: disable ICRNL (CR->NL), IXON (Ctrl-S/Q)
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        // Local flags: disable echo, canonical mode, signals
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        // Read returns after 1 byte
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {};

        return .{
            .original_termios = original,
            .raw_termios = raw,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .is_tty = true,
        };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.original_termios) |orig| {
            posix.tcsetattr(self.stdin_fd, .FLUSH, orig) catch {};
        }
    }

    /// Temporarily restore cooked mode for external commands
    pub fn restoreCooked(self: *Terminal) void {
        if (self.original_termios) |orig| {
            posix.tcsetattr(self.stdin_fd, .FLUSH, orig) catch {};
        }
    }

    /// Re-enter raw mode after external command completes
    pub fn enterRaw(self: *Terminal) void {
        if (self.raw_termios) |raw| {
            posix.tcsetattr(self.stdin_fd, .FLUSH, raw) catch {};
        }
    }

    pub fn readKey(self: *Terminal) !Key {
        var buf: [1]u8 = undefined;
        const n = try posix.read(self.stdin_fd, &buf);
        if (n == 0) return .ctrl_d;

        const c = buf[0];

        // In cooked mode, just return chars and newlines
        if (!self.is_tty) {
            if (c == '\n') return .enter;
            return .{ .char = c };
        }

        // Handle control characters (raw mode)
        if (c == 3) return .ctrl_c; // Ctrl+C
        if (c == 4) return .ctrl_d; // Ctrl+D
        if (c == 9) return .tab;
        if (c == 13 or c == 10) return .enter;
        if (c == 127 or c == 8) return .backspace;

        // Handle escape sequences
        if (c == 27) {
            return self.readEscapeSequence();
        }

        return .{ .char = c };
    }

    fn readEscapeSequence(self: *Terminal) !Key {
        var seq: [3]u8 = undefined;

        // Try to read more bytes (non-blocking would be better but this works)
        const n1 = posix.read(self.stdin_fd, seq[0..1]) catch return .unknown;
        if (n1 == 0) return .unknown;

        if (seq[0] == '[') {
            const n2 = posix.read(self.stdin_fd, seq[1..2]) catch return .unknown;
            if (n2 == 0) return .unknown;

            switch (seq[1]) {
                'A' => return .arrow_up,
                'B' => return .arrow_down,
                'C' => return .arrow_right,
                'D' => return .arrow_left,
                'H' => return .home,
                'F' => return .end,
                '3' => {
                    // Delete key: ESC [ 3 ~
                    _ = posix.read(self.stdin_fd, seq[2..3]) catch {};
                    return .delete;
                },
                else => return .unknown,
            }
        }

        return .unknown;
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        _ = try posix.write(self.stdout_fd, bytes);
    }

    pub fn bell(self: *Terminal) void {
        _ = posix.write(self.stdout_fd, "\x07") catch {};
    }

    pub fn clearLine(self: *Terminal) void {
        // Move to start of line and clear
        _ = posix.write(self.stdout_fd, "\r\x1b[K") catch {};
    }

    pub fn moveCursorLeft(self: *Terminal, n: usize) void {
        if (n == 0) return;
        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d}D", .{n}) catch return;
        _ = posix.write(self.stdout_fd, seq) catch {};
    }

    pub fn moveCursorRight(self: *Terminal, n: usize) void {
        if (n == 0) return;
        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d}C", .{n}) catch return;
        _ = posix.write(self.stdout_fd, seq) catch {};
    }
};
