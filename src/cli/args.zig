//! `cli/args.zig` —— argv 解析（**纯逻辑，零 IO**）。
//!
//! 只做首期需要的形状；不引入命令框架（对标文档 14：44 个子命令里首期只需少数几个）。
//!
//! 退出码契约（雷区 H）：
//!   - headless **不支持的 flag → exit 2**
//!   - `--internal-resume-check`：exit 1 = 已触发崩溃恢复，Shell 让位

const std = @import("std");

pub const Command = enum {
    help,
    version,
    serve,
    /// 交互式 REPL（人用的形态：读完一轮接一轮）
    repl,
    /// 一次性、NDJSON 输出（程序用的形态）
    print,
    acp,
    unknown,
};

pub const Options = struct {
    command: Command = .repl,
    /// `serve --port`
    port: u16 = 0,
    /// `serve --token` / env
    token: ?[]const u8 = null,
    /// `--print <prompt>` 或第一个位置参数
    prompt: ?[]const u8 = null,
    /// `--output-format stream-json`
    stream_json: bool = false,
    /// `--resume <sessionId>`
    resume_session: ?[]const u8 = null,
    /// `--model`
    model: ?[]const u8 = null,
    /// `--permission-mode`
    permission_mode: ?[]const u8 = null,
    /// `--verbose`
    verbose: bool = false,
    /// `--mock-sse <file>`：把录制好的 SSE 走一遍完整链路（**零网络演示 / 冒烟**）
    mock_sse: ?[]const u8 = null,
    /// `--web-root <dir>`：UI 静态资源目录（默认 `<cwd>/web`）
    web_root: ?[]const u8 = null,
    /// 未知 flag（用于 exit 2）
    unknown_flag: ?[]const u8 = null,
};

pub const ParseError = error{ExitTwo};

pub fn parse(argv: []const []const u8) ParseError!Options {
    var o = Options{};
    var i: usize = 1; // 跳过 argv[0]
    var positional_seen = false;

    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            o.command = .version;
            return o;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            o.command = .help;
            return o;
        }
        if (std.mem.eql(u8, a, "--verbose")) {
            o.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--interactive") or std.mem.eql(u8, a, "-i")) {
            o.command = .repl;
            continue;
        }
        if (std.mem.eql(u8, a, "--print") or std.mem.eql(u8, a, "-p")) {
            o.command = .print;
            if (i + 1 < argv.len) {
                i += 1;
                o.prompt = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--serve")) {
            o.command = .serve;
            continue;
        }
        if (std.mem.eql(u8, a, "--output-format")) {
            if (i + 1 < argv.len) {
                i += 1;
                if (std.mem.eql(u8, argv[i], "stream-json")) o.stream_json = true;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--input-format")) {
            if (i + 1 < argv.len) i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--port")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.port = std.fmt.parseInt(u16, argv[i], 10) catch 0;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--token")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.token = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--web-root")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.web_root = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--mock-sse")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.mock_sse = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--resume")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.resume_session = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--model")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.model = argv[i];
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--permission-mode")) {
            if (i + 1 < argv.len) {
                i += 1;
                o.permission_mode = argv[i];
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            o.unknown_flag = a;
            return error.ExitTwo;
        }
        if (!positional_seen) {
            positional_seen = true;
            if (std.mem.eql(u8, a, "serve")) {
                o.command = .serve;
            } else if (std.mem.eql(u8, a, "acp")) {
                o.command = .acp;
            } else if (std.mem.eql(u8, a, "version")) {
                o.command = .version;
            } else if (std.mem.eql(u8, a, "help")) {
                o.command = .help;
            } else {
                // 人给的第一个位置参数 = 第一句话，然后进交互
                o.command = .repl;
                o.prompt = a;
            }
            continue;
        }
        // acp serve 的第二个位置参数
        if (o.command == .acp and std.mem.eql(u8, a, "serve")) continue;
        o.unknown_flag = a;
        return error.ExitTwo;
    }
    return o;
}

pub const USAGE =
    \\Zigent — a coding agent kernel
    \\
    \\Usage:
    \\  zigent                       Show this help
    \\  zigent --version             Print the version
    \\  zigent serve [--port N]      Start the local HTTP + SSE server
    \\  zigent --print "<prompt>"    Run one prompt headless (stdout = protocol)
    \\  zigent acp serve             Serve ACP over NDJSON on stdin/stdout
    \\
    \\Options:
    \\  --model <id>                  Override the model
    \\  --permission-mode <mode>      ASK | ACCEPT_EDITS | BYPASS_PERMISSIONS | PLAN
    \\  --resume <sessionId>          Resume a stored session
    \\  --output-format stream-json   NDJSON event output (headless)
    \\  --verbose                     More logging on stderr
    \\
;

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "args: 无参数 → REPL" {
    const o = try parse(&.{"zigent"});
    try testing.expectEqual(Command.repl, o.command);
    try testing.expect(o.prompt == null);
}

test "args: --print 仍是一次性 NDJSON 形态" {
    const o = try parse(&.{ "zigent", "--print", "x" });
    try testing.expectEqual(Command.print, o.command);
}

test "args: --version" {
    const o = try parse(&.{ "zigent", "--version" });
    try testing.expectEqual(Command.version, o.command);
}

test "args: serve --port 0" {
    const o = try parse(&.{ "zigent", "serve", "--port", "0" });
    try testing.expectEqual(Command.serve, o.command);
    try testing.expectEqual(@as(u16, 0), o.port);
}

test "args: --print 带引号的长命令" {
    const o = try parse(&.{ "zigent", "--print", "读一下 src/main.zig" });
    try testing.expectEqual(Command.print, o.command);
    try testing.expectEqualStrings("读一下 src/main.zig", o.prompt.?);
}

test "args: 位置参数进 REPL 并作为第一句话" {
    const o = try parse(&.{ "zigent", "修复这个 bug" });
    try testing.expectEqual(Command.repl, o.command);
    try testing.expectEqualStrings("修复这个 bug", o.prompt.?);
}

test "args: acp serve" {
    const o = try parse(&.{ "zigent", "acp", "serve" });
    try testing.expectEqual(Command.acp, o.command);
}

test "args: 不支持的 flag → exit 2" {
    try testing.expectError(error.ExitTwo, parse(&.{ "zigent", "--nonsense" }));
}

test "args: --output-format stream-json" {
    const o = try parse(&.{ "zigent", "--print", "x", "--output-format", "stream-json" });
    try testing.expect(o.stream_json);
}

test "args: --mock-sse 录制回放" {
    const o = try parse(&.{ "zigent", "--print", "x", "--mock-sse", "tests/fixtures/sse/a.txt" });
    try testing.expectEqualStrings("tests/fixtures/sse/a.txt", o.mock_sse.?);
}

test "args: --resume 与 --model" {
    const o = try parse(&.{ "zigent", "serve", "--resume", "sess-1", "--model", "m" });
    try testing.expectEqualStrings("sess-1", o.resume_session.?);
    try testing.expectEqualStrings("m", o.model.?);
}
