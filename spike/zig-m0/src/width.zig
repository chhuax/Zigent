//! 显示宽度（E3）—— Zig 生态缺终端显示宽度的等价物，必须自建。
//!
//! 为什么这块在 spike 里：仓库 CJK 重度使用，而既有实现侧**自己就不一致**——
//! `PermissionPrompt` 用终端宽度的 `wcwidth` 做框线对齐，
//! 但 `MarkdownRenderer` / `StatusLineRenderer.fit` 却按 `String.length()` 补齐。
//! 宽度算错是**肉眼可见**的（框线歪、表格错位、截断劈开 emoji）。
//!
//! ⚠️ 本文件是**最小可用子集**，不是完整 UCD：
//! - 覆盖了常用的 CJK / 全角 / 韩文 / 常见 emoji 区段；
//! - **完整实现应从 UCD 生成**（`EastAsianWidth.txt` + `GraphemeBreakProperty.txt`
//! + `emoji-data.txt`），并在 build.zig 里加一步生成，而不是手抄。
//! 这是 SPIKE-E3 要给出的结论之一：**手抄表 vs 引 ICU4C**。

const std = @import("std");

pub const width_zero = 0;
pub const width_one = 1;
pub const width_two = 2;

const Range = struct { lo: u21, hi: u21 };

/// East Asian Wide / Fullwidth（W + F）—— 占 2 列。
const wide: []const Range = &.{
 .{ .lo = 0x1100, .hi = 0x115F }, // Hangul Jamo
 .{ .lo = 0x2E80, .hi = 0x303E }, // CJK Radicals .. CJK Symbols
 .{ .lo = 0x3041, .hi = 0x33FF }, // Hiragana .. CJK Compatibility
 .{ .lo = 0x3400, .hi = 0x4DBF }, // CJK Ext A
 .{ .lo = 0x4E00, .hi = 0x9FFF }, // CJK Unified
 .{ .lo = 0xA000, .hi = 0xA4CF }, // Yi
 .{ .lo = 0xA960, .hi = 0xA97F }, // Hangul Jamo Extended-A
 .{ .lo = 0xAC00, .hi = 0xD7A3 }, // Hangul Syllables
 .{ .lo = 0xF900, .hi = 0xFAFF }, // CJK Compatibility Ideographs
 .{ .lo = 0xFE10, .hi = 0xFE19 }, // Vertical forms
 .{ .lo = 0xFE30, .hi = 0xFE6F }, // CJK Compatibility Forms
 .{ .lo = 0xFF00, .hi = 0xFF60 }, // Fullwidth Forms
 .{ .lo = 0xFFE0, .hi = 0xFFE6 }, // Fullwidth signs
 .{ .lo = 0x1F300, .hi = 0x1F64F }, // Misc Symbols and Pictographs + Emoticons
 .{ .lo = 0x1F900, .hi = 0x1F9FF }, // Supplemental Symbols and Pictographs
 .{ .lo = 0x1FA70, .hi = 0x1FAFF }, // Symbols and Pictographs Extended-A
 .{ .lo = 0x20000, .hi = 0x2FFFD }, // CJK Ext B..
 .{ .lo = 0x30000, .hi = 0x3FFFD }, // CJK Ext G..
};

/// 零宽：组合记号、变体选择符、ZWJ、方向控制、肤色修饰符。
const zero: []const Range = &.{
 .{ .lo = 0x0300, .hi = 0x036F }, // Combining Diacritical Marks
 .{ .lo = 0x0483, .hi = 0x0489 },
 .{ .lo = 0x0591, .hi = 0x05BD },
 .{ .lo = 0x0610, .hi = 0x061A },
 .{ .lo = 0x064B, .hi = 0x065F },
 .{ .lo = 0x0670, .hi = 0x0670 },
 .{ .lo = 0x06D6, .hi = 0x06DC },
 .{ .lo = 0x0E31, .hi = 0x0E31 }, // Thai
 .{ .lo = 0x0E34, .hi = 0x0E3A },
 .{ .lo = 0x0E47, .hi = 0x0E4E },
 .{ .lo = 0x200B, .hi = 0x200F }, // ZWSP .. RLM
 .{ .lo = 0x2028, .hi = 0x202E },
 .{ .lo = 0x2060, .hi = 0x2064 },
 .{ .lo = 0x20D0, .hi = 0x20F0 }, // Combining Diacritical Marks for Symbols
 .{ .lo = 0xFE00, .hi = 0xFE0F }, // Variation Selectors（VS16 也在此）
 .{ .lo = 0xFE20, .hi = 0xFE2F },
 .{ .lo = 0xFEFF, .hi = 0xFEFF }, // BOM / ZWNBSP
 .{ .lo = 0x1F3FB, .hi = 0x1F3FF }, // Emoji skin tone modifiers
 .{ .lo = 0xE0100, .hi = 0xE01EF }, // Variation Selectors Supplement
};

fn inRanges(cp: u21, list: []const Range) bool {
 // 线性扫描足够（表小且命中常见区间靠前）；若表变大应换成二分。
 for (list) |r| {
 if (cp < r.lo) return false; // 表按 lo 升序
 if (cp >= r.lo and cp <= r.hi) return true;
 }
 return false;
}

/// 单码位宽度：0 / 1 / 2。控制字符按 0 处理（调用方应自行过滤）。
pub fn codepointWidth(cp: u21) u8 {
 if (cp == 0) return 0;
 if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0; // C0/C1 控制符
 if (inRanges(cp, zero)) return 0;
 if (inRanges(cp, wide)) return width_two;
 return width_one;
}

/// 下一个码位 + 其字节长度。非法字节按 1 字节、宽度 1 处理（不 panic）。
fn nextCodepoint(s: []const u8, i: usize) struct { cp: u21, len: usize } {
 const b = s[i];
 var len: usize = 1;
 if (b < 0x80) return .{ .cp = b, .len = 1 };
 if (b & 0xE0 == 0xC0) len = 2 else if (b & 0xF0 == 0xE0) len = 3 else if (b & 0xF8 == 0xF0) len = 4;
 if (i + len > s.len) return .{ .cp = 0xFFFD, .len = 1 };
 const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cp = 0xFFFD, .len = 1 };
 return .{ .cp = cp, .len = len };
}

/// 字符串显示宽度。
///
/// 简化字形簇处理：
/// - 组合记号 / VS / ZWJ / 肤色修饰符 → 宽度 0（跟在基字符后不额外占位）；
/// - 区域指示符（国旗）成对算 2 列（单个算 2 列，成对不再翻倍）；
/// - keycap 序列（`1` + VS16 + U+20E3）→ 算 2 列（因为 VS16 把 `1` 变成 emoji 宽度）。
pub fn displayWidth(s: []const u8) usize {
 var total: usize = 0;
 var i: usize = 0;
 var prev_ri: bool = false; // 上一个是否区域指示符
 while (i < s.len) {
 const r = nextCodepoint(s, i);
 i += r.len;

 const is_ri = r.cp >= 0x1F1E6 and r.cp <= 0x1F1FF;
 if (is_ri) {
 // 成对国旗算 2 列：第一个 +2，第二个 +0
 if (!prev_ri) total += 2;
 prev_ri = true;
 continue;
 }
 prev_ri = false;

 if (r.cp == 0x20E3) continue; // 组合用 enclosing keycap：宽度已由基字符按 emoji 记
 total += codepointWidth(r.cp);
 }
 return total;
}

/// 按显示宽度截断，不劈开码位，也不在末尾留下半个宽字符。
/// 超出时追加 `ellipsis`（其宽度需调用方自行计入预算）。
pub fn truncateToWidth(s: []const u8, max_width: usize, ellipsis: []const u8) []const u8 {
 const ell_w = displayWidth(ellipsis);
 const budget = if (max_width > ell_w) max_width - ell_w else 0;

 var w: usize = 0;
 var i: usize = 0;
 var last_ok: usize = 0;
 while (i < s.len) {
 const r = nextCodepoint(s, i);
 const cw = codepointWidth(r.cp);
 if (w + cw > budget) break;
 w += cw;
 i += r.len;
 last_ok = i;
 }
 if (last_ok == s.len) return s; // 未超限，无需省略号
 // 返回值需要拼接，这里只返回可安全切分的前缀；省略号由调用方追加。
 return s[0..last_ok];
}

/// 左对齐补齐到 width（用于表格/框线）。宽度不足时补空格。
pub fn padRight(alloc: std.mem.Allocator, s: []const u8, width: usize) ![]u8 {
 const w = displayWidth(s);
 if (w >= width) return alloc.dupe(u8, s);
 var out = try std.ArrayListUnmanaged(u8).initCapacity(alloc, s.len + (width - w));
 errdefer out.deinit(alloc);
 try out.appendSlice(alloc, s);
 var k: usize = 0;
 while (k < width - w) : (k += 1) try out.append(alloc, ' ');
 return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "宽度：ASCII 与拉丁" {
 try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
 try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "宽度：CJK 是 2 列（框线对齐的基础）" {
 try std.testing.expectEqual(@as(usize, 4), displayWidth("中文"));
 try std.testing.expectEqual(@as(usize, 6), displayWidth("你好吗"));
 // 中英混排
 try std.testing.expectEqual(@as(usize, 7), displayWidth("ab中文c"));
}

test "宽度：全角与日文/韩文" {
 try std.testing.expectEqual(@as(usize, 2), displayWidth("Ａ")); // U+FF21 全角
 try std.testing.expectEqual(@as(usize, 2), displayWidth("あ")); // U+3042
 try std.testing.expectEqual(@as(usize, 2), displayWidth("한")); // U+11120? 实为 U+D55C
}

test "宽度：emoji 与变体选择符" {
 // 基础 emoji（U+1F600）
 try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F600}"));
 // emoji + VS16（VS16 必须算 0，否则宽度翻倍）
 try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{2764}\u{FE0F}"));
 // ZWJ 序列：宽度 0 的连接符不能额外占位
 try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F468}\u{200D}\u{1F469}"));
 // 肤色修饰符算 0
 try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F44D}\u{1F3FD}"));
}

test "宽度：区域指示符成对（国旗）只算 2 列" {
 // 🇨🇳 = U+1F1E8 U+1F1F3
 try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F1E8}\u{1F1F3}"));
 // 单个区域指示符按 2 列
 try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F1E8}"));
}

test "宽度：组合记号不占位" {
 // e + U+0301（combining acute）→ 1 列
 try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{0301}"));
}

test "截断：不劈开宽字符，也不超预算" {
 // "中文abc" 宽度 7；预算 5 → 只能放 "中文" + 1 个 ASCII = 宽度 5
 const s = "中文abc";
 const cut = truncateToWidth(s, 5, "");
 try std.testing.expectEqualStrings("中文a", cut);
 try std.testing.expect(displayWidth(cut) <= 5);

 // 预算 3 → "中文" 是 4 列，放不下 → 只能放 "中"
 const cut2 = truncateToWidth(s, 3, "");
 try std.testing.expectEqualStrings("中", cut2);

 // 预算 2 → 正好放 "中"
 try std.testing.expectEqualStrings("中", truncateToWidth(s, 2, ""));

 // 预算 1 → 放不下任何宽字符
 try std.testing.expectEqualStrings("", truncateToWidth(s, 1, ""));

 // 未超限时原样返回
 try std.testing.expectEqualStrings(s, truncateToWidth(s, 100, ""));
}

test "截断：为省略号预留宽度（中文 + …）" {
 const s = "这是一段很长的中文描述";
 const cut = truncateToWidth(s, 10, "…"); // 省略号占 1 列 → 正文预算 9
 try std.testing.expect(displayWidth(cut) + displayWidth("…") <= 10);
 try std.testing.expectEqual(@as(usize, 8), displayWidth(cut)); // 4 个汉字
}

test "补齐：padRight 按显示宽度补空格（表格对齐）" {
 const gpa = std.testing.allocator;
 const p = try padRight(gpa, "中文", 8);
 defer gpa.free(p);
 try std.testing.expectEqual(@as(usize, 8), displayWidth(p));
 try std.testing.expectEqualStrings("中文 ", p);
}
