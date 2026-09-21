//! `tools/specs.zig` —— **8 个工具的单一 schema 真源**（文档 03 §9 / 05 §3）。
//!
//! 为什么整份 `Spec` 集中在一个文件：历史上 schema 是**双轨**的（内部校验一份、
//! 给模型看的宣告一份），已经出过两次事故：
//!   - `Grep.head_limit` 文案写「Defaults to 250」，代码缺省实际是 100；
//!   - `TodoWrite` 的模型轨（`content`/`status`/`activeForm`）与内部轨
//!     （`id`/`content`/`status`/`priority`）字段集不同，导致「模型必填 / 校验不查」。
//! `common.schema.Spec` 同时生成**模型 JSON Schema** 与**运行期校验器**，
//! 结构上不可能分叉；本文件把它落成 8 份声明，工具实现只允许从这里取。
//!
//! ⚠️ 阈值常量（`GREP_DEFAULT_HEAD_LIMIT` 等）与描述文案在**编译期**绑定：
//!   描述由 `std.fmt.comptimePrint` 从同一个常量生成，「代码一个数、文案另一个数」
//!   这种事故在本文件里无法再表达出来。

const std = @import("std");
const common = @import("common");
const schema = common.schema;
const json = common.json;

// ─────────────────────────────────────────────────────────────────────────────
// 契约常量（单一真源；工具实现与 Spec 描述都从这里取）
// ─────────────────────────────────────────────────────────────────────────────

/// `Read` 缺省读取行数（文档 05 §4.1 `DEFAULT_LIMIT`）。
pub const READ_DEFAULT_LIMIT: usize = 2000;
/// `Read` 单文件读入上限（防超大文件进内存）。
pub const READ_MAX_BYTES: usize = 16 << 20;

/// `Bash` 缺省超时（文档 05 §4.4 B1）。
pub const BASH_DEFAULT_TIMEOUT_MS: u64 = 120_000;
/// `Bash` 超时上限。
pub const BASH_MAX_TIMEOUT_MS: u64 = 600_000;

/// `Glob` 结果条数上限（文档 05 §4.5 G1）。
pub const GLOB_MAX_RESULTS: usize = 1000;
/// `Glob` 结果上限（模型上下文保护）。
pub const GLOB_MAX_RESULT_CHARS: usize = 65_536;

/// `Grep` 缺省结果上限（文档 05 §4.6 P2 `DEFAULT_MAX_RESULTS`）。
pub const GREP_DEFAULT_MAX_RESULTS: usize = 100;
/// ★ `Grep.head_limit` 缺省值 —— **代码与模型文案共用这一个数**（事故现场修复点）。
pub const GREP_DEFAULT_HEAD_LIMIT: usize = 100;
/// `Grep`/`Bash` 结果上限（模型上下文保护）。
pub const SEARCH_MAX_RESULT_CHARS: usize = 50_000;

/// 工具结果落盘 backstop（code point 口径，见 `truncate.zig`）。
pub const ABSOLUTE_MAX_RESULT_CHARS: usize = common.ToolResult.MAX_TOOL_RESULT_CHARS;

// ─────────────────────────────────────────────────────────────────────────────
// 1. Read
// ─────────────────────────────────────────────────────────────────────────────

pub const read_spec = schema.Spec{ .fields = &.{
    .{ .name = "file_path", .type = .string, .required = true, .description = "The absolute path to the file to read" },
    .{ .name = "offset", .type = .integer, .minimum = 0, .description = "The line number to start reading from. Only provide if the file is too large to read at once" },
    .{ .name = "limit", .type = .integer, .minimum = 1, .description = "The number of lines to read. Only provide if the file is too large to read at once." },
    .{ .name = "pages", .type = .string, .description = "Page range for PDF files (e.g., \"1-5\", \"3\", \"10-20\"). Only applicable to PDF files. Maximum 20 pages per request." },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 2. Write
// ─────────────────────────────────────────────────────────────────────────────

pub const write_spec = schema.Spec{ .fields = &.{
    .{ .name = "file_path", .type = .string, .required = true, .description = "The absolute path to the file to write (must be absolute, not relative)" },
    .{ .name = "content", .type = .string, .required = true, .description = "The content to write to the file" },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 3. Edit
// ─────────────────────────────────────────────────────────────────────────────

/// ⚠️ doc 05 §4.3 的裁决：`replace_all` 在模型轨进 `required`（strict 对象只排除
/// `.optional`，`default(false)` 是非 optional）。Zig 用 `Field.required = true`
/// **单点**决定模型 required 与校验器行为，两轨不再分叉。
pub const edit_spec = schema.Spec{ .fields = &.{
    .{ .name = "file_path", .type = .string, .required = true, .description = "The absolute path to the file to modify" },
    .{ .name = "old_string", .type = .string, .required = true, .description = "The text to replace" },
    .{ .name = "new_string", .type = .string, .required = true, .description = "The text to replace it with (must be different from old_string)" },
    .{ .name = "replace_all", .type = .boolean, .required = true, .default_json = "false", .description = "Replace all occurrences of old_string (default false)" },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 4. Bash
// ─────────────────────────────────────────────────────────────────────────────

pub const bash_spec = schema.Spec{ .fields = &.{
    .{ .name = "command", .type = .string, .required = true, .description = "The command to execute" },
    .{ .name = "timeout", .type = .integer, .minimum = 1, .maximum = @floatFromInt(BASH_MAX_TIMEOUT_MS), .description = "Optional timeout in milliseconds (max 600000)" },
    .{ .name = "description", .type = .string, .description = "Clear, concise description of what this command does in active voice." },
    .{ .name = "run_in_background", .type = .boolean, .description = "Set to true to run this command in the background. Use Read to read the output later." },
    .{ .name = "dangerouslyDisableSandbox", .type = .boolean, .description = "Set this to true to dangerously override sandbox mode and run commands without sandboxing." },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 5. Glob
// ─────────────────────────────────────────────────────────────────────────────

pub const glob_spec = schema.Spec{ .fields = &.{
    .{ .name = "pattern", .type = .string, .required = true, .description = "The glob pattern to match files against" },
    .{ .name = "path", .type = .string, .description = "The directory to search in. If not specified, the current working directory will be used." },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 6. Grep（14 个暴露字段）
// ─────────────────────────────────────────────────────────────────────────────

/// 描述里内嵌缺省值 —— 与 `GREP_DEFAULT_HEAD_LIMIT` 编译期同源（修复 250/100 漂移）。
const grep_head_limit_desc = std.fmt.comptimePrint(
    "Limit output to first N lines/entries. Defaults to {d} when unspecified.",
    .{GREP_DEFAULT_HEAD_LIMIT},
);

pub const grep_spec = schema.Spec{ .fields = &.{
    .{ .name = "pattern", .type = .string, .required = true, .description = "The regular expression pattern to search for in file contents" },
    .{ .name = "path", .type = .string, .description = "File or directory to search in (rg PATH). Defaults to current working directory." },
    .{ .name = "glob", .type = .string, .description = "Glob pattern to filter files (e.g. \"*.js\", \"*.{ts,tsx}\") - maps to rg --glob" },
    .{ .name = "output_mode", .type = .string, .enum_values = &.{ "content", "files_with_matches", "count" }, .description = "Output mode: \"content\" shows matching lines, \"files_with_matches\" shows only file paths, \"count\" shows match counts. Defaults to \"content\"." },
    .{ .name = "-B", .type = .integer, .minimum = 0, .description = "Number of lines to show before each match (rg -B). Requires output_mode: \"content\", ignored otherwise." },
    .{ .name = "-A", .type = .integer, .minimum = 0, .description = "Number of lines to show after each match (rg -A). Requires output_mode: \"content\", ignored otherwise." },
    .{ .name = "-C", .type = .integer, .minimum = 0, .description = "Alias for context." },
    .{ .name = "context", .type = .integer, .minimum = 0, .description = "Number of lines to show before and after each match (rg -C). Requires output_mode: \"content\", ignored otherwise." },
    .{ .name = "-n", .type = .boolean, .description = "Show line numbers in output (rg -n). Defaults to true." },
    .{ .name = "-i", .type = .boolean, .description = "Case insensitive search (rg -i)" },
    .{ .name = "type", .type = .string, .description = "File type to search (rg --type). Common types: js, py, rust, go, java, etc." },
    .{ .name = "head_limit", .type = .integer, .minimum = 1, .default_json = std.fmt.comptimePrint("{d}", .{GREP_DEFAULT_HEAD_LIMIT}), .description = grep_head_limit_desc },
    .{ .name = "offset", .type = .integer, .minimum = 0, .default_json = "0", .description = "Skip first N lines/entries before applying head_limit. Defaults to 0." },
    .{ .name = "multiline", .type = .boolean, .default_json = "false", .description = "Enable multiline mode where . matches newlines and patterns can span lines (rg -U --multiline-dotall). Default: false." },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 7. TodoWrite
// ─────────────────────────────────────────────────────────────────────────────

pub const todo_item_spec = schema.Spec{ .fields = &.{
    .{ .name = "content", .type = .string, .required = true, .description = "A brief title for the task" },
    .{ .name = "status", .type = .string, .required = true, .enum_values = &.{ "pending", "in_progress", "completed" }, .description = "Task status" },
    .{ .name = "activeForm", .type = .string, .required = true, .description = "Present continuous form shown in spinner" },
} };

pub const todo_spec = schema.Spec{ .fields = &.{
    .{ .name = "todos", .type = .array, .required = true, .items = .object, .description = "The updated todo list" },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 8. ask_user_question（单轨；`anyOf` 无法用 `Field` 表达，改由 execute 显式 XOR 检查）
// ─────────────────────────────────────────────────────────────────────────────

pub const ask_spec = schema.Spec{ .fields = &.{
    .{ .name = "question", .type = .string, .description = "The complete question to ask the user" },
    .{ .name = "questions", .type = .array, .items = .object, .description = "The complete questions to ask the user (batch)" },
    .{ .name = "header", .type = .string, .description = "Short label displayed as a chip/tag (max 12 chars)" },
    .{ .name = "options", .type = .array, .items = .object, .description = "Options for the single question" },
    .{ .name = "multiSelect", .type = .boolean, .description = "Allow selecting multiple options (default false)" },
} };

// ─────────────────────────────────────────────────────────────────────────────
// 对**已解析**的 JSON 值做同源字段校验（用于 `TodoWrite` 的数组元素）
// ─────────────────────────────────────────────────────────────────────────────

/// 与 `Spec.validate` 同一套字段表，但作用在已经解析出来的 `json.Value` 上
/// （`Spec.validate` 只吃原始文本；Todo 的嵌套 item 拿不到逐元素 raw 切片，
/// 又不能 parse→re-serialize）。返回 null = 通过。
pub fn validateValue(arena: std.mem.Allocator, spec: schema.Spec, v: json.Value) !?[]const u8 {
    if (v != .object) return "item must be a JSON object";
    for (spec.fields) |f| {
        const fv = v.get(f.name) orelse {
            if (f.required) {
                return try std.fmt.allocPrint(arena, "missing required field '{s}'", .{f.name});
            }
            continue;
        };
        switch (f.type) {
            .string => {
                const s = fv.asString() orelse
                    return try std.fmt.allocPrint(arena, "'{s}' must be a string", .{f.name});
                if (f.enum_values.len > 0) {
                    var found = false;
                    for (f.enum_values) |allowed| {
                        if (std.mem.eql(u8, allowed, s)) found = true;
                    }
                    if (!found) return try std.fmt.allocPrint(arena, "Invalid status: {s}", .{s});
                }
                if (f.max_length) |mx| {
                    if (common.usage.countCodePoints(s) > mx) {
                        return try std.fmt.allocPrint(arena, "'{s}' exceeds maxLength {d}", .{ f.name, mx });
                    }
                }
            },
            .integer, .number => {
                const ok = switch (fv) {
                    .integer, .number => true,
                    else => false,
                };
                if (!ok) return try std.fmt.allocPrint(arena, "'{s}' must be a number", .{f.name});
            },
            .boolean => if (fv != .boolean)
                return try std.fmt.allocPrint(arena, "'{s}' must be a boolean", .{f.name}),
            .array => if (fv != .array)
                return try std.fmt.allocPrint(arena, "'{s}' must be an array", .{f.name}),
            .object => if (fv != .object)
                return try std.fmt.allocPrint(arena, "'{s}' must be an object", .{f.name}),
        }
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn validateOk(spec: schema.Spec, raw: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return (try spec.validate(arena.allocator(), raw)) == null;
}

fn schemaParses(spec: schema.Spec) !void {
    const s = try spec.modelSchemaAlloc(testing.allocator);
    defer testing.allocator.free(s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try json.parse(arena.allocator(), s);
    try testing.expect(std.mem.indexOf(u8, s, "\"type\":\"object\"") != null);
}

test "specs: 8 个工具的模型 schema 都是合法 JSON" {
    try schemaParses(read_spec);
    try schemaParses(write_spec);
    try schemaParses(edit_spec);
    try schemaParses(bash_spec);
    try schemaParses(glob_spec);
    try schemaParses(grep_spec);
    try schemaParses(todo_spec);
    try schemaParses(ask_spec);
}

test "specs: Read 接受好输入、拒绝坏输入" {
    try testing.expect(try validateOk(read_spec, "{\"file_path\":\"/x\"}"));
    try testing.expect(try validateOk(read_spec, "{\"file_path\":\"/x\",\"offset\":3,\"limit\":10}"));
    try testing.expect(!try validateOk(read_spec, "{}"));
    try testing.expect(!try validateOk(read_spec, "{\"file_path\":1}"));
    try testing.expect(!try validateOk(read_spec, "{\"file_path\":\"/x\",\"offset\":-1}"));
    try testing.expect(!try validateOk(read_spec, "not json"));
}

test "specs: Write 接受好输入、拒绝坏输入" {
    try testing.expect(try validateOk(write_spec, "{\"file_path\":\"/x\",\"content\":\"hi\"}"));
    try testing.expect(!try validateOk(write_spec, "{\"file_path\":\"/x\"}"));
    try testing.expect(!try validateOk(write_spec, "{\"content\":\"hi\"}"));
}

test "specs: Edit 的 replace_all 由 Field.required 单点决定（模型必填）" {
    try testing.expect(try validateOk(edit_spec, "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":false}"));
    try testing.expect(!try validateOk(edit_spec, "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\"}"));
    const js = try edit_spec.modelSchemaAlloc(testing.allocator);
    defer testing.allocator.free(js);
    try testing.expect(std.mem.indexOf(u8, js, "\"replace_all\"") != null);
    try testing.expect(std.mem.indexOf(u8, js, "\"required\":[\"file_path\",\"old_string\",\"new_string\",\"replace_all\"]") != null);
}

test "specs: Bash 只 required=command，timeout 上限 600000" {
    try testing.expect(try validateOk(bash_spec, "{\"command\":\"ls\"}"));
    try testing.expect(!try validateOk(bash_spec, "{}"));
    try testing.expect(!try validateOk(bash_spec, "{\"command\":\"ls\",\"timeout\":700000}"));
    try testing.expect(try validateOk(bash_spec, "{\"command\":\"ls\",\"timeout\":600000}"));
    const js = try bash_spec.modelSchemaAlloc(testing.allocator);
    defer testing.allocator.free(js);
    try testing.expect(std.mem.indexOf(u8, js, "\"required\":[\"command\"]") != null);
}

test "specs: Glob 接受 path 可选" {
    try testing.expect(try validateOk(glob_spec, "{\"pattern\":\"*.zig\"}"));
    try testing.expect(try validateOk(glob_spec, "{\"pattern\":\"*.zig\",\"path\":\"/tmp\"}"));
    try testing.expect(!try validateOk(glob_spec, "{}"));
    try testing.expect(!try validateOk(glob_spec, "{\"pattern\":5}"));
}

test "specs: Grep 恰好 14 个暴露字段且 output_mode 枚举受约束" {
    try testing.expectEqual(@as(usize, 14), grep_spec.fields.len);
    try testing.expect(try validateOk(grep_spec, "{\"pattern\":\"a\"}"));
    try testing.expect(try validateOk(grep_spec, "{\"pattern\":\"a\",\"-i\":true,\"head_limit\":5}"));
    try testing.expect(!try validateOk(grep_spec, "{}"));
    try testing.expect(!try validateOk(grep_spec, "{\"pattern\":\"a\",\"output_mode\":\"nope\"}"));
}

test "specs: ★ head_limit 代码缺省值与 Spec 描述里的数字逐字一致（250/100 事故修复）" {
    const f = grep_spec.field("head_limit").?;
    const expected = try std.fmt.allocPrint(testing.allocator, "Defaults to {d} when unspecified.", .{GREP_DEFAULT_HEAD_LIMIT});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, f.description, expected) != null);
    // 反向：描述里不许出现别的数字式 "Defaults to N when unspecified"
    try testing.expect(std.mem.indexOf(u8, f.description, "Defaults to 250") == null);
    // 模型 schema 的 default 也是同一个数
    const js = try grep_spec.modelSchemaAlloc(testing.allocator);
    defer testing.allocator.free(js);
    const expected_default = try std.fmt.allocPrint(testing.allocator, "\"default\":{d}", .{GREP_DEFAULT_HEAD_LIMIT});
    defer testing.allocator.free(expected_default);
    try testing.expect(std.mem.indexOf(u8, js, expected_default) != null);
}

test "specs: TodoWrite 顶层数组受校验，item 轨由 validateValue 校验" {
    try testing.expect(try validateOk(todo_spec, "{\"todos\":[]}"));
    try testing.expect(try validateOk(todo_spec, "{\"todos\":[{\"content\":\"a\",\"status\":\"pending\",\"activeForm\":\"doing a\"}]}"));
    try testing.expect(!try validateOk(todo_spec, "{}"));
    try testing.expect(!try validateOk(todo_spec, "{\"todos\":\"nope\"}"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try json.parse(a, "{\"content\":\"a\",\"status\":\"in_progress\",\"activeForm\":\"x\"}");
    try testing.expect((try validateValue(a, todo_item_spec, good)) == null);
    const bad_status = try json.parse(a, "{\"content\":\"a\",\"status\":\"nope\",\"activeForm\":\"x\"}");
    const msg = try validateValue(a, todo_item_spec, bad_status);
    try testing.expect(msg != null);
    try testing.expect(std.mem.indexOf(u8, msg.?, "Invalid status") != null);
    const missing = try json.parse(a, "{\"content\":\"a\"}");
    try testing.expect((try validateValue(a, todo_item_spec, missing)) != null);
}

test "specs: ask_user_question 只拒绝类型错误（XOR 在 execute 里）" {
    try testing.expect(try validateOk(ask_spec, "{\"question\":\"q\",\"options\":[]}"));
    try testing.expect(try validateOk(ask_spec, "{\"questions\":[]}"));
    try testing.expect(!try validateOk(ask_spec, "{\"question\":5}"));
    try testing.expect(!try validateOk(ask_spec, "{\"questions\":\"nope\"}"));
}

test "specs: 结果上限三档（Bash/Grep 50000、Glob 65536、其余 400000）" {
    try testing.expectEqual(@as(usize, 50_000), SEARCH_MAX_RESULT_CHARS);
    try testing.expectEqual(@as(usize, 65_536), GLOB_MAX_RESULT_CHARS);
    try testing.expectEqual(@as(usize, 400_000), ABSOLUTE_MAX_RESULT_CHARS);
}
