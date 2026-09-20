//! `cli/render.zig` —— 把事件流渲染成**人看的**样式。
//!
//! ## 一条纪律：**散文走 stdout，chrome 走 stderr**
//!
//! - 模型说的话（`text_delta`）→ **stdout**
//! - 工具行、进度、错误、计量、提示 → **stderr**
//!
//! 好处：`zigent "改一下这个 bug" > answer.txt` 拿到的**只有回答本身**，
//! 不会被工具日志污染。这也和"stdout 只走协议"的交付契约同源。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const util = @import("util");
const engine = @import("engine");

pub const Renderer = struct {
    gpa: Allocator,
    io: Io,
    /// 已经吐过第一个字（决定要不要在工具行前补换行）
    in_text: bool = false,
    /// 第一条 session_started 才打印会话头
    greeted: bool = false,
    /// 工具名缓存：tool_use_id → name（tool_result 只带 id）
    tools: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// 显示推理流（默认关：对多数人是噪音）
    show_reasoning: bool = false,

    pub fn init(gpa: Allocator, io: Io) Renderer {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.tools.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.tools.deinit(self.gpa);
    }

    pub fn sink(self: *Renderer) engine.EventSink {
        return .{ .ctx = self, .emit_fn = emit };
    }

    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *Renderer = @ptrCast(@alignCast(ctx));
        try self.render(ev);
    }

    fn out(self: *Renderer, comptime fmt: []const u8, args: anytype) void {
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        util.io.writeStdout(self.io, s) catch {};
    }

    fn err(self: *Renderer, comptime fmt: []const u8, args: anytype) void {
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        util.io.writeStderr(self.io, s);
    }

    /// 工具行之前先收尾当前文本行（否则会和正文挤在同一行）。
    fn breakLine(self: *Renderer) void {
        if (self.in_text) {
            self.out("\n", .{});
            self.in_text = false;
        }
    }

    pub fn render(self: *Renderer, ev: common.StreamEvent) !void {
        switch (ev) {
            .text_delta => |d| {
                self.in_text = true;
                self.out("{s}", .{d.text});
            },
            .reasoning_delta => |d| {
                if (self.show_reasoning) {
                    self.breakLine();
                    self.err("\x1b[2m  ~ {s}\x1b[0m\n", .{oneLine(d.text, 120)});
                }
            },
            .tool_call => |c| {
                self.breakLine();
                // 记住 id → 名字，供 tool_result 用
                const k = self.gpa.dupe(u8, c.tool_use_id) catch return;
                self.tools.put(self.gpa, k, c.tool_name) catch {};
                var sbuf: [256]u8 = undefined;
                self.err("\n  \x1b[36m▶\x1b[0m {s} \x1b[2m{s}\x1b[0m\n", .{ c.tool_name, summarizeInto(&sbuf, c.input) });
            },
            .tool_progress => |p| {
                if (p.message) |m| {
                    self.err("\x1b[2m    … {s}\x1b[0m\n", .{oneLine(m, 120)});
                }
            },
            .tool_result => |r| {
                const name = self.tools.get(r.tool_use_id) orelse "tool";
                const mark = if (r.is_error) "\x1b[31m✗\x1b[0m" else "\x1b[32m✓\x1b[0m";
                self.err("  {s} {s} \x1b[2m({d}ms, {d} 字符)\x1b[0m\n", .{
                    mark, name, r.duration_ms, common.usage.countCodePoints(r.output),
                });
                // 失败时把第一行原因显示出来（成功时不刷屏 —— 正文里模型会总结）
                if (r.is_error) {
                    self.err("\x1b[31m    {s}\x1b[0m\n", .{oneLine(r.output, 300)});
                }
            },
            .error_event => |e| {
                self.breakLine();
                if (e.terminal) {
                    self.err("\n  \x1b[31m✗ 失败\x1b[0m [{s}] {s}\n", .{ e.error_code, e.message });
                } else {
                    self.err(
                        "\n  \x1b[33m!\x1b[0m {s} \x1b[2m({s}, 重试 {d}/{d}，{d}ms 后)\x1b[0m\n",
                        .{ e.message, e.error_code, e.retry_attempt, e.max_retries, e.retry_delay_ms },
                    );
                }
            },
            .compact_boundary => |c| {
                self.breakLine();
                self.err(
                    "\n  \x1b[2m⋯ 上下文压缩（{s}）：{d} → {d} 条消息，约 {d} → {d} tokens\x1b[0m\n",
                    .{ c.kind, c.before_messages, c.after_messages, c.tokens_before, c.tokens_after },
                );
            },
            .turn_complete => |t| {
                self.err("\x1b[2m  · 输出 {d} tokens，{d}ms\x1b[0m\n", .{ t.usage.output_tokens, t.duration_ms });
            },
            .session_started => |s| {
                if (self.greeted) return;
                self.greeted = true;
                const model = if (s.model.len > 0) s.model else "(未配置模型)";
                self.err("\x1b[1mZigent\x1b[0m  \x1b[2m{s} · {s} · 权限 {s}\x1b[0m\n", .{
                    s.cwd, model, s.mode,
                });
                self.err("\x1b[2m输入你的要求；/help 看命令；Ctrl-C 取消本轮或退出\x1b[0m\n", .{});
            },
            .session_ended => |s| {
                self.err(
                    "\x1b[2m  · 本轮结束：{d} 轮 / {d} 次工具 / {d} tokens / {d}ms\x1b[0m\n",
                    .{ s.turn_count, s.tool_call_count, s.total_tokens, s.duration_ms },
                );
            },
            .status => |s| self.err("\x1b[2m  {s}\x1b[0m\n", .{s.message}),
            else => {}, // 扩展事件与计量细节：交互模式下不刷屏
        }
    }

    /// 会话头（由 REPL 在开始处调用一次）。
    pub fn banner(self: *Renderer, version: []const u8) void {
        self.err("\x1b[1mZigent\x1b[0m \x1b[2m{s}\x1b[0m\n", .{version});
    }
};

/// 取一行（压掉换行，按 code point 截断）。
pub fn oneLine(s: []const u8, max_cp: usize) []const u8 {
    for (s, 0..) |c, i| {
        if (c == '\n' or c == '\r') return s[0..i];
    }
    return common.usage.truncateCodePoints(s, max_cp);
}

/// 从工具入参里挑一个"最能说明它在干嘛"的字段，**写进调用方的缓冲**。
///
/// 为什么不用"返回 arena 切片"：那样返回的指针在函数返回时就悬垂了。
/// 交互渲染是每秒几十次的小操作，写进栈缓冲最省事也最安全。
pub fn summarizeInto(buf: []u8, input: []const u8) []const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const v = common.json.parse(arena.allocator(), input) catch return copyTrunc(buf, input, 90);
    const keys = [_][]const u8{ "file_path", "path", "command", "pattern", "query", "prompt", "url" };
    for (keys) |k| {
        if (v.getString(k)) |val| return copyTrunc(buf, val, 90);
    }
    return copyTrunc(buf, input, 90);
}

fn copyTrunc(buf: []u8, s: []const u8, max_cp: usize) []const u8 {
    const line = oneLine(s, max_cp);
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    return buf[0..n];
}

const testing = std.testing;

test "render: oneLine 截到第一行" {
    try testing.expectEqualStrings("第一行", oneLine("第一行\n第二行", 100));
    try testing.expectEqualStrings("abc", oneLine("abcdef", 3));
}

test "render: summarizeInto 优先挑关键字段，且不悬垂" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/a/b.zig", summarizeInto(&buf, "{\"file_path\":\"/a/b.zig\",\"command\":\"ls\"}"));
    try testing.expectEqualStrings("ls -la", summarizeInto(&buf, "{\"command\":\"ls -la\"}"));
    // 非法 JSON 也不能 panic
    try testing.expectEqualStrings("not json", summarizeInto(&buf, "not json"));
}
