//! `config/settings.zig` —— 分层设置合并 + **内容 SHA-256 指纹**（文档 10 §3）。
//!
//! ## 层序（低 → 高，INTERFACES §4.1）
//!
//! ```
//! 内置默认 < ~/.zigent/settings.json        (user)
//!          < <cwd>/.agents/settings.json     (project)
//!          < <cwd>/.agents/settings.local.json (local)
//!          < ~/.zigent/settings.managed.json (managed)
//!          < ~/.zigent/settings.policy.json  (policy)
//!          < 环境变量覆盖                      (env)
//! ```
//!
//! ## 合并语义（文档 10 §3.2）
//!
//! - 同名对象 → **递归深合并**；
//! - 标量与数组 → **整体替换**（没有拼接、没有去重）；
//! - **未知字段一律保留**（`raw` 里原样带出）—— 不许丢用户数据。
//!
//! ## 失效判定（文档 10 §3.3，P2）
//!
//! `fingerprint` = **合并后内容的 SHA-256**（小写 hex），**不是 mtime、不是 size**。
//! `touch` 不触发重载、同秒等长改写**会**触发 —— `Snapshot.changedFrom` 是唯一判据。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const util = @import("util");
const paths_mod = @import("paths.zig");
const userconfig = @import("userconfig.zig");

pub const json = common.json;
pub const Paths = paths_mod.Paths;

/// 单层文件最大字节（手改文本，超过即异常）。
pub const MAX_SETTINGS_BYTES: usize = 8 << 20;

/// 合并层名（文档 10 §3.1 的层名收敛）。
pub const Source = enum {
    builtin,
    keys,
    user,
    project,
    local,
    managed,
    policy,
    env,

    pub fn wireName(self: Source) []const u8 {
        return switch (self) {
            .builtin => "builtin",
            .keys => "keys",
            .user => "user",
            .project => "project",
            .local => "local",
            .managed => "managed",
            .policy => "policy",
            .env => "environment",
        };
    }
};

/// 环境变量覆盖（Zig 侧新增，设计文档 §3.1 的「CLI flags 最终胜出」之前的收口点）。
///
/// ⚠️ 每条都**只覆盖对应的标量**，不写回 `raw` —— 保证「raw = 磁盘上的合并结果」。
/// `AGENT_AUTOCOMPACT_BUFFER_TOKENS` 一类**不在本模块**（属压缩逻辑，不是设置层）。
pub const env_overrides = struct {
    pub const permission_mode = "ZIGENT_PERMISSION_MODE";
    pub const model = "ZIGENT_MODEL";
    pub const provider = "ZIGENT_PROVIDER";
    pub const max_turns = "ZIGENT_MAX_TURNS";
    pub const max_tokens = "ZIGENT_MAX_TOKENS";
    pub const temperature = "ZIGENT_TEMPERATURE";
    pub const effort = "ZIGENT_EFFORT";
};

/// 一个层的读取结果（文档 10 §3.3 的 `Layer`）。
pub const Layer = struct {
    source: Source,
    /// `null` = 内存层（env / builtin）。
    path: ?[]const u8 = null,
    /// 已解析的原始对象（借用自读取用 arena）。
    values: json.Map = .{},
    /// **该文件字节**的 SHA-256 小写 hex（内存层为 null）。
    fingerprint: ?[]const u8 = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Settings
// ─────────────────────────────────────────────────────────────────────────────

pub const Settings = struct {
    permission_mode: common.perm.Mode = .ask,
    model: []const u8 = "",
    provider: []const u8 = "",
    max_turns: u32 = 200,
    temperature: ?f64 = null,
    max_tokens: i64 = 16384,
    effort: []const u8 = "standard",
    /// 分层合并后的**内容 SHA-256**（失效判据用哈希，**不用 mtime**）。
    fingerprint: []const u8 = "",
    raw: json.Map = .{},

    /// 本次加载拥有的 arena（装载字符串字段 / fingerprint / layers 数组）。
    ///
    /// ⚠️ **不要拷贝 `Settings` 值**：拷贝会让两个实例共享同一个 arena 指针，
    /// `deinit` 就会双重释放。请传递 `*const Settings`（契约就是这么用的）。
    arena: ?*std.heap.ArenaAllocator = null,
    /// 参与合并的层（低 → 高），供 doctor 输出 provenance。
    layers: []const Layer = &.{},

    pub fn deinit(self: *Settings, gpa: Allocator) void {
        // 结构 buffer（entries / array）是 **gpa** 分配的：必须递归释放。
        freeMapStorage(gpa, &self.raw);
        self.raw = .{};
        for (self.layers) |layer| freeMapStorage(gpa, @constCast(&layer.values));
        self.layers = &.{};
        // 字符串与层快照结构随 arena 一起释放。
        if (self.arena) |a| {
            a.deinit();
            gpa.destroy(a);
            self.arena = null;
        }
    }

    /// 读一个合并后的**顶层**键（点号路径不展开 —— 嵌套由调用方自己走 `Value.get`）。
    ///
    /// ⚠️ 返回 `?json.Value` 是 INTERFACES §4.1 的契约。`"contextWindow"` /
    /// `"appendSystemPrompt"` 这类**标量键**直接取字符串即可用 `getString`。
    pub fn get(self: *const Settings, key: []const u8) ?json.Value {
        return self.raw.get(key);
    }

    /// 便捷：把顶层键当字符串读（非字符串类型返回 `null`）。
    /// 便于 `settings.getString("appendSystemPrompt") orelse ""` 这类调用点。
    pub fn getString(self: *const Settings, key: []const u8) ?[]const u8 {
        const v = self.raw.get(key) orelse return null;
        return v.asString();
    }

    /// 便捷：把顶层键当整数读（`number` 也接受）。
    pub fn getInt(self: *const Settings, key: []const u8) ?i64 {
        const v = self.raw.get(key) orelse return null;
        return v.asInt();
    }

    // ── 加载 ──────────────────────────────────────────────────────────────

    /// 按 INTERFACES §4.1 的分层顺序合并。
    ///
    /// 单层读取失败（畸形 JSON / 不是对象）→ **跳过该层并继续**（不中断整份加载），
    /// 与「单个 provider 解密失败不中断配置加载」同一纪律。
    pub fn load(
        io: Io,
        gpa: Allocator,
        p: *const Paths,
        env: *const std.process.Environ.Map,
    ) !Settings {
        const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_ptr.deinit();
        const a = arena_ptr.allocator();

        var merged: json.Map = .{};
        var layers = std.ArrayListUnmanaged(Layer).empty;
        var layer_arena = std.heap.ArenaAllocator.init(gpa);
        defer layer_arena.deinit();

        // ① 用户层
        try readLayer(io, &layer_arena, &merged, a, gpa, .user, try p.userSettingsFile(a), &layers);
        // ② 项目层（execution cwd）
        try readLayer(io, &layer_arena, &merged, a, gpa, .project, try p.projectSettingsFile(a), &layers);
        // ③ 本地层（workspace root）
        try readLayer(io, &layer_arena, &merged, a, gpa, .local, try p.localSettingsFile(a), &layers);
        // ④ 托管层
        try readLayer(io, &layer_arena, &merged, a, gpa, .managed, try p.managedSettingsFile(a), &layers);
        // ⑤ 策略层（最高非 env）
        try readLayer(io, &layer_arena, &merged, a, gpa, .policy, try p.policySettingsFile(a), &layers);

        // ⑥ 环境变量覆盖（只覆盖标量，不写回 raw）
        const env_map = try envOverrides(env, gpa, a);
        if (env_map.count() > 0) {
            try mergeMap(&merged, env_map, gpa, a);
            try layers.append(a, .{ .source = .env, .values = env_map });
        }

        var self = Settings{
            .raw = merged,
            .arena = arena_ptr,
            .layers = layers.items,
        };
        self.applyFromRaw();
        try self.computeFingerprint(a);
        return self;
    }

    /// `config.json` 的 **keys 层**（文档 10 §3.1）：只抽 `model.default`（设置 `model`）。
    ///
    /// ⚠️ 该层**不是全量**：`permissionMode` / `permissions` / `sandbox` **不进**
    /// settings（那是旧文档的说法，实测不存在）。本函数只做 `model.default → "default"`。
    pub fn applyKeysLayer(self: *Settings, cfg: *const userconfig.UserConfig) void {
        if (cfg.default_model.len != 0 or cfg.default_model_from_env != null) {
            // 档位名（**不是**具体模型）—— 交给路由解析
            self.model = "default";
        }
    }

    fn applyFromRaw(self: *Settings) void {
        if (mapString(self.raw, &.{ "permissionMode", "permission_mode" })) |raw| {
            self.permission_mode = common.perm.Mode.fromWire(raw) orelse self.permission_mode;
        }
        if (mapString(self.raw, &.{ "model" })) |v| {
            if (v.len != 0) self.model = v;
        }
        if (mapString(self.raw, &.{ "provider" })) |v| {
            if (v.len != 0) self.provider = v;
        }
        if (mapInt(self.raw, &.{ "maxTurns", "max_turns" })) |n| {
            if (n > 0 and n <= std.math.maxInt(u32)) self.max_turns = @intCast(n);
        }
        if (getFirst(self.raw, &.{ "temperature" })) |v| {
            switch (v) {
                .number => |f| self.temperature = f,
                .integer => |i| self.temperature = @floatFromInt(i),
                else => {},
            }
        }
        if (mapInt(self.raw, &.{ "maxTokens", "max_tokens" })) |n| {
            self.max_tokens = n;
        }
        if (mapString(self.raw, &.{ "effort" })) |v| {
            if (v.len != 0) self.effort = v;
        }
    }

    /// ★ 失效判定唯一入口：**合并后内容**的 SHA-256（小写 hex）。
    fn computeFingerprint(self: *Settings, a: Allocator) !void {
        var digest: [32]u8 = undefined;
        const enc = try canonicalJson(a, self.raw);
        std.crypto.hash.sha2.Sha256.hash(enc, &digest, .{});
        self.fingerprint = try a.dupe(u8, &sha256Hex(digest));
    }
};

fn getFirst(m: json.Map, keys: []const []const u8) ?json.Value {
    for (keys) |k| {
        if (m.get(k)) |v| return v;
    }
    return null;
}

fn mapString(m: json.Map, keys: []const []const u8) ?[]const u8 {
    const v = getFirst(m, keys) orelse return null;
    return v.asString();
}

fn mapInt(m: json.Map, keys: []const []const u8) ?i64 {
    const v = getFirst(m, keys) orelse return null;
    return v.asInt();
}

/// 读一层：不存在 / 空文件 → **不进层列表**（provenance 不撒谎）。
fn readLayer(
    io: Io,
    layer_arena: *std.heap.ArenaAllocator,
    target: *json.Map,
    dest: Allocator,
    gpa: Allocator,
    source: Source,
    path: []const u8,
    layers: *std.ArrayListUnmanaged(Layer),
) !void {
    const la = layer_arena.allocator();
    const bytes = util.io.readFileAlloc(io, la, path, MAX_SETTINGS_BYTES) catch |e| switch (e) {
        error.FileNotFound => return,
        error.AccessDenied => return, // 权限问题不该让内核起不来
        else => return e,
    };
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const fp = try la.dupe(u8, &sha256Hex(digest));

    const value = json.parse(la, bytes) catch return; // 畸形 → 跳过本层
    if (value != .object) return;
    if (value.object.count() == 0) return;

    try mergeMap(target, value.object, gpa, dest);
    try layers.append(dest, .{
        .source = source,
        .path = try dest.dupe(u8, path),
        // 层快照：**结构用 gpa**（稳定），字符串用 `dest`（Settings.arena）。
        .values = try cloneMap(gpa, value.object, dest),
        .fingerprint = fp,
    });
}

/// 环境变量覆盖：只产出「被显式设置且非空白」的那些键。
/// 键与结构用 `gpa`（与其它 map 一致，可释放），值字符串用 `arena`。
fn envOverrides(env: *const std.process.Environ.Map, gpa: Allocator, arena: Allocator) Allocator.Error!json.Map {
    var m: json.Map = .{};
    try applyEnvKey(&m, gpa, arena, env, env_overrides.permission_mode, "permissionMode");
    try applyEnvKey(&m, gpa, arena, env, env_overrides.model, "model");
    try applyEnvKey(&m, gpa, arena, env, env_overrides.provider, "provider");
    try applyEnvKey(&m, gpa, arena, env, env_overrides.max_turns, "maxTurns");
    try applyEnvKey(&m, gpa, arena, env, env_overrides.max_tokens, "maxTokens");
    try applyEnvKey(&m, gpa, arena, env, env_overrides.temperature, "temperature");
    try applyEnvKey(&m, gpa, arena, env, env_overrides.effort, "effort");
    return m;
}

fn applyEnvKey(
    m: *json.Map,
    gpa: Allocator,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    env_name: []const u8,
    wire_name: []const u8,
) Allocator.Error!void {
    const raw = util.io.getEnv(env, env_name) orelse return;
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0) return;
    const value = switch (envValueFor(env_name, v)) {
        .string => |str| json.Value{ .string = try arena.dupe(u8, str) },
        else => |other| other,
    };
    try m.put(gpa, try arena.dupe(u8, wire_name), value);
}

fn envValueFor(key: []const u8, v: []const u8) json.Value {
    if (std.mem.eql(u8, key, env_overrides.max_turns) or
        std.mem.eql(u8, key, env_overrides.max_tokens))
    {
        const n = std.fmt.parseInt(i64, v, 10) catch return .{ .string = v };
        return .{ .integer = n };
    }
    if (std.mem.eql(u8, key, env_overrides.temperature)) {
        const f = std.fmt.parseFloat(f64, v) catch return .{ .string = v };
        return .{ .number = f };
    }
    return .{ .string = v };
}

// ─────────────────────────────────────────────────────────────────────────────
// 合并（深合并 + 整体替换）
// ─────────────────────────────────────────────────────────────────────────────

/// `src` 合并进 `target`（**原地**）：同名对象递归，其余整体替换（深拷贝）。
///
/// ⚠️ **内存模型（两个踩过的坑，别改回去）**：
///   1. `Map.entries` 的**存储必须来自不会移动的分配器（`gpa`）**：
///      `get()` 会长期借用内层 map 的 entries 切片，若它指向 arena 的 buffer，
///      后续 arena 增长会把它搬走 → 读嵌套对象时 **segfault**。
///   2. 替换一个值之前必须 **release 掉旧值**：数组 buffer 是 gpa 分配的，
///      不释放就是一条真泄漏（`deinit` 只释放「当前还在树上的」那些）。
/// 字符串一律放 `arena`（不动，且随 `Settings.arena` 一次性释放）。
pub fn mergeMap(target: *json.Map, src: json.Map, gpa: Allocator, arena: Allocator) Allocator.Error!void {
    // 第一遍：两边都是对象的同名键 → 就地深合并（不改变 target 的 entries）。
    for (target.entries.items) |*te| {
        const sv = src.get(te.key) orelse continue;
        if (te.value == .object and sv == .object) {
            try mergeMap(&te.value.object, sv.object, gpa, arena);
        }
    }
    // 第二遍：新键 / 非对象键 → 替换（**先释放旧值**）。
    for (src.entries.items) |e| {
        for (target.entries.items) |*te| {
            if (!std.mem.eql(u8, te.key, e.key)) continue;
            if (te.value == .object and e.value == .object) break; // 已合并
            releaseValue(gpa, te.value);
            te.value = try cloneValue(e.value, gpa, arena);
            break;
        } else {
            try target.put(gpa, try arena.dupe(u8, e.key), try cloneValue(e.value, gpa, arena));
        }
    }
}

/// 深拷贝一个 JSON 值：**存储结构用 `gpa`**（稳定），**字符串用 `arena`**。
pub fn cloneValue(v: json.Value, gpa: Allocator, arena: Allocator) Allocator.Error!json.Value {
    return switch (v) {
        .null => .null,
        .boolean => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .number => |f| .{ .number = f },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |arr| blk: {
            const out = try gpa.alloc(json.Value, arr.len);
            for (arr, 0..) |item, i| out[i] = try cloneValue(item, gpa, arena);
            break :blk .{ .array = out };
        },
        .object => |o| .{ .object = try cloneMap(gpa, o, arena) },
    };
}

pub fn cloneMap(gpa: Allocator, src: json.Map, arena: Allocator) Allocator.Error!json.Map {
    var out: json.Map = .{};
    try out.entries.ensureTotalCapacity(gpa, src.count());
    for (src.entries.items) |e| {
        out.entries.appendAssumeCapacity(.{
            .key = try arena.dupe(u8, e.key),
            .value = try cloneValue(e.value, gpa, arena),
        });
    }
    return out;
}

/// 释放一个值的**结构存储**（`Value.array` / `Map.entries` 及其子孙）。
/// 不碰字符串 —— 字符串归 `Settings.arena`。
pub fn releaseValue(gpa: Allocator, v: json.Value) void {
    switch (v) {
        .array => |arr| {
            for (arr) |item| releaseValue(gpa, item);
            gpa.free(arr);
        },
        .object => |o| {
            var m = o;
            freeMapStorage(gpa, &m);
        },
        else => {},
    }
}

pub fn freeMapStorage(gpa: Allocator, m: *json.Map) void {
    for (m.entries.items) |e| releaseValue(gpa, e.value);
    m.entries.deinit(gpa);
    m.entries = .empty;
}

/// **规范化 JSON**：顶层键按字典序排序后编码。
///
/// 为什么不能直接 `json.stringify`：`Object` 保持插入顺序，
/// 而「同一份逻辑内容、不同书写顺序」的两个文件应当有**同一个指纹**
/// （否则用户重排字段就会触发一次无意义的重合并）。
/// 值的内部顺序（嵌套对象）保持原样 —— 那属于内容本身。
pub fn canonicalJson(gpa: Allocator, obj: json.Map) Allocator.Error![]u8 {
    const keys = try gpa.alloc([]const u8, obj.entries.items.len);
    defer gpa.free(keys);
    for (obj.entries.items, 0..) |e, i| keys[i] = e.key;
    std.mem.sort([]const u8, keys, {}, lessThanStr);

    var e = json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    for (keys) |k| {
        try e.field(k, obj.get(k).?);
    }
    try e.endObject();
    return e.toOwnedSlice();
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// SHA-256 摘要 → 64 字符小写 hex（指纹的**唯一**表示）。
fn sha256Hex(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

// ─────────────────────────────────────────────────────────────────────────────
// 指纹快照（热重载的唯一判据）
// ─────────────────────────────────────────────────────────────────────────────

/// 一次加载的**不可变快照**：绝对路径 → 内容指纹。
///
/// `changedFrom` 是 `touch` / 同秒改写 / 编辑器 atomic-rename 的**统一答案**。
pub const Snapshot = struct {
    /// 路径 → 64 字符小写 hex（`null` = 文件当前不存在）。
    entries: []Entry = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub const Entry = struct {
        path: []const u8,
        fingerprint: ?[]const u8,
    };

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            gpa.destroy(a);
            self.arena = null;
        }
    }

    /// 读全部 settings 候选路径的内容指纹。
    pub fn capture(io: Io, gpa: Allocator, p: *const Paths) !Snapshot {
        const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_ptr.deinit();
        const a = arena_ptr.allocator();

        const candidates = try p.settingsCandidatePaths(a);
        const out = try a.alloc(Entry, candidates.len);
        for (candidates, 0..) |path, i| {
            out[i] = .{ .path = path, .fingerprint = try contentFingerprint(io, a, path) };
        }
        return .{ .entries = out, .arena = arena_ptr };
    }

    /// **有任何指纹变化（含新增 / 删除层）即需要重跑合并。**
    ///
    /// ⚠️ 「文件不存在」也是一种**状态**（指纹 `null`），不是「找不到条目」——
    /// 两者必须区分，否则任何缺失层都会让比对恒为「变了」。
    pub fn changedFrom(self: *const Snapshot, other: *const Snapshot) bool {
        if (self.entries.len != other.entries.len) return true;
        outer: for (self.entries) |mine| {
            for (other.entries) |theirs| {
                if (!std.mem.eql(u8, mine.path, theirs.path)) continue;
                if (optEql(mine.fingerprint, theirs.fingerprint)) continue :outer;
                return true;
            }
            return true; // 对方没有这条路径 → 层集合变了
        }
        return false;
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// 单个路径的内容指纹（`null` = 文件不存在 / 不可读）。
/// ★ 读 bytes → SHA-256 → 小写 hex；**不用 mtime、不用 size**。
pub fn contentFingerprint(io: Io, gpa: Allocator, path: []const u8) !?[]const u8 {
    const bytes = util.io.readFileAlloc(io, gpa, path, MAX_SETTINGS_BYTES) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.AccessDenied => return null,
        else => return e,
    };
    defer gpa.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = try gpa.dupe(u8, &sha256Hex(digest));
    return hex;
}

/// 与 `Settings.load` 同一份候选路径顺序 —— 供热重载比对。
pub fn layerCandidatePaths(p: *const Paths, gpa: Allocator) ![][]u8 {
    return p.settingsCandidatePaths(gpa);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Tmp = struct {
    threaded: std.Io.Threaded,
    io: Io,
    dir: []u8,

    fn init(gpa: Allocator) !Tmp {
        var t: Tmp = .{ .threaded = std.Io.Threaded.init(gpa, .{}), .io = undefined, .dir = undefined };
        t.io = t.threaded.io();
        const rnd = try util.io.randomHex(t.io, gpa, 6);
        defer gpa.free(rnd);
        t.dir = try std.fmt.allocPrint(gpa, "/tmp/zigent-settings-{s}", .{rnd});
        try util.io.mkdirp(t.io, t.dir);
        return t;
    }

    fn deinit(self: *Tmp, gpa: Allocator) void {
        util.io.removeTree(self.io, self.dir) catch {};
        gpa.free(self.dir);
        self.threaded.deinit();
    }

    /// 建 `<dir>/home/.zigent` 与 `<dir>/repo/.agents` 两棵树并返回 Paths。
    fn paths(self: *Tmp, gpa: Allocator) !Paths {
        const home = try std.fs.path.join(gpa, &.{ self.dir, "home" });
        defer gpa.free(home);
        const repo = try std.fs.path.join(gpa, &.{ self.dir, "repo" });
        defer gpa.free(repo);
        try util.io.mkdirp(self.io, home);
        try util.io.mkdirp(self.io, repo);
        return Paths{
            .home = try gpa.dupe(u8, home),
            .cwd = try gpa.dupe(u8, repo),
        };
    }

    fn writeUser(self: *Tmp, gpa: Allocator, p: Paths, content: []const u8) !void {
        const f = try p.userSettingsFile(gpa);
        defer gpa.free(f);
        try util.io.mkdirp(self.io, std.fs.path.dirname(f).?);
        try util.io.writeFile(self.io, f, content);
    }

    fn writeProject(self: *Tmp, gpa: Allocator, p: Paths, name: []const u8, content: []const u8) !void {
        const wd = try p.workspaceDir(gpa);
        defer gpa.free(wd);
        try util.io.mkdirp(self.io, wd);
        const f = try std.fs.path.join(gpa, &.{ wd, name });
        defer gpa.free(f);
        try util.io.writeFile(self.io, f, content);
    }
};

test "settings: 内置默认值（无任何文件）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }

    const env = std.process.Environ.Map.init(gpa);
    var s = try Settings.load(t.io, gpa, &p, &env);
    defer s.deinit(gpa);

    try testing.expectEqual(common.perm.Mode.ask, s.permission_mode);
    try testing.expectEqualStrings("", s.model);
    try testing.expectEqualStrings("", s.provider);
    try testing.expectEqual(@as(u32, 200), s.max_turns);
    try testing.expect(s.temperature == null);
    try testing.expectEqual(@as(i64, 16384), s.max_tokens);
    try testing.expectEqualStrings("standard", s.effort);
    try testing.expectEqual(@as(usize, 0), s.layers.len);
    try testing.expectEqual(@as(usize, 64), s.fingerprint.len);
}

test "settings: 分层优先级（user < project < local < managed < policy）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }
    const env = std.process.Environ.Map.init(gpa);

    try t.writeUser(gpa, p, "{\"model\":\"user-model\",\"maxTurns\":10,\"permissionMode\":\"ASK\"}");
    try t.writeProject(gpa, p, "settings.json", "{\"model\":\"project-model\",\"maxTurns\":20}");
    try t.writeProject(gpa, p, "settings.local.json", "{\"model\":\"local-model\"}");

    const managed = try p.managedSettingsFile(gpa);
    defer gpa.free(managed);
    try util.io.writeFile(t.io, managed, "{\"model\":\"managed-model\"}");

    // 还没有 policy 层
    var s1 = try Settings.load(t.io, gpa, &p, &env);
    defer s1.deinit(gpa);
    try testing.expectEqualStrings("managed-model", s1.model);
    try testing.expectEqual(@as(u32, 20), s1.max_turns);
    try testing.expectEqual(common.perm.Mode.ask, s1.permission_mode);
    try testing.expectEqual(@as(usize, 4), s1.layers.len);
    try testing.expectEqual(Source.user, s1.layers[0].source);
    try testing.expectEqual(Source.policy, Source.policy); // 枚举可达

    // 加 policy 层 → 胜出
    const policy = try p.policySettingsFile(gpa);
    defer gpa.free(policy);
    try util.io.writeFile(t.io, policy, "{\"model\":\"policy-model\"}");
    var s2 = try Settings.load(t.io, gpa, &p, &env);
    defer s2.deinit(gpa);
    try testing.expectEqualStrings("policy-model", s2.model);
    try testing.expectEqual(@as(usize, 5), s2.layers.len);
    try testing.expectEqual(Source.policy, s2.layers[4].source);
}

test "settings: 深合并 vs 整体替换（数组不拼接）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }
    const env = std.process.Environ.Map.init(gpa);

    try t.writeUser(gpa, p,
        \\{"nested":{"a":1,"b":2},"list":[1,2,3],"model":"user","keep":"yes"}
    );
    try t.writeProject(gpa, p, "settings.json",
        \\{"nested":{"b":20,"c":30},"list":[9],"provider":"proj"}
    );

    var s = try Settings.load(t.io, gpa, &p, &env);
    defer s.deinit(gpa);

    const nested = s.get("nested").?;
    try testing.expectEqual(@as(i64, 1), nested.getInt("a").?); // 低层保留
    try testing.expectEqual(@as(i64, 20), nested.getInt("b").?); // 高层覆盖
    try testing.expectEqual(@as(i64, 30), nested.getInt("c").?); // 高层新增

    // 数组**整体替换**（不是合并成 [1,2,3,9]）
    const list = s.get("list").?.array;
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(i64, 9), list[0].asInt().?);

    // 未知字段保留
    try testing.expectEqualStrings("yes", s.get("keep").?.asString().?);
    try testing.expectEqualStrings("proj", s.provider);
    try testing.expectEqualStrings("user", s.model);
}

test "settings: permissionMode 解析四种模式 + 未知值不改默认" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }
    const env = std.process.Environ.Map.init(gpa);

    try t.writeUser(gpa, p, "{\"permissionMode\":\"ACCEPT_EDITS\"}");
    var a = try Settings.load(t.io, gpa, &p, &env);
    defer a.deinit(gpa);
    try testing.expectEqual(common.perm.Mode.accept_edits, a.permission_mode);

    try t.writeUser(gpa, p, "{\"permissionMode\":\"plan\"}");
    var b = try Settings.load(t.io, gpa, &p, &env);
    defer b.deinit(gpa);
    try testing.expectEqual(common.perm.Mode.plan, b.permission_mode);

    try t.writeUser(gpa, p, "{\"permissionMode\":\"BOGUS\"}");
    var c = try Settings.load(t.io, gpa, &p, &env);
    defer c.deinit(gpa);
    try testing.expectEqual(common.perm.Mode.ask, c.permission_mode);
}

test "settings: 环境变量覆盖（CLI 之前的收口点）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }

    try t.writeUser(gpa, p, "{\"model\":\"file-model\",\"maxTurns\":10,\"maxTokens\":100,\"effort\":\"fast\",\"temperature\":0.5}");

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(env_overrides.model, "env-model");
    try env.put(env_overrides.max_turns, "42");
    try env.put(env_overrides.max_tokens, "999");
    try env.put(env_overrides.temperature, "0.9");
    try env.put(env_overrides.effort, "deep");
    try env.put(env_overrides.provider, "env-provider");
    try env.put(env_overrides.permission_mode, "BYPASS_PERMISSIONS");

    var s = try Settings.load(t.io, gpa, &p, &env);
    defer s.deinit(gpa);
    try testing.expectEqualStrings("env-model", s.model);
    try testing.expectEqual(@as(u32, 42), s.max_turns);
    try testing.expectEqual(@as(i64, 999), s.max_tokens);
    try testing.expectEqual(@as(f64, 0.9), s.temperature.?);
    try testing.expectEqualStrings("deep", s.effort);
    try testing.expectEqualStrings("env-provider", s.provider);
    try testing.expectEqual(common.perm.Mode.bypass_permissions, s.permission_mode);
    // env 层出现在层列表尾部
    try testing.expectEqual(Source.env, s.layers[s.layers.len - 1].source);
    // env 覆盖是**层**（参与指纹），因此合并结果里就是 env 值
    try testing.expectEqualStrings("env-model", s.get("model").?.asString().?);
}

test "settings: 畸形层被跳过而不是中断整份加载" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }
    const env = std.process.Environ.Map.init(gpa);

    try t.writeUser(gpa, p, "{\"model\":\"ok-model\"}");
    try t.writeProject(gpa, p, "settings.json", "{ this is not json");
    try t.writeProject(gpa, p, "settings.local.json", "[1,2,3]");

    var s = try Settings.load(t.io, gpa, &p, &env);
    defer s.deinit(gpa);
    try testing.expectEqualStrings("ok-model", s.model);
    try testing.expectEqual(@as(usize, 1), s.layers.len); // 只有 user 层进了 provenance

    // 空对象层也不算「进了层」（provenance 不撒谎）
    try t.writeUser(gpa, p, "{}");
    var s2 = try Settings.load(t.io, gpa, &p, &env);
    defer s2.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), s2.layers.len);
}

test "settings: 指纹 = 合并后内容的 SHA-256（不是 mtime）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }
    const env = std.process.Environ.Map.init(gpa);

    try t.writeUser(gpa, p, "{\"model\":\"m\",\"maxTurns\":5}");
    var s1 = try Settings.load(t.io, gpa, &p, &env);
    defer s1.deinit(gpa);
    try testing.expectEqual(@as(usize, 64), s1.fingerprint.len);

    // ① 内容不变（只 touch）→ 指纹不变
    const f = try p.userSettingsFile(gpa);
    defer gpa.free(f);
    try util.io.writeFile(t.io, f, "{\"model\":\"m\",\"maxTurns\":5}");
    var s2 = try Settings.load(t.io, gpa, &p, &env);
    defer s2.deinit(gpa);
    try testing.expectEqualStrings(s1.fingerprint, s2.fingerprint);

    // ② 字段重排（同一逻辑内容）→ **同一指纹**（规范化编码）
    try util.io.writeFile(t.io, f, "{\"maxTurns\":5,\"model\":\"m\"}");
    var s3 = try Settings.load(t.io, gpa, &p, &env);
    defer s3.deinit(gpa);
    try testing.expectEqualStrings(s1.fingerprint, s3.fingerprint);

    // ③ 内容真变（含同秒等长改写）→ 指纹变
    try util.io.writeFile(t.io, f, "{\"model\":\"n\",\"maxTurns\":5}");
    var s4 = try Settings.load(t.io, gpa, &p, &env);
    defer s4.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, s1.fingerprint, s4.fingerprint));

    // ④ 指纹就是 SHA-256(规范化 JSON) 的 hex
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const canon = try canonicalJson(arena.allocator(), s4.raw);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canon, &digest, .{});
    try testing.expectEqualStrings(std.fmt.bytesToHex(digest, .lower)[0..], s4.fingerprint);
}

test "settings: Snapshot.changedFrom（touch 不触发 / 同秒等长改写触发 / 增删层触发）" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }

    try t.writeUser(gpa, p, "{\"model\":\"m\"}");
    var a = try Snapshot.capture(t.io, gpa, &p);
    defer a.deinit(gpa);
    var b = try Snapshot.capture(t.io, gpa, &p);
    defer b.deinit(gpa);
    try testing.expect(!a.changedFrom(&b));

    // 同秒、等长改写：mtime 判定会漏，内容指纹不会
    const f = try p.userSettingsFile(gpa);
    defer gpa.free(f);
    try util.io.writeFile(t.io, f, "{\"model\":\"x\"}");
    var c = try Snapshot.capture(t.io, gpa, &p);
    defer c.deinit(gpa);
    try testing.expect(a.changedFrom(&c));
    try testing.expect(c.changedFrom(&a));

    // 新增层
    try t.writeProject(gpa, p, "settings.json", "{\"maxTurns\":1}");
    var d = try Snapshot.capture(t.io, gpa, &p);
    defer d.deinit(gpa);
    try testing.expect(c.changedFrom(&d));

    // 删除层
    const proj = try p.projectSettingsFile(gpa);
    defer gpa.free(proj);
    try util.io.deleteFile(t.io, proj);
    var e = try Snapshot.capture(t.io, gpa, &p);
    defer e.deinit(gpa);
    try testing.expect(d.changedFrom(&e));
}

test "settings: applyKeysLayer 只抽取 model.default → 档位名 default" {
    const gpa = testing.allocator;
    var s = Settings{};
    defer s.deinit(gpa);

    var cfg: userconfig.UserConfig = .{};
    defer cfg.deinit(gpa);
    s.applyKeysLayer(&cfg);
    try testing.expectEqualStrings("", s.model);

    // 有 model.default → 写的是**档位名**，不是具体模型（交给路由解析）
    var cfg2: userconfig.UserConfig = .{ .default_model = "MiniMax/MiniMax-M3" };
    defer cfg2.deinit(gpa);
    s.applyKeysLayer(&cfg2);
    try testing.expectEqualStrings("default", s.model);
}

test "settings: canonicalJson 顶层键排序（嵌套顺序保持）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parse(a, "{\"b\":{\"z\":1,\"a\":2},\"a\":1}");
    const s = try canonicalJson(a, v.object);
    try testing.expectEqualStrings("{\"a\":1,\"b\":{\"z\":1,\"a\":2}}", s);
}

test "settings: get() 读任意（含未知）键" {
    var t = try Tmp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    const gpa = testing.allocator;
    const p = try t.paths(gpa);
    defer {
        gpa.free(p.home);
        gpa.free(p.cwd);
    }
    const env = std.process.Environ.Map.init(gpa);

    try t.writeUser(gpa, p,
        \\{"futureThing":{"deep":[1,2]},"maxTurns":7,
        \\ "contextWindow":200000,"appendSystemPrompt":"be terse"}
    );
    var s = try Settings.load(t.io, gpa, &p, &env);
    defer s.deinit(gpa);
    try testing.expect(s.get("futureThing") != null);
    try testing.expectEqual(@as(usize, 2), s.get("futureThing").?.get("deep").?.array.len);
    try testing.expectEqual(@as(u32, 7), s.max_turns);
    try testing.expect(s.get("nope") == null);
    // 引擎读的两个任意键（INTERFACES 之外的扩展键）必须可检索
    try testing.expectEqual(@as(i64, 200000), s.getInt("contextWindow").?);
    try testing.expectEqualStrings("be terse", s.getString("appendSystemPrompt").?);
    try testing.expect(s.getString("contextWindow") == null); // 类型不符 → null
}

test "settings: 用户根 settings 与工作区 settings 是**不同文件**" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/h", .cwd = "/repo" };
    const us = try p.userSettingsFile(gpa);
    defer gpa.free(us);
    const ps = try p.projectSettingsFile(gpa);
    defer gpa.free(ps);
    try testing.expect(!std.mem.eql(u8, us, ps));
    try testing.expect(std.mem.indexOf(u8, us, ".zigent") != null);
    try testing.expect(std.mem.indexOf(u8, ps, ".agents") != null);
}
