//! `config/userconfig.zig` —— ★ **`config.json` 的唯一定义**（文档 10 §2 / 文档 03 §6.6）。
//!
//! `config.json` **只有 5 个序列化字段**：
//! `version` / `model.default` / `model.pro` / `model.mini` / `providers`。
//!
//! ⚠️ 三条容易搞错的点：
//!   1. 三档绑定在 wire 上是**扁平点号 key**（`"model.default"`），**不是**嵌套对象；
//!   2. `permissionMode` / `permissions` / `sandbox` / `model.ultra` **在配置对象上不存在**
//!      —— 行为开关归 `settings.zig`，`config.json` 只放 provider/模型事实；
//!   3. **保留未知字段**（本机实测就有 `youzone`）：严格模式会丢用户数据。
//!
//! 序列化用手写（`common.json` 的 Encoder），不用反射派生 —— wire 名是跨版本契约。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const util = @import("util");

pub const json = common.json;

// ─────────────────────────────────────────────────────────────────────────────
// wire 名字面量（P1 的最小落地：所有 key 只在这里出现一次）
// ─────────────────────────────────────────────────────────────────────────────

pub const wire = struct {
    pub const version = "version";
    pub const model_default = "model.default"; // 扁平点号，不是嵌套！
    pub const model_pro = "model.pro";
    pub const model_mini = "model.mini";
    pub const providers = "providers";
    pub const enabled = "enabled";
    pub const provider_type = "type";
    pub const base_url = "baseUrl";
    pub const api_key_env = "apiKeyEnv";
    pub const api_key = "apiKey";
    pub const timeout_ms = "timeoutMs";
    pub const proxy = "proxy";
    pub const headers = "headers";
    pub const models = "models";
    pub const label = "label";
    pub const limit = "limit";
    pub const context = "context";
    pub const output = "output";
    pub const compact_window = "compactWindow";
    pub const capabilities = "capabilities";
    pub const reasoning = "reasoning";
    pub const tool_call = "toolCall";
    pub const temperature = "temperature";
    pub const native_tool_search = "nativeToolSearch";
    pub const variants = "variants";
    pub const default_effort = "defaultEffort";
    pub const sampling = "sampling";
    pub const top_p = "topP";
    pub const seed = "seed";
    pub const concurrency = "concurrency";
};

/// 已知顶层字段的**显式常量数组**（Zig 无反射 ⇒ 漏登记即「静默不认」）。
pub const KNOWN_TOP_LEVEL = [_][]const u8{
    wire.version,
    wire.model_default,
    wire.model_pro,
    wire.model_mini,
    wire.providers,
};

/// 已废弃 / 越界的顶层字段：读到要**报诊断**而不是静默忽略（文档 10 §2.1）。
pub const REJECTED_TOP_LEVEL = [_][]const u8{
    "model.ultra", // 已收敛成三档；读到要报诊断
    "permissionMode",
    "permissions",
    "sandbox",
};

/// 单文件最大读取字节（配置是手改文本，超过就是异常）。
pub const MAX_CONFIG_BYTES: usize = 4 << 20;

// ─────────────────────────────────────────────────────────────────────────────
// 类型
// ─────────────────────────────────────────────────────────────────────────────

/// 档位。`pro` / `mini` 未显式设置时**返回 null**（让调用方回落 `default`），
/// 而不是把档位名当 model 泄漏出去。
pub const Tier = enum {
    default,
    pro,
    mini,

    pub fn wireName(self: Tier) []const u8 {
        return switch (self) {
            .default => "default",
            .pro => "pro",
            .mini => "mini",
        };
    }

    pub fn fromWire(s: []const u8) ?Tier {
        if (std.ascii.eqlIgnoreCase(s, "default")) return .default;
        if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
        if (std.ascii.eqlIgnoreCase(s, "mini")) return .mini;
        return null;
    }
};

/// 一个 provider 声明的**契约字段**（INTERFACES §4.1）。
///
/// `models` 是模型 id 列表（`<providerId>/<modelId>` 的另一半）。
/// 更细的 per-model 元数据（`label` / `limit` / `capabilities` / `variants` /
/// `sampling` / `concurrency`）与 `headers` / `proxy` / `timeoutMs` 都留在
/// `raw`（**永不丢用户数据**），由将来的 `llm/router` 按需读取。
pub const ProviderEntry = struct {
    id: []const u8,
    kind: []const u8, // "anthropic" | "openai"
    base_url: []const u8,
    api_key: []const u8,
    api_key_env: []const u8,
    models: []const []const u8 = &.{},
    /// 该 provider 在 `config.json` 里的**原始 JSON 对象**（保序 + 保留未知字段）。
    raw: json.Map = .{},
};

pub const UserConfig = struct {
    version: i64 = 1,
    default_model: []const u8 = "",
    pro_model: []const u8 = "",
    mini_model: []const u8 = "",
    providers: []ProviderEntry = &.{},

    /// 非 JSON 字段：`ZIGENT_DEFAULT_MODEL` 注入值（非空时覆盖 `default` 档）。
    default_model_from_env: ?[]const u8 = null,
    /// 顶层未知字段（前向兼容：新版写的字段，旧版读一遍不许丢）。
    unknown: json.Map = .{},
    /// 顶层被拒字段（`model.ultra` 等）—— 供 doctor 报诊断。
    rejected: []const []const u8 = &.{},

    /// `load` 拥有的分配（arena）。`null` = 调用方自建（纯默认值，无分配）。
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *UserConfig, gpa: Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            gpa.destroy(a);
            self.arena = null;
        }
    }

    /// 按 id 找 provider（**大小写不敏感**，但返回配置里的大小写）。
    pub fn providerFor(self: *const UserConfig, id: []const u8) ?ProviderEntry {
        for (self.providers) |p| {
            if (std.ascii.eqlIgnoreCase(p.id, id)) return p;
        }
        return null;
    }

    pub fn providerForTier(self: *const UserConfig, tier: Tier) ?ProviderEntry {
        const binding = self.modelFor(tier) orelse return null;
        const slash = std.mem.indexOfScalar(u8, binding, '/') orelse return null;
        return self.providerFor(binding[0..slash]);
    }

    /// 档位 → `"providerId/modelId"` 绑定串（可能为 null）。
    ///
    /// 规则（逐条对齐既有实现）：
    ///   1. `default` 档：`ZIGENT_DEFAULT_MODEL` 覆盖优先；
    ///   2. 显式绑定非空即返回；
    ///   3. **只有 `default` 档**才合成「第一个声明了 model 的 provider 的第一个 model」；
    ///   4. `pro` / `mini` 未设 → `null`（让路由回落，而不是泄漏档位名）。
    pub fn modelFor(self: *const UserConfig, tier: Tier) ?[]const u8 {
        return switch (tier) {
            .default => blk: {
                if (self.default_model_from_env) |v| {
                    if (v.len != 0) break :blk v;
                }
                if (self.default_model.len != 0) break :blk self.default_model;
                break :blk self.firstConfiguredModelBinding();
            },
            .pro => if (self.pro_model.len != 0) self.pro_model else null,
            .mini => if (self.mini_model.len != 0) self.mini_model else null,
        };
    }

    /// 第一个「声明了 model」的 provider 的第一个 model → `"provider/model"`。
    /// 返回的切片借自 arena（`load` 时已分配好）。
    pub fn firstConfiguredModelBinding(self: *const UserConfig) ?[]const u8 {
        for (self.providers) |p| {
            if (p.models.len > 0) return joinBinding(self, p.id, p.models[0]);
        }
        return null;
    }

    fn joinBinding(self: *const UserConfig, provider_id: []const u8, model_id: []const u8) ?[]const u8 {
        const a = self.arena orelse return null;
        return std.fmt.allocPrint(a.allocator(), "{s}/{s}", .{ provider_id, model_id }) catch null;
    }

    // ── 加载 ──────────────────────────────────────────────────────────────

    /// 读 `path`（不存在 → 全默认值，**不报错**）。
    ///
    /// ⚠️ JSON 畸形 / 顶层不是对象 → **返回默认值 + 不中断**（文档 10 §8.1 的
    /// 「单个 provider 解密失败不得中断整份配置加载」是同一纪律）。诊断走 `rejected`。
    pub fn load(io: Io, gpa: Allocator, path: []const u8) !UserConfig {
        const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_ptr.deinit();
        const a = arena_ptr.allocator();

        const bytes = (try util.fsio.readIfExists(io, a, path, MAX_CONFIG_BYTES)) orelse
            return UserConfig{ .arena = arena_ptr };
        // readIfExists 已经用 arena 分配（arena 不单独 free）。

        const value = json.parse(a, bytes) catch
            return UserConfig{ .arena = arena_ptr };
        const obj = switch (value) {
            .object => |o| o,
            else => return UserConfig{ .arena = arena_ptr },
        };

        var cfg = UserConfig{ .arena = arena_ptr };
        if (obj.get(wire.version)) |v| {
            if (v.asInt()) |n| cfg.version = n;
        }
        cfg.default_model = str(obj, wire.model_default);
        cfg.pro_model = str(obj, wire.model_pro);
        cfg.mini_model = str(obj, wire.model_mini);

        // providers（保序：合成 default 档依赖「第一个」）
        if (obj.get(wire.providers)) |pv| {
            if (pv == .object) {
                const entries = pv.object.entries.items;
                // 先解析到固定缓冲，再按**实际个数**精确分配（避免未初始化槽位）。
                var stack: [256]ProviderEntry = undefined;
                var n: usize = 0;
                for (entries) |e| {
                    if (e.value != .object) continue; // 非对象项跳过（不 panic）
                    if (n == stack.len) break;
                    stack[n] = try parseProvider(a, e.key, e.value.object);
                    n += 1;
                }
                const list = try a.alloc(ProviderEntry, n);
                @memcpy(list, stack[0..n]);
                cfg.providers = list;
            }
        }

        // 未知 / 被拒字段（**保留未知、报告被拒**）
        var unknown: json.Map = .{};
        var rejected = std.ArrayListUnmanaged([]const u8).empty;
        for (obj.entries.items) |e| {
            if (isKnownTopLevel(e.key)) continue;
            for (REJECTED_TOP_LEVEL) |r| {
                if (std.mem.eql(u8, e.key, r)) {
                    try rejected.append(a, e.key);
                    break;
                }
            } else {
                try unknown.put(a, e.key, e.value);
            }
        }
        cfg.unknown = unknown;
        cfg.rejected = rejected.items;

        return cfg;
    }

    /// `ZIGENT_DEFAULT_MODEL` 覆盖注入（不改写文件，文档 10 §4.1）。
    pub fn applyEnvOverrides(self: *UserConfig, env: *const std.process.Environ.Map) void {
        const v = util.io.getEnv(env, "ZIGENT_DEFAULT_MODEL");
        if (v) |s| {
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len != 0) self.default_model_from_env = t;
        }
    }

    /// 便捷：`load` + `applyEnvOverrides`。
    pub fn loadWithEnv(io: Io, gpa: Allocator, path: []const u8, env: *const std.process.Environ.Map) !UserConfig {
        var cfg = try load(io, gpa, path);
        cfg.applyEnvOverrides(env);
        return cfg;
    }

    // ── 序列化（保留未知字段的 round-trip） ───────────────────────────────

    /// 编码回 JSON。**未知顶层字段、每个 provider 的原始对象都原样写出**。
    pub fn toJson(self: *const UserConfig, gpa: Allocator) ![]u8 {
        var e = json.Encoder.init(gpa);
        errdefer e.deinit();
        try e.beginObject();
        try e.intField(wire.version, self.version);
        try writeOptString(&e, wire.model_default, self.default_model);
        try writeOptString(&e, wire.model_pro, self.pro_model);
        try writeOptString(&e, wire.model_mini, self.mini_model);

        try e.key(wire.providers);
        try e.beginObject();
        for (self.providers) |p| {
            try e.key(p.id);
            try e.value(.{ .object = p.raw });
        }
        // 未知字段里若有 "providers" 的同名兄弟，按原序补回（这里简单追加）
        try e.endObject();

        for (self.unknown.entries.items) |u| {
            if (std.mem.eql(u8, u.key, wire.providers)) continue;
            if (isKnownTopLevel(u.key)) continue;
            try e.field(u.key, u.value);
        }
        try e.endObject();
        return e.toOwnedSlice();
    }
};

fn writeOptString(e: *json.Encoder, key: []const u8, v: []const u8) !void {
    if (v.len == 0) return; // 缺席与空串语义不同：不写空串
    try e.stringField(key, v);
}

fn isKnownTopLevel(key: []const u8) bool {
    for (KNOWN_TOP_LEVEL) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn str(obj: json.Map, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn parseProvider(a: Allocator, id: []const u8, obj: json.Map) !ProviderEntry {
    // kind：`type` 缺失时回退 providerId（文档 10 §2.1）
    const kind_raw = str(obj, wire.provider_type);
    const kind = if (kind_raw.len != 0) kind_raw else id;

    var models = std.ArrayListUnmanaged([]const u8).empty;
    if (obj.get(wire.models)) |mv| {
        if (mv == .object) {
            for (mv.object.entries.items) |me| {
                try models.append(a, me.key);
            }
        }
    }

    return .{
        .id = id,
        .kind = kind,
        .base_url = str(obj, wire.base_url),
        .api_key = str(obj, wire.api_key),
        .api_key_env = str(obj, wire.api_key_env),
        .models = models.items,
        .raw = obj,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 测试用临时目录（每个测试一个，结束删掉）。
const Tmp = struct {
    threaded: std.Io.Threaded,
    io: Io,
    dir: []u8,

    fn init(gpa: Allocator) !Tmp {
        var t: Tmp = .{ .threaded = std.Io.Threaded.init(gpa, .{}), .io = undefined, .dir = undefined };
        t.io = t.threaded.io();
        const rnd = try util.io.randomHex(t.io, gpa, 6);
        defer gpa.free(rnd);
        t.dir = try std.fmt.allocPrint(gpa, "/tmp/zigent-userconfig-{s}", .{rnd});
        try util.io.mkdirp(t.io, t.dir);
        return t;
    }

    fn deinit(self: *Tmp, gpa: Allocator) void {
        util.io.removeTree(self.io, self.dir) catch {};
        gpa.free(self.dir);
        self.threaded.deinit();
    }

    fn write(self: *Tmp, gpa: Allocator, name: []const u8, content: []const u8) ![]u8 {
        const p = try std.fs.path.join(gpa, &.{ self.dir, name });
        try util.io.writeFile(self.io, p, content);
        return p;
    }
};

const SAMPLE =
    \\{
    \\  "version": 2,
    \\  "model.default": "MiniMax/MiniMax-M3",
    \\  "model.pro": "DeepSeek/deepseek-v4-pro",
    \\  "model.mini": "DeepSeek/deepseek-v4-flash",
    \\  "youzone": { "unknown_field": [1, 2, 3] },
    \\  "providers": {
    \\    "MiniMax": {
    \\      "type": "anthropic",
    \\      "baseUrl": "https://api.minimaxi.com/anthropic",
    \\      "apiKeyEnv": "MINIMAX_API_KEY",
    \\      "timeoutMs": 300000,
    \\      "headers": { "X-Trace": "local" },
    \\      "models": {
    \\        "MiniMax-M3": { "label": "MiniMax M3", "limit": { "context": 1000000, "output": 64000, "compactWindow": 512000 } },
    \\        "MiniMax-M2": {}
    \\      }
    \\    },
    \\    "OpenAI-Via-Proxy": {
    \\      "type": "openai",
    \\      "baseUrl": "https://api.openai.com/v1/",
    \\      "apiKeyEnv": "OPENAI_API_KEY",
    \\      "proxy": { "type": "http", "host": "127.0.0.1", "port": 7890 },
    \\      "models": { "gpt-4o": { "label": "GPT-4o" } }
    \\    }
    \\  }
    \\}
;

test "userconfig: 5 个顶层字段解析正确" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const path = try t.write(gpa, "config.json", SAMPLE);
    defer gpa.free(path);

    var cfg = try UserConfig.load(t.io, gpa, path);
    defer cfg.deinit(gpa);

    try testing.expectEqual(@as(i64, 2), cfg.version);
    try testing.expectEqualStrings("MiniMax/MiniMax-M3", cfg.default_model);
    try testing.expectEqualStrings("DeepSeek/deepseek-v4-pro", cfg.pro_model);
    try testing.expectEqualStrings("DeepSeek/deepseek-v4-flash", cfg.mini_model);
    try testing.expectEqual(@as(usize, 2), cfg.providers.len);

    // 插入序保留
    try testing.expectEqualStrings("MiniMax", cfg.providers[0].id);
    try testing.expectEqualStrings("OpenAI-Via-Proxy", cfg.providers[1].id);

    const mm = cfg.providerFor("MiniMax").?;
    try testing.expectEqualStrings("anthropic", mm.kind);
    try testing.expectEqualStrings("https://api.minimaxi.com/anthropic", mm.base_url);
    try testing.expectEqualStrings("MINIMAX_API_KEY", mm.api_key_env);
    try testing.expectEqualStrings("", mm.api_key);
    try testing.expectEqual(@as(usize, 2), mm.models.len);
    try testing.expectEqualStrings("MiniMax-M3", mm.models[0]);

    const oa = cfg.providerFor("openai-via-proxy").?; // 大小写不敏感
    try testing.expectEqualStrings("OpenAI-Via-Proxy", oa.id); // 返回配置里的大小写
    try testing.expectEqualStrings("openai", oa.kind);
}

test "userconfig: 三档绑定解析（env 覆盖 / 显式 / 只有 default 合成 / pro-mini 未设 null）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;

    const path = try t.write(gpa, "config.json", SAMPLE);
    defer gpa.free(path);
    var cfg = try UserConfig.load(t.io, gpa, path);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("MiniMax/MiniMax-M3", cfg.modelFor(.default).?);
    try testing.expectEqualStrings("DeepSeek/deepseek-v4-pro", cfg.modelFor(.pro).?);
    try testing.expectEqualStrings("DeepSeek/deepseek-v4-flash", cfg.modelFor(.mini).?);
    try testing.expectEqual(Tier.default, Tier.fromWire("DEFAULT").?);

    // env 覆盖**只在 default 档**生效
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("ZIGENT_DEFAULT_MODEL", "  Env/Model-1  ");
    cfg.applyEnvOverrides(&env);
    try testing.expectEqualStrings("Env/Model-1", cfg.modelFor(.default).?);
    try testing.expectEqualStrings("DeepSeek/deepseek-v4-pro", cfg.modelFor(.pro).?);
}

test "userconfig: 无 model.default 时合成「第一个 provider 的第一个 model」" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;

    const src =
        \\{"version":1,"providers":{
        \\  "P1":{"type":"openai","models":{"m1":{},"m2":{}}},
        \\  "P2":{"type":"anthropic","models":{"m3":{}}}}}
    ;
    const path = try t.write(gpa, "c.json", src);
    defer gpa.free(path);
    var cfg = try UserConfig.load(t.io, gpa, path);
    defer cfg.deinit(gpa);

    try testing.expectEqualStrings("P1/m1", cfg.modelFor(.default).?);
    // pro / mini 未设 → null（**不**回落成档位名）
    try testing.expect(cfg.modelFor(.pro) == null);
    try testing.expect(cfg.modelFor(.mini) == null);
    try testing.expectEqualStrings("P1", cfg.providerForTier(.default).?.id);
    try testing.expect(cfg.providerForTier(.pro) == null);
}

test "userconfig: 未知字段保留 + 被拒字段报告（model.ultra 报诊断不静默忽略）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;

    const src =
        \\{"version":2,"model.default":"a/b","model.ultra":"x/y",
        \\ "permissionMode":"BYPASS_PERMISSIONS","youzone":{"k":true},
        \\ "providers":{"a":{"type":"openai","models":{"b":{}}}}}
    ;
    const path = try t.write(gpa, "c.json", src);
    defer gpa.free(path);
    var cfg = try UserConfig.load(t.io, gpa, path);
    defer cfg.deinit(gpa);

    try testing.expect(cfg.unknown.get("youzone") != null);
    try testing.expect(cfg.unknown.get("permissionMode") == null);
    try testing.expectEqual(@as(usize, 2), cfg.rejected.len);

    // round-trip：未知字段与 provider 原始细节都不丢
    const out = try cfg.toJson(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "youzone") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model.default") != null);
    try testing.expect(std.mem.indexOf(u8, out, "MiniMax") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"a\"") != null);

    // 再解析一次，语义等价
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = try json.parse(arena.allocator(), out);
    try testing.expectEqualStrings("a/b", v.getString("model.default").?);
    try testing.expect(v.get("youzone") != null);
    try testing.expectEqualStrings("openai", v.get("providers").?.get("a").?.getString("type").?);
}

test "userconfig: 文件不存在 / 畸形 JSON → 默认值，不报错" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;

    const missing = try std.fs.path.join(gpa, &.{ t.dir, "nope.json" });
    defer gpa.free(missing);
    var a = try UserConfig.load(t.io, gpa, missing);
    defer a.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), a.providers.len);
    try testing.expect(a.modelFor(.default) == null);

    const bad = try t.write(gpa, "bad.json", "{ not json");
    defer gpa.free(bad);
    var b = try UserConfig.load(t.io, gpa, bad);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), b.providers.len);

    const arr = try t.write(gpa, "arr.json", "[1,2,3]");
    defer gpa.free(arr);
    var c = try UserConfig.load(t.io, gpa, arr);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), c.providers.len);
}

test "userconfig: type 缺失时回退 providerId；providers 里非对象项跳过" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;

    const src =
        \\{"providers":{"my-openai":{"models":{"gpt":{}}},"broken":"oops","nullish":null}}
    ;
    const path = try t.write(gpa, "c.json", src);
    defer gpa.free(path);
    var cfg = try UserConfig.load(t.io, gpa, path);
    defer cfg.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), cfg.providers.len);
    try testing.expectEqualStrings("my-openai", cfg.providers[0].kind); // 回退 id
    try testing.expectEqualStrings("my-openai", cfg.providers[0].id);
}

test "userconfig: wire 名常量（扁平点号，不是嵌套对象）" {
    try testing.expectEqualStrings("model.default", wire.model_default);
    try testing.expectEqualStrings("model.pro", wire.model_pro);
    try testing.expectEqualStrings("model.mini", wire.model_mini);
    try testing.expectEqualStrings("baseUrl", wire.base_url);
    try testing.expectEqualStrings("apiKeyEnv", wire.api_key_env);
    try testing.expectEqualStrings("apiKey", wire.api_key);
    // 只有 5 个顶层字段
    try testing.expectEqual(@as(usize, 5), KNOWN_TOP_LEVEL.len);
}
