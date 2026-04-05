const std = @import("std");

// QR Code encoder for versions 2-6, ECC Level Low, Byte mode only.
// Designed for encoding URLs up to ~134 characters for terminal display.

const MAX_VERSION = 6;
const MAX_SIZE = 17 + MAX_VERSION * 4; // 41 for version 6
const MAX_MODULES = MAX_SIZE * MAX_SIZE;

pub const QrCode = struct {
    modules: [MAX_MODULES]bool,
    size: u32,

    pub fn get(self: QrCode, row: u32, col: u32) bool {
        return self.modules[row * self.size + col];
    }

    fn set(self: *QrCode, row: u32, col: u32, val: bool) void {
        self.modules[row * self.size + col] = val;
    }
};

pub const QrError = error{
    DataTooLong,
};

// Version table: data codewords and EC codewords for Low ECC
const VersionInfo = struct {
    size: u32,
    data_codewords: u32,
    ec_codewords: u32,
    data_capacity_bytes: u32, // max bytes in byte mode
};

const version_table = [_]VersionInfo{
    .{ .size = 25, .data_codewords = 34, .ec_codewords = 10, .data_capacity_bytes = 32 }, // V2
    .{ .size = 29, .data_codewords = 55, .ec_codewords = 15, .data_capacity_bytes = 53 }, // V3
    .{ .size = 33, .data_codewords = 80, .ec_codewords = 20, .data_capacity_bytes = 78 }, // V4
    .{ .size = 37, .data_codewords = 108, .ec_codewords = 26, .data_capacity_bytes = 106 }, // V5
    .{ .size = 41, .data_codewords = 136, .ec_codewords = 18, .data_capacity_bytes = 134 }, // V6
};

fn versionIndex(version: u32) u32 {
    return version - 2;
}

fn selectVersion(data_len: usize) !u32 {
    for (0..version_table.len) |i| {
        if (data_len <= version_table[i].data_capacity_bytes) {
            return @intCast(i + 2);
        }
    }
    return QrError.DataTooLong;
}

// ── GF(2^8) arithmetic with primitive polynomial 0x11D ──

const GF_SIZE = 256;

const gf_exp = blk: {
    var table: [512]u8 = undefined;
    var x: u32 = 1;
    for (0..255) |i| {
        table[i] = @intCast(x);
        x <<= 1;
        if (x >= 256) x ^= 0x11D;
    }
    for (255..512) |i| {
        table[i] = table[i - 255];
    }
    break :blk table;
};

const gf_log = blk: {
    var table: [256]u8 = undefined;
    table[0] = 0; // undefined, but set to 0
    for (0..255) |i| {
        table[gf_exp[i]] = @intCast(i);
    }
    break :blk table;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(u32, gf_log[a]) + @as(u32, gf_log[b])];
}

// ── Reed-Solomon ──

fn rsGeneratorPoly(comptime n: u32) [n + 1]u8 {
    var gen: [n + 1]u8 = .{0} ** (n + 1);
    gen[0] = 1;

    for (0..n) |i| {
        // multiply gen by (x - α^i)
        var j: u32 = @intCast(i + 1);
        while (j > 0) : (j -= 1) {
            gen[j] = gen[j - 1] ^ gfMul(gen[j], gf_exp[i]);
        }
        gen[0] = gfMul(gen[0], gf_exp[i]);
    }
    return gen;
}

fn rsEncode(data: []const u8, ec_count: u32, ec_out: []u8) void {
    // Use the max ec_count we'll ever need (26 for V5)
    rsEncodeInner(data, ec_count, ec_out);
}

fn rsEncodeInner(data: []const u8, ec_count: u32, ec_out: []u8) void {
    // We need to generate the generator polynomial at runtime since ec_count varies
    // Use a buffer large enough for our max (26 EC codewords)
    var gen: [27]u8 = .{0} ** 27;
    gen[0] = 1;

    for (0..ec_count) |i| {
        var j: u32 = @intCast(i + 1);
        while (j > 0) : (j -= 1) {
            gen[j] = gen[j - 1] ^ gfMul(gen[j], gf_exp[i]);
        }
        gen[0] = gfMul(gen[0], gf_exp[i]);
    }

    // Polynomial division
    var remainder: [27]u8 = .{0} ** 27;

    for (data) |byte| {
        const coef = byte ^ remainder[0];
        // shift remainder
        for (0..ec_count) |i| {
            if (i + 1 < ec_count) {
                remainder[i] = remainder[i + 1];
            } else {
                remainder[i] = 0;
            }
        }
        // add gen * coef
        for (0..ec_count) |i| {
            remainder[i] ^= gfMul(gen[ec_count - 1 - i], coef);
        }
    }

    for (0..ec_count) |i| {
        ec_out[i] = remainder[i];
    }
}

// ── Data Encoding ──

fn encodeData(data: []const u8, version: u32) struct { codewords: [136]u8, count: u32 } {
    const vi = versionIndex(version);
    const total_codewords = version_table[vi].data_codewords;

    var bits: [136 * 8]u1 = .{0} ** (136 * 8);
    var bit_pos: u32 = 0;

    // Mode indicator: 0100 (byte mode)
    writeBits(&bits, &bit_pos, 0b0100, 4);

    // Character count (8 bits for versions 1-9)
    writeBits(&bits, &bit_pos, @intCast(data.len), 8);

    // Data bytes
    for (data) |byte| {
        writeBits(&bits, &bit_pos, byte, 8);
    }

    // Terminator (up to 4 zero bits)
    const remaining_bits = total_codewords * 8 - bit_pos;
    const term_bits = @min(remaining_bits, 4);
    writeBits(&bits, &bit_pos, 0, @intCast(term_bits));

    // Pad to byte boundary
    if (bit_pos % 8 != 0) {
        const pad_bits: u4 = @intCast(8 - (bit_pos % 8));
        writeBits(&bits, &bit_pos, 0, pad_bits);
    }

    // Pad with alternating 0xEC, 0x11
    var pad_byte: u32 = 0;
    while (bit_pos < total_codewords * 8) {
        const pb: u8 = if (pad_byte % 2 == 0) 0xEC else 0x11;
        writeBits(&bits, &bit_pos, pb, 8);
        pad_byte += 1;
    }

    // Convert bits to bytes
    var codewords: [136]u8 = .{0} ** 136;
    for (0..total_codewords) |i| {
        var byte: u8 = 0;
        for (0..8) |b| {
            byte = (byte << 1) | bits[i * 8 + b];
        }
        codewords[i] = byte;
    }

    return .{ .codewords = codewords, .count = total_codewords };
}

fn writeBits(bits: []u1, pos: *u32, value: u32, count: u4) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const shift: u5 = @intCast(count - 1 - i);
        bits[pos.*] = @intCast((value >> shift) & 1);
        pos.* += 1;
    }
}

// ── Matrix Construction ──

pub fn encode(data: []const u8) !QrCode {
    const version = try selectVersion(data.len);
    const vi = versionIndex(version);
    const info = version_table[vi];
    const size = info.size;

    // Encode data codewords
    const encoded = encodeData(data, version);
    const data_codewords = encoded.codewords[0..encoded.count];

    // Generate EC codewords
    var ec_codewords: [26]u8 = undefined;
    rsEncode(data_codewords, info.ec_codewords, ec_codewords[0..info.ec_codewords]);

    // Build the full message: data + EC
    var message: [162]u8 = undefined; // max: 136 data + 26 ec
    const msg_len = info.data_codewords + info.ec_codewords;
    @memcpy(message[0..info.data_codewords], data_codewords);
    @memcpy(message[info.data_codewords..msg_len], ec_codewords[0..info.ec_codewords]);

    // Try all 8 mask patterns, pick the one with lowest penalty
    var best_qr: QrCode = undefined;
    var best_penalty: u32 = std.math.maxInt(u32);

    for (0..8) |mask_idx| {
        var qr = QrCode{
            .modules = .{false} ** MAX_MODULES,
            .size = size,
        };
        var is_function: [MAX_MODULES]bool = .{false} ** MAX_MODULES;

        placeFinderPatterns(&qr, &is_function);
        placeTimingPatterns(&qr, &is_function);
        if (version >= 2) {
            placeAlignmentPatterns(&qr, &is_function, version);
        }
        reserveFormatInfo(&qr, &is_function);

        // Dark module
        qr.set(4 * version + 9, 8, true);
        is_function[(4 * version + 9) * size + 8] = true;

        placeDataBits(&qr, &is_function, message[0..msg_len]);
        applyMask(&qr, &is_function, @intCast(mask_idx));
        writeFormatInfo(&qr, @intCast(mask_idx));

        const penalty = calculatePenalty(&qr);
        if (penalty < best_penalty) {
            best_penalty = penalty;
            best_qr = qr;
        }
    }

    return best_qr;
}

fn placeFinderPatterns(qr: *QrCode, is_function: []bool) void {
    const size = qr.size;
    // Top-left, top-right, bottom-left
    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 0, @as(i32, @intCast(size)) - 7 },
        .{ @as(i32, @intCast(size)) - 7, 0 },
    };

    for (positions) |pos| {
        const row_off = pos[0];
        const col_off = pos[1];

        // Place 7x7 finder + 1-module separator
        var dr: i32 = -1;
        while (dr <= 7) : (dr += 1) {
            var dc: i32 = -1;
            while (dc <= 7) : (dc += 1) {
                const r = row_off + dr;
                const c = col_off + dc;
                if (r < 0 or r >= @as(i32, @intCast(size)) or c < 0 or c >= @as(i32, @intCast(size))) continue;
                const ru: u32 = @intCast(r);
                const cu: u32 = @intCast(c);

                var dark = false;
                if (dr >= 0 and dr <= 6 and dc >= 0 and dc <= 6) {
                    // Inside the 7x7 area
                    const dru: u32 = @intCast(dr);
                    const dcu: u32 = @intCast(dc);
                    if (dru == 0 or dru == 6 or dcu == 0 or dcu == 6) {
                        dark = true; // border
                    } else if (dru >= 2 and dru <= 4 and dcu >= 2 and dcu <= 4) {
                        dark = true; // center
                    }
                }
                qr.set(ru, cu, dark);
                is_function[ru * size + cu] = true;
            }
        }
    }
}

fn placeTimingPatterns(qr: *QrCode, is_function: []bool) void {
    const size = qr.size;
    for (8..size - 8) |i| {
        const dark = (i % 2 == 0);
        // Horizontal timing (row 6)
        if (!is_function[6 * size + @as(u32, @intCast(i))]) {
            qr.set(6, @intCast(i), dark);
            is_function[6 * size + @as(u32, @intCast(i))] = true;
        }
        // Vertical timing (col 6)
        if (!is_function[@as(u32, @intCast(i)) * size + 6]) {
            qr.set(@intCast(i), 6, dark);
            is_function[@as(u32, @intCast(i)) * size + 6] = true;
        }
    }
}

// Alignment pattern center positions for versions 2-6
const alignment_positions = [_][]const u32{
    &.{ 6, 18 }, // V2
    &.{ 6, 22 }, // V3
    &.{ 6, 26 }, // V4
    &.{ 6, 30 }, // V5
    &.{ 6, 34 }, // V6
};

fn placeAlignmentPatterns(qr: *QrCode, is_function: []bool, version: u32) void {
    const positions = alignment_positions[version - 2];
    const size = qr.size;

    for (positions) |row| {
        for (positions) |col| {
            // Skip if overlapping with finder patterns
            if (isFinderArea(row, col, size)) continue;

            // Place 5x5 alignment pattern
            var dr: i32 = -2;
            while (dr <= 2) : (dr += 1) {
                var dc: i32 = -2;
                while (dc <= 2) : (dc += 1) {
                    const r: u32 = @intCast(@as(i32, @intCast(row)) + dr);
                    const c: u32 = @intCast(@as(i32, @intCast(col)) + dc);
                    const abs_dr = if (dr < 0) -dr else dr;
                    const abs_dc = if (dc < 0) -dc else dc;
                    const dark = (abs_dr == 2 or abs_dc == 2 or (dr == 0 and dc == 0));
                    qr.set(r, c, dark);
                    is_function[r * size + c] = true;
                }
            }
        }
    }
}

fn isFinderArea(row: u32, col: u32, size: u32) bool {
    // Top-left finder + separator: rows 0-8, cols 0-8
    if (row <= 8 and col <= 8) return true;
    // Top-right finder + separator: rows 0-8, cols size-9 to size-1
    if (row <= 8 and col >= size - 8) return true;
    // Bottom-left finder + separator: rows size-9 to size-1, cols 0-8
    if (row >= size - 8 and col <= 8) return true;
    return false;
}

fn reserveFormatInfo(qr: *QrCode, is_function: []bool) void {
    const size = qr.size;
    // Around top-left finder
    for (0..9) |i| {
        if (i < size) {
            // Horizontal (row 8)
            if (!is_function[8 * size + @as(u32, @intCast(i))]) {
                is_function[8 * size + @as(u32, @intCast(i))] = true;
            }
            // Vertical (col 8)
            if (!is_function[@as(u32, @intCast(i)) * size + 8]) {
                is_function[@as(u32, @intCast(i)) * size + 8] = true;
            }
        }
    }
    // Around top-right finder (row 8, cols size-8 to size-1)
    for (0..8) |i| {
        const col: u32 = size - 1 - @as(u32, @intCast(i));
        is_function[8 * size + col] = true;
    }
    // Around bottom-left finder (col 8, rows size-7 to size-1)
    for (0..7) |i| {
        const row: u32 = size - 1 - @as(u32, @intCast(i));
        is_function[row * size + 8] = true;
    }
}

fn placeDataBits(qr: *QrCode, is_function: []bool, message: []const u8) void {
    const size = qr.size;
    var bit_idx: u32 = 0;
    const total_bits: u32 = @intCast(message.len * 8);

    // Data is placed in a zigzag pattern: right-to-left columns, pairs
    // Starting from bottom-right, going up, then down, etc.
    var right: i32 = @as(i32, @intCast(size)) - 1;
    while (right >= 1) {
        // Skip vertical timing pattern column
        if (right == 6) {
            right -= 1;
            continue;
        }
        const left = right - 1;

        // Determine direction: upward for first pair, downward for next, etc.
        // The column pair index from the right determines direction
        const col_pair_from_right = (@as(u32, @intCast(size)) - 1 - @as(u32, @intCast(if (right > 6) right else right + 1))) / 2;
        const going_up = (col_pair_from_right % 2 == 0);

        if (going_up) {
            var row: i32 = @as(i32, @intCast(size)) - 1;
            while (row >= 0) : (row -= 1) {
                const ru: u32 = @intCast(row);
                // Right column first, then left
                for ([_]i32{ right, left }) |col| {
                    if (col < 0) continue;
                    const cu: u32 = @intCast(col);
                    if (is_function[ru * size + cu]) continue;
                    if (bit_idx < total_bits) {
                        const byte_idx = bit_idx / 8;
                        const bit_off: u3 = @intCast(7 - (bit_idx % 8));
                        qr.set(ru, cu, ((message[byte_idx] >> bit_off) & 1) == 1);
                        bit_idx += 1;
                    }
                }
            }
        } else {
            var row: u32 = 0;
            while (row < size) : (row += 1) {
                for ([_]i32{ right, left }) |col| {
                    if (col < 0) continue;
                    const cu: u32 = @intCast(col);
                    if (is_function[row * size + cu]) continue;
                    if (bit_idx < total_bits) {
                        const byte_idx = bit_idx / 8;
                        const bit_off: u3 = @intCast(7 - (bit_idx % 8));
                        qr.set(row, cu, ((message[byte_idx] >> bit_off) & 1) == 1);
                        bit_idx += 1;
                    }
                }
            }
        }

        right -= 2;
    }
}

fn applyMask(qr: *QrCode, is_function: []bool, mask: u3) void {
    const size = qr.size;
    for (0..size) |r| {
        for (0..size) |c| {
            if (is_function[r * size + c]) continue;
            const should_flip = switch (mask) {
                0 => (r + c) % 2 == 0,
                1 => r % 2 == 0,
                2 => c % 3 == 0,
                3 => (r + c) % 3 == 0,
                4 => (r / 2 + c / 3) % 2 == 0,
                5 => (r * c) % 2 + (r * c) % 3 == 0,
                6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0,
                7 => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
            };
            if (should_flip) {
                const idx = @as(u32, @intCast(r)) * size + @as(u32, @intCast(c));
                qr.modules[idx] = !qr.modules[idx];
            }
        }
    }
}

fn writeFormatInfo(qr: *QrCode, mask: u3) void {
    const size = qr.size;
    // ECC level Low = 01, mask pattern = 3 bits → 5 bits total
    const format_data: u32 = (0b01 << 3) | @as(u32, mask);

    // BCH(15,5) encoding
    var format_bits = bchEncode(format_data);

    // XOR with mask
    format_bits ^= 0x5412;

    // Place format info bits
    // Around top-left finder: horizontal (row 8, cols 0-7 skipping col 6)
    const horizontal_cols = [_]u32{ 0, 1, 2, 3, 4, 5, 7, 8 };
    const vertical_rows = [_]u32{ 8, 7, 5, 4, 3, 2, 1, 0 };

    // First 8 bits go to:
    // Horizontal: row 8, cols 0,1,2,3,4,5,7,8
    for (horizontal_cols, 0..) |col, i| {
        const bit = (format_bits >> @intCast(14 - i)) & 1;
        qr.set(8, col, bit == 1);
    }
    // Vertical: col 8, rows 8,7,5,4,3,2,1,0 (skipping row 6)
    for (vertical_rows, 0..) |row, i| {
        const bit = (format_bits >> @intCast(14 - i)) & 1;
        qr.set(row, 8, bit == 1);
    }

    // Remaining 7 bits:
    // Vertical (bottom-left): col 8, rows size-7 to size-1
    for (0..7) |i| {
        const bit = (format_bits >> @intCast(6 - i)) & 1;
        qr.set(size - 7 + @as(u32, @intCast(i)), 8, bit == 1);
    }
    // Horizontal (top-right): row 8, cols size-8 to size-1
    for (0..8) |i| {
        const bit = (format_bits >> @intCast(7 - i)) & 1;
        qr.set(8, size - 8 + @as(u32, @intCast(i)), bit == 1);
    }
}

fn bchEncode(data: u32) u32 {
    var d = data << 10;
    while (bitsLen(d) >= 11) {
        const shift = bitsLen(d) - 11;
        d ^= @as(u32, 0x537) << @intCast(shift);
    }
    return (data << 10) | d;
}

fn bitsLen(x: u32) u32 {
    if (x == 0) return 0;
    var n: u32 = 0;
    var v = x;
    while (v > 0) {
        n += 1;
        v >>= 1;
    }
    return n;
}

// ── Penalty Calculation ──

fn calculatePenalty(qr: *const QrCode) u32 {
    var penalty: u32 = 0;
    penalty += penaltyRule1(qr);
    penalty += penaltyRule2(qr);
    penalty += penaltyRule3(qr);
    penalty += penaltyRule4(qr);
    return penalty;
}

// Rule 1: Adjacent modules in row/column that are same color
fn penaltyRule1(qr: *const QrCode) u32 {
    var penalty: u32 = 0;
    const size = qr.size;

    // Horizontal
    for (0..size) |r| {
        var count: u32 = 1;
        for (1..size) |c| {
            if (qr.get(@intCast(r), @intCast(c)) == qr.get(@intCast(r), @intCast(c - 1))) {
                count += 1;
            } else {
                if (count >= 5) penalty += count - 2;
                count = 1;
            }
        }
        if (count >= 5) penalty += count - 2;
    }

    // Vertical
    for (0..size) |c| {
        var count: u32 = 1;
        for (1..size) |r| {
            if (qr.get(@intCast(r), @intCast(c)) == qr.get(@intCast(r - 1), @intCast(c))) {
                count += 1;
            } else {
                if (count >= 5) penalty += count - 2;
                count = 1;
            }
        }
        if (count >= 5) penalty += count - 2;
    }

    return penalty;
}

// Rule 2: 2x2 blocks of same color
fn penaltyRule2(qr: *const QrCode) u32 {
    var penalty: u32 = 0;
    const size = qr.size;

    for (0..size - 1) |r| {
        for (0..size - 1) |c| {
            const val = qr.get(@intCast(r), @intCast(c));
            if (val == qr.get(@intCast(r), @intCast(c + 1)) and
                val == qr.get(@intCast(r + 1), @intCast(c)) and
                val == qr.get(@intCast(r + 1), @intCast(c + 1)))
            {
                penalty += 3;
            }
        }
    }

    return penalty;
}

// Rule 3: Finder-like patterns
fn penaltyRule3(qr: *const QrCode) u32 {
    var penalty: u32 = 0;
    const size = qr.size;
    const pattern1 = [_]bool{ true, false, true, true, true, false, true, false, false, false, false };
    const pattern2 = [_]bool{ false, false, false, false, true, false, true, true, true, false, true };

    for (0..size) |r| {
        for (0..size) |c| {
            if (c + 11 <= size) {
                var match1 = true;
                var match2 = true;
                for (0..11) |k| {
                    const val = qr.get(@intCast(r), @intCast(c + k));
                    if (val != pattern1[k]) match1 = false;
                    if (val != pattern2[k]) match2 = false;
                }
                if (match1) penalty += 40;
                if (match2) penalty += 40;
            }
            if (r + 11 <= size) {
                var match1 = true;
                var match2 = true;
                for (0..11) |k| {
                    const val = qr.get(@intCast(r + k), @intCast(c));
                    if (val != pattern1[k]) match1 = false;
                    if (val != pattern2[k]) match2 = false;
                }
                if (match1) penalty += 40;
                if (match2) penalty += 40;
            }
        }
    }

    return penalty;
}

// Rule 4: Proportion of dark modules
fn penaltyRule4(qr: *const QrCode) u32 {
    const size = qr.size;
    var dark_count: u32 = 0;
    const total = size * size;

    for (0..size) |r| {
        for (0..size) |c| {
            if (qr.get(@intCast(r), @intCast(c))) dark_count += 1;
        }
    }

    const pct = (dark_count * 100) / total;
    const prev5 = (pct / 5) * 5;
    const next5 = prev5 + 5;

    const dev1 = if (prev5 >= 50) prev5 - 50 else 50 - prev5;
    const dev2 = if (next5 >= 50) next5 - 50 else 50 - next5;

    const min_dev = @min(dev1, dev2);
    return (min_dev / 5) * 10;
}

// ── Terminal Rendering ──

pub fn renderTerminal(writer: anytype, qr: QrCode, indent: []const u8) !void {
    const size = qr.size;
    const quiet = 2; // quiet zone modules
    const total = size + quiet * 2;

    // Process 2 rows at a time using half-block characters
    var row: u32 = 0;
    while (row < total) : (row += 2) {
        try writer.writeAll(indent);
        for (0..total) |c_idx| {
            const col: u32 = @intCast(c_idx);
            const top_dark = getWithQuietZone(qr, row, col, quiet);
            const bot_dark = if (row + 1 < total)
                getWithQuietZone(qr, row + 1, col, quiet)
            else
                false;

            if (top_dark and bot_dark) {
                try writer.writeAll("\u{2588}"); // █
            } else if (top_dark and !bot_dark) {
                try writer.writeAll("\u{2580}"); // ▀
            } else if (!top_dark and bot_dark) {
                try writer.writeAll("\u{2584}"); // ▄
            } else {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll("\n");
    }
}

fn getWithQuietZone(qr: QrCode, row: u32, col: u32, quiet: u32) bool {
    if (row < quiet or col < quiet) return false;
    const r = row - quiet;
    const c = col - quiet;
    if (r >= qr.size or c >= qr.size) return false;
    return qr.get(r, c);
}

// ── Tests ──

test "qr encode short url" {
    const qr = try encode("https://relay.fun.dev/#/pair/abc123:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789");
    try std.testing.expect(qr.size >= 21);
    try std.testing.expect(qr.size <= 41);
}

test "qr encode hello" {
    const qr = try encode("HELLO WORLD");
    try std.testing.expect(qr.size >= 21);
}

test "gf arithmetic" {
    // gfMul(2, 3) in GF(2^8)
    try std.testing.expectEqual(@as(u8, 6), gfMul(2, 3));
    // Multiplicative identity
    try std.testing.expectEqual(@as(u8, 5), gfMul(5, 1));
    // Multiply by zero
    try std.testing.expectEqual(@as(u8, 0), gfMul(0, 42));
}

test "bch encode" {
    // Test format info encoding for ECC L, mask 0
    const result = bchEncode(0b01_000);
    const masked = result ^ 0x5412;
    _ = masked;
    // Just verify it produces a 15-bit value
    try std.testing.expect(result < (1 << 15));
}

test "version selection" {
    try std.testing.expectEqual(@as(u32, 2), try selectVersion(10));
    try std.testing.expectEqual(@as(u32, 2), try selectVersion(32));
    try std.testing.expectEqual(@as(u32, 3), try selectVersion(33));
    try std.testing.expectEqual(@as(u32, 6), try selectVersion(134));
    try std.testing.expectError(QrError.DataTooLong, selectVersion(135));
}

test "render terminal" {
    const qr = try encode("test");
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderTerminal(fbs.writer(), qr, "  ");
    const output = fbs.getWritten();
    try std.testing.expect(output.len > 0);
    // Should contain block characters
    try std.testing.expect(std.mem.indexOf(u8, output, "\u{2588}") != null or
        std.mem.indexOf(u8, output, "\u{2580}") != null or
        std.mem.indexOf(u8, output, "\u{2584}") != null);
}
