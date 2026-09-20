//! `engine/sink.zig` —— 事件汇聚点（P4：**一条事件流，多种传输**）。
//!
//! `engine` 只认识这个 sink；`server`（SSE）/`client_proto`（stream-json、ACP）/
//! headless 各自实现它。**引擎里不存在任何"给某个前端特判"的分支。**

const std = @import("std");
const common = @import("common");

pub const EventSink = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, ev: common.StreamEvent) anyerror!void,

    pub fn send(self: EventSink, ev: common.StreamEvent) !void {
        try self.emit_fn(self.ctx, ev);
    }
};

/// 把事件丢弃的 sink（测试/后台用）。
pub const DiscardingSink = struct {
    pub fn sink(self: *DiscardingSink) EventSink {
        return .{ .ctx = self, .emit_fn = emit };
    }
    fn emit(_: *anyopaque, _: common.StreamEvent) anyerror!void {}
};

/// 收集事件的 sink（**必须用来做断言**）。
pub const CollectingSink = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(common.StreamEvent) = .empty,

    pub fn init(gpa: std.mem.Allocator) CollectingSink {
        return .{ .gpa = gpa };
    }

    pub fn sink(self: *CollectingSink) EventSink {
        return .{ .ctx = self, .emit_fn = emit };
    }

    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *CollectingSink = @ptrCast(@alignCast(ctx));
        try self.events.append(self.gpa, ev);
    }

    pub fn deinit(self: *CollectingSink) void {
        self.events.deinit(self.gpa);
    }

    pub fn countOf(self: *CollectingSink, tag: std.meta.Tag(common.StreamEvent)) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (std.meta.activeTag(e) == tag) n += 1;
        }
        return n;
    }

    pub fn text(self: *CollectingSink, gpa: std.mem.Allocator) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(gpa);
        for (self.events.items) |e| {
            switch (e) {
                .text_delta => |d| try out.appendSlice(gpa, d.text),
                .reasoning_delta => {},
                else => {},
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

test "sink: 收集与丢弃" {
    var c = CollectingSink.init(testing.allocator);
    defer c.deinit();
    const s = c.sink();
    try s.send(.{ .text_delta = .{ .text = "你好" } });
    try s.send(.{ .text_delta = .{ .text = "世界" } });
    try s.send(.{ .status = .{ .message = "x" } });
    try testing.expectEqual(@as(usize, 2), c.countOf(.text_delta));
    const joined = try c.text(testing.allocator);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("你好世界", joined);

    var d = DiscardingSink{};
    try d.sink().send(.{ .status = .{ .message = "ignored" } });
}
