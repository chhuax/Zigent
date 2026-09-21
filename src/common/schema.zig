//! `schema.Spec` —— **单一真源**（文档 03 §9.4）。
//!
//! 为什么这是 tools 层最重要的设计：schema 双轨（内部校验用一份、给模型看另一份）
//! 已经出过两次事故（`agent` 的 `isolation` 文案矛盾 4 天；`Grep` 的 `head_limit`
//! 文案说 250、代码实际 100）。**一份 `Spec` 同时生成模型 schema 与运行期校验器，
//! 结构上不可能分叉。**
//!
//! 校验器**只读**输入：绝不 parse → re-serialize（不变量 I1）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

pub const ValueType = enum {
    string,
    integer,
    number,
    boolean,
    array,
    object,

    pub fn wireName(self: ValueType) []const u8 {
        return switch (self) {
            .string => "string",
            .integer => "integer",
            .number => "number",
            .boolean => "boolean",
            .array => "array",
            .object => "object",
        };
    }
};

pub const Field = struct {
    name: []const u8,
    type: ValueType,
    required: bool = false,
    description: []const u8 = "",
    /// 枚举约束（`null` = 不约束）
    enum_values: []const []const u8 = &.{},
    /// 默认值（原始 JSON 文本，写进模型 schema）
    default_json: ?[]const u8 = null,
    /// array 元素类型
    items: ?ValueType = null,
    min_items: ?usize = null,
    max_items: ?usize = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    /// 字符串最大 code point 数
    max_length: ?usize = null,
};

/// 一个工具的输入 schema。
pub const Spec = struct {
    fields: []const Field = &.{},

    pub fn field(self: Spec, name: []const u8) ?Field {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// 产出给模型看的 JSON Schema。
    pub fn writeModelSchema(self: Spec, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("type", "object");
        try e.key("properties");
        try e.beginObject();
        for (self.fields) |f| {
            try e.key(f.name);
            try e.beginObject();
            try e.stringField("type", f.type.wireName());
            if (f.description.len > 0) try e.stringField("description", f.description);
            if (f.enum_values.len > 0) {
                try e.key("enum");
                try e.beginArray();
                for (f.enum_values) |v| try e.string(v);
                try e.endArray();
            }
            if (f.default_json) |d| {
                try e.key("default");
                try e.raw(d);
            }
            if (f.items) |it| {
                try e.key("items");
                try e.beginObject();
                try e.stringField("type", it.wireName());
                try e.endObject();
            }
            if (f.min_items) |v| try e.intField("minItems", @intCast(v));
            if (f.max_items) |v| try e.intField("maxItems", @intCast(v));
            if (f.minimum) |v| {
                try e.key("minimum");
                try e.float(v);
            }
            if (f.maximum) |v| {
                try e.key("maximum");
                try e.float(v);
            }
            if (f.max_length) |v| try e.intField("maxLength", @intCast(v));
            try e.endObject();
        }
        try e.endObject();
        try e.key("required");
        try e.beginArray();
        for (self.fields) |f| {
            if (f.required) try e.string(f.name);
        }
        try e.endArray();
        try e.boolField("additionalProperties", false);
        try e.endObject();
    }

    pub fn modelSchemaAlloc(self: Spec, gpa: Allocator) ![]u8 {
        var e = json.Encoder.init(gpa);
        errdefer e.deinit();
        try self.writeModelSchema(&e);
        return e.toOwnedSlice();
    }

    /// 运行期校验（**与模型 schema 同源**）。返回 null = 通过。
    /// 错误信息是给人/模型看的一句话。
    pub fn validate(self: Spec, arena: Allocator, raw_input: []const u8) !?[]const u8 {
        const v = json.parse(arena, raw_input) catch |err| {
            return try std.fmt.allocPrint(arena, "input is not valid JSON ({s})", .{@errorName(err)});
        };
        if (v != .object) return "input must be a JSON object";

        for (self.fields) |f| {
            const fv = v.get(f.name);
            if (fv == null) {
                if (f.required) {
                    return try std.fmt.allocPrint(arena, "missing required field '{s}'", .{f.name});
                }
                continue;
            }
            const val = fv.?;
            if (try checkType(arena, f, val)) |msg| return msg;
        }
        return null;
    }

    fn checkType(arena: Allocator, f: Field, val: json.Value) !?[]const u8 {
        switch (f.type) {
            .string => {
                const s = val.asString() orelse
                    return try std.fmt.allocPrint(arena, "'{s}' must be a string", .{f.name});
                if (f.enum_values.len > 0) {
                    var found = false;
                    for (f.enum_values) |allowed| {
                        if (std.mem.eql(u8, allowed, s)) found = true;
                    }
                    if (!found) {
                        return try std.fmt.allocPrint(arena, "'{s}' must be one of the allowed values", .{f.name});
                    }
                }
                if (f.max_length) |mx| {
                    const n = @import("usage.zig").countCodePoints(s);
                    if (n > mx) {
                        return try std.fmt.allocPrint(arena, "'{s}' exceeds maxLength {d}", .{ f.name, mx });
                    }
                }
            },
            .integer, .number => {
                const n: f64 = switch (val) {
                    .integer => |i| @floatFromInt(i),
                    .number => |x| x,
                    else => return try std.fmt.allocPrint(arena, "'{s}' must be a number", .{f.name}),
                };
                if (f.minimum) |mn| {
                    if (n < mn) return try std.fmt.allocPrint(arena, "'{s}' below minimum", .{f.name});
                }
                if (f.maximum) |mx| {
                    if (n > mx) return try std.fmt.allocPrint(arena, "'{s}' above maximum", .{f.name});
                }
            },
            .boolean => {
                if (val != .boolean)
                    return try std.fmt.allocPrint(arena, "'{s}' must be a boolean", .{f.name});
            },
            .array => {
                const arr = switch (val) {
                    .array => |a| a,
                    else => return try std.fmt.allocPrint(arena, "'{s}' must be an array", .{f.name}),
                };
                if (f.min_items) |mn| {
                    if (arr.len < mn) return try std.fmt.allocPrint(arena, "'{s}' needs at least {d} items", .{ f.name, mn });
                }
                if (f.max_items) |mx| {
                    if (arr.len > mx) return try std.fmt.allocPrint(arena, "'{s}' allows at most {d} items", .{ f.name, mx });
                }
                if (f.items) |it| {
                    for (arr) |item| {
                        const sub = Field{ .name = f.name, .type = it };
                        if (try checkType(arena, sub, item)) |msg| return msg;
                    }
                }
            },
            .object => {
                if (val != .object)
                    return try std.fmt.allocPrint(arena, "'{s}' must be an object", .{f.name});
            },
        }
        return null;
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const sample = Spec{ .fields = &.{
    .{ .name = "file_path", .type = .string, .required = true, .description = "absolute path" },
    .{ .name = "offset", .type = .integer, .minimum = 0 },
    .{ .name = "mode", .type = .string, .enum_values = &.{ "a", "b" } },
    .{ .name = "tags", .type = .array, .items = .string, .max_items = 2 },
} };

test "schema: 模型 schema 与校验器同源" {
    const s = try sample.modelSchemaAlloc(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"required\":[\"file_path\"]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"maxItems\":2") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"enum\":[\"a\",\"b\"]") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try sample.validate(arena.allocator(), "{\"file_path\":\"/x\"}")) == null);
    const missing = try sample.validate(arena.allocator(), "{}");
    try testing.expect(missing != null);
    try testing.expect(std.mem.indexOf(u8, missing.?, "file_path") != null);
}

test "schema: 类型与枚举约束" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try sample.validate(a, "{\"file_path\":1}")) != null);
    try testing.expect((try sample.validate(a, "{\"file_path\":\"/x\",\"mode\":\"c\"}")) != null);
    try testing.expect((try sample.validate(a, "{\"file_path\":\"/x\",\"mode\":\"a\"}")) == null);
    try testing.expect((try sample.validate(a, "{\"file_path\":\"/x\",\"offset\":-1}")) != null);
    try testing.expect((try sample.validate(a, "{\"file_path\":\"/x\",\"tags\":[\"a\",\"b\",\"c\"]}")) != null);
    try testing.expect((try sample.validate(a, "{\"file_path\":\"/x\",\"tags\":[1]}")) != null);
}

test "schema: 非法 JSON 报错而不是 panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = try sample.validate(arena.allocator(), "{not json");
    try testing.expect(msg != null);
}

test "schema: 额外字段被接受（模型可能多发）但 schema 声明 additionalProperties=false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try sample.validate(arena.allocator(), "{\"file_path\":\"/x\",\"extra\":1}")) == null);
}
