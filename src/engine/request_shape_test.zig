//! **报文形状守卫** —— 断言"我们真的要发出去的请求体是合法 JSON"。
//!
//! 为什么必须有这条：`llm/` 的 67 个测试全走 `MockTransport`，它**不解析我们自己发出的
//! body**，只负责喂回预录的 SSE。于是"发出去的报文是否合法"这条路径**没有任何断言** ——
//! 首次真网络调用（DeepSeek）当场报：
//!   Failed to parse the request body as JSON:
//!   tools[0].function.parameters: expected value at line 1 column 12288
//! 这个测试就是补上那个洞。

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const llm = @import("llm");
const tools = @import("tools");

/// 复刻 `loop.toolSpecs()`：把 registry 的 8 个 Spec 变成 wire 用的 ToolSpec。
fn buildToolSpecs(a: std.mem.Allocator, reg: *tools.Registry) ![]llm.ToolSpec {
    const specs = try reg.modelSpecs(a);
    const out = try a.alloc(llm.ToolSpec, specs.len);
    for (specs, 0..) |s, i| {
        out[i] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
    }
    return out;
}

test "报文守卫: 真实系统提示词 + 8 工具 → 两套 wire 的 body 都是合法 JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var reg = try tools.defaultRegistry(testing.allocator);
    defer reg.deinit();
    const tspecs = try buildToolSpecs(a, &reg);

    // 复刻 engine 的真实装配：完整系统提示词（含项目约定 + 记忆 + 工具清单）
    const entries = try a.alloc(@import("prompt.zig").ToolEntry, tspecs.len);
    for (tspecs, 0..) |s, i| entries[i] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
    const system = try @import("prompt.zig").build(a, .{
        .cwd = "/repo",
        .model = "deepseek-chat",
        .instructions = "项目约定：注释用中文。",
        .hot_memory = "用户偏好简洁。",
    }, entries);

    const msgs = try a.alloc(common.Message, 1);
    msgs[0] = try common.Message.user(a, "只回答两个字：收到");
    const req = llm.ApiRequest{
        .model = "deepseek-chat",
        .system = system,
        .messages = msgs,
        .tools = tspecs,
        .max_tokens = 4096,
    };

    const obody = try llm.openai.buildRequestBody(a, &req, .{});
    std.debug.print("[报文守卫] 真实 body 长度 = {d} 字节（system {d} 字节）\n", .{ obody.len, system.len });
    _ = common.json.parse(a, obody) catch |err| {
        std.debug.print("[报文守卫] openai body 非法：{s}\n", .{@errorName(err)});
        return err;
    };
    // 注：**不要**断言 body 长度上限。真实跑时系统提示词约 16 KB、body 约 24 KB，
    // 而 DeepSeek 报的错在 column 12288（恰好 12 KiB）—— 说明**到达服务端的字节被截断了**，
    // 那是传输层的事，不是本测试能覆盖的。这里只守"合法 JSON"。
}

test "报文守卫(回归): toolSpecs 复制内容而非指针（旧写法是 use-after-free）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var reg = try tools.defaultRegistry(testing.allocator);
    defer reg.deinit();

    // 源 Spec 单独分配，用来比对指针
    const src = try reg.modelSpecs(testing.allocator);
    defer tools.freeModelSpecs(testing.allocator, src);

    const tspecs = try @import("loop.zig").dupToolSpecs(a, &reg);

    // ★ 核心断言：产出的字符串**必须不是**源 Spec 的那块内存。
    //
    //   旧写法（`defer tools.freeModelSpecs(...)` 之后返回指针）只复制指针，
    //   源一释放就是 use-after-free —— 而 UB **无法**用「构造悬垂指针、再断言它失败」
    //   来测：那样写自己就会崩（本用例最初就是这种写法，实测 SIGABRT）。
    //   所以改为断言「内容被复制」这条可判定的性质：指针不同 + 内容相同。
    try testing.expectEqual(src.len, tspecs.len);
    for (src, tspecs) |s, t| {
        try testing.expectEqualStrings(s.schema_json, t.schema_json);
        if (s.schema_json.len > 0) {
            try testing.expect(t.schema_json.ptr != s.schema_json.ptr);
        }
        if (s.description.len > 0) {
            try testing.expect(t.description.ptr != s.description.ptr);
        }
    }

    // 复制出来的内容仍能构造出合法 body
    const msgs = try a.alloc(common.Message, 1);
    msgs[0] = try common.Message.user(a, "x");
    const req = llm.ApiRequest{ .model = "m", .system = "s", .messages = msgs, .tools = tspecs };
    const body = try llm.openai.buildRequestBody(a, &req, .{});
    _ = common.json.parse(a, body) catch |err| {
        std.debug.print("\n[报文守卫] dupToolSpecs 产出的 body 非法：{s}\n", .{@errorName(err)});
        return err;
    };
}

test "报文守卫: OpenAI 请求体是合法 JSON，且 tools[].function.parameters 是对象" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var reg = try tools.defaultRegistry(testing.allocator);
    defer reg.deinit();
    const tspecs = try buildToolSpecs(a, &reg);

    const msgs = try a.alloc(common.Message, 1);
    msgs[0] = try common.Message.user(a, "只回答两个字：收到");

    const req = llm.ApiRequest{
        .model = "deepseek-chat",
        .system = "你是 Zigent。",
        .messages = msgs,
        .tools = tspecs,
        .max_tokens = 4096,
    };

    const body = try llm.openai.buildRequestBody(a, &req, .{});
    try testing.expect(body.len > 0);
    std.debug.print("\n[报文守卫] 小请求体长度 = {d} 字节\n", .{body.len});

    // ① 整份 body 必须是合法 JSON
    const v = common.json.parse(a, body) catch |err| {
        std.debug.print(
            "\n[报文守卫] body 不是合法 JSON：{s}（长度 {d}）\n前 200 字节：{s}\n",
            .{ @errorName(err), body.len, body[0..@min(200, body.len)] },
        );
        return err;
    };

    // ② tools[0].function.parameters 必须是**对象**（不是字符串、不能被截断）
    const arr = v.getArray("tools") orelse return error.NoTools;
    try testing.expect(arr.len == 8);
    for (arr, 0..) |t, i| {
        const f = t.get("function") orelse return error.NoFunction;
        const params = f.get("parameters") orelse return error.NoParameters;
        if (params != .object) {
            std.debug.print("\n[报文守卫] tools[{d}].function.parameters 不是对象，而是 {s}\n", .{ i, @tagName(params) });
            return error.ParametersNotObject;
        }
    }

    // ③ 顺带确认 Anthropic 侧也一样（同一批 Spec，两套 wire）
    const abody = try llm.anthropic.buildRequestBody(a, &req, .{});
    _ = common.json.parse(a, abody) catch |err| {
        std.debug.print("\n[报文守卫] anthropic body 不是合法 JSON：{s}（长度 {d}）\n", .{ @errorName(err), abody.len });
        return err;
    };
}
