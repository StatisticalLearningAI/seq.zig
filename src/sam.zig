const seq = @import("./seq.zig");
const std = @import("std");
const testing = std.testing;

// https://samtools.github.io/hts-specs/SAMv1.pdf

pub const SortOrder = enum { unknown, unsorted, query_name, coordinate };

pub const GroupAlignment = enum {
    none, // default
    query, // alignments are grouped by QNAME
    reference, // alignments are grouped by RNAME/POS
};

pub const FieldType = enum { query_name, flags, reference_name, pos };

pub const HDTagType = enum { version, sorted_alignment };

pub const AlignmentColumns = {};

const HDTag = union(HDTagType) {
    version: struct { major: u16, minor: u16 },
};

pub const ReadGroup = struct {};
pub const RefSeqName = struct {};

pub const SamAlignmentFlags = struct {
    const Self = @This();

    paired: bool = false, // 0x1 the read is paired in sequencing, no matter whether it is mapped in a pair
    proper_pair: bool = false, // 0x2 each segment properly aligned according to the aligner
    unmap: bool = false, // 0x4 segment is unmapped conflicts with proper_pair
    munmap: bool = false, // 0x8 next segment in the template unmapped
    reverse: bool = false, // 0x10 SEQ being reverse complemented
    mate_reverse: bool = false, // 0x20 SEQ of the next segment in the template being reverse complemented
    read1: bool = false, // 0x40 first segment in the template
    read2: bool = false, // 0x80 second segment in the template
    secondary: bool = false, // 0x100 secondary alignment
    qc_failure: bool = false, // 0x200 not passing filters, such as platform/vendor quality controls QC
    dup: bool = false, // 0x400 PCR or optical duplicate
    sup_alignment: bool = false, // 0x800 supplementary allignment

    pub const PariedBit = 0x1;
    pub const ProperPairedBit = 0x2;
    pub const Unmapped = 0x4;
    pub const MateUnmapped = 0x8;
    pub const Reverse = 0x10;
    pub const MateReverse = 0x20;
    pub const Read1 = 0x40;
    pub const Read2 = 0x80;
    pub const Secondary = 0x100;
    pub const QCFailure = 0x200;
    pub const Dup = 0x400;
    pub const SupplementaryAlignment = 0x800;

    pub fn toSamAlignmentFlags(value: anytype) SamAlignmentFlags {
        return .{ .paired = (SamAlignmentFlags.PariedBit & value) > 0, .proper_pair = (SamAlignmentFlags.ProperPairedBit & value) > 0, .unmap = (SamAlignmentFlags.Unmapped & value) > 0, .munmap = (SamAlignmentFlags.MateUnmapped & value) > 0, .reverse = (SamAlignmentFlags.Reverse & value) > 0, .mate_reverse = (SamAlignmentFlags.MateReverse & value) > 0, .read1 = (SamAlignmentFlags.Read1 & value) > 0, .read2 = (SamAlignmentFlags.Read2 & value) > 0, .secondary = (SamAlignmentFlags.Secondary & value) > 0, .qc_failure = (SamAlignmentFlags.QCFailure & value) > 0, .dup = (SamAlignmentFlags.Dup & value) > 0, .sup_alignment = (SamAlignmentFlags.SupplementaryAlignment & value) > 0 };
    }

    pub fn toValue(self: *Self, comptime T: type) T {
        return (if (self.paired) (SamAlignmentFlags.PariedBit) or 0) |
            (if (self.proper_pair) (SamAlignmentFlags.ProperPairedBit) or 0) |
            (if (self.unmap) (SamAlignmentFlags.Unmapped) or 0) |
            (if (self.munmap) (SamAlignmentFlags.MateUnmapped) or 0) |
            (if (self.reverse) (SamAlignmentFlags.Reverse) or 0) |
            (if (self.mate_reverse) (SamAlignmentFlags.MateReverse) or 0) |
            (if (self.read1) (SamAlignmentFlags.Read1) or 0) |
            (if (self.read2) (SamAlignmentFlags.Read2) or 0) |
            (if (self.secondary) (SamAlignmentFlags.Secondary) or 0) |
            (if (self.qc_failure) (SamAlignmentFlags.QCFailure) or 0) |
            (if (self.dup) (SamAlignmentFlags.Dup) or 0) |
            (if (self.sup_alignment) (SamAlignmentFlags.SupplementaryAlignment) or 0);
    }
};

pub const ReaderOptions = struct {
    reserve_len: usize = 4096,
};
pub fn Scanner(comptime Stream: type, comptime options: ReaderOptions) type {
    return struct {
        const Self = @This();
        stream: Stream,

        state: enum {
            header,
            begin_alignment, // consume the required field
            seq, // consume theseq
            qual, // consume the qual
            end_alignment, // finish processing and return back to begin_alignment

           // header_hd,
           // header_sq,
           // header_rg,
           // header_pg,
           // header_co,
        } = .header,
        buffer: [options.reserve_len]u8 = undefined,
        consume_pos: usize = 0,

        // HD header
        minor_version: u16 = 0,
        major_version: u16 = 0,

        fn streamReadColumn(self: *Self, buffer: []u8) anyerror!struct { buf: []const u8, last: bool } {
            var reader = self.stream.reader();
            var pos: usize = 0;
            while (true) {
                const byte: u8 = reader.readByte() catch |err| switch (err) {
                    error.EndOfStream => return .{ .buf = buffer[0..pos], .last= true }, // the buffer is exausted
                    else => |e| return e,
                };
                switch (byte) {
                    // skip \r
                    std.ascii.control_code.cr => {},
                    // horizontal tab
                    std.ascii.control_code.ht, std.ascii.control_code.lf => return .{ .buf = buffer[0..pos], .last= byte == std.ascii.control_code.lf },
                    else => {
                        buffer[pos] = byte;
                        pos += 1;
                    },
                }
            }
        }

        pub fn next(self: *Self) (error{ ParseError, Overflow })!?union(enum) {
            // header meta data
            header_meta: struct { version: struct {
                major: u16,
                minor: u16,
            }, sub_sorting: struct { sort_order: SortOrder, tags: std.BoundedArray([]const u8, 16) }, sort_order: SortOrder, group_alignment: GroupAlignment },
            ref_sequence: struct {
                //name: []const u8,
                // locus: struct {

                // }
            },
            program: struct {},
            comment: []const u8,
            read_group: struct {},

            // alignment
            begin_alignment: struct {},
            alignment_seq: struct {},
            alignment_qual: struct {},
            end_alignment: struct {},
        }{
            var reader = self.stream.reader();
            while (true) {
                switch (self.state) {
                    .header => {
                        var name_column = self.streamReadColumn(self.buffer[0..]) catch return error.ParseError;
                        if (std.mem.eql(u8, name_column.buf, "@HD")) {
                            var sub_sorting: SortOrder = .unknown;
                            var sub_sorting_tags: std.BoundedArray([]const u8, 16) = .{};
                            var sort_order: SortOrder = .unknown;
                            var group_alignment: GroupAlignment = .none;
                            var begin: usize = 0;
                            blk: while (true) {
                                var entry_column = self.streamReadColumn(self.buffer[begin..]) catch return error.ParseError;
                                var split_iter = std.mem.splitSequence(u8, entry_column.buf, ":");
                                if (split_iter.next()) |key| {
                                    if (std.mem.eql(u8, key, "VN")) {
                                        if (split_iter.next()) |val| {
                                            var verion_iter = std.mem.splitSequence(u8, val, ".");
                                            if (verion_iter.next()) |major_str| {
                                                self.major_version = std.fmt.parseUnsigned(u16, major_str, 10) catch return error.ParseError;
                                            } else return error.ParseError;
                                            if (verion_iter.next()) |minor_str| {
                                                self.minor_version = std.fmt.parseUnsigned(u16, minor_str, 10) catch return error.ParseError;
                                            } else return error.ParseError;
                                        } else return error.ParseError;
                                    } else if (std.mem.eql(u8, key, "SO")) {
                                        if (split_iter.next()) |val| {
                                            if (std.mem.eql(u8, val, "unsorted")) {
                                                sort_order = .unsorted;
                                            } else if (std.mem.eql(u8, val, "queryname")) {
                                                sort_order = .query_name;
                                            } else if (std.mem.eql(u8, val, "coordinate")) {
                                                sort_order = .coordinate;
                                            } else return error.ParseError;
                                        } else return error.ParseError;
                                    } else if (std.mem.eql(u8, key, "GO")) {
                                        if (split_iter.next()) |val| {
                                            if (std.mem.eql(u8, val, "none")) {
                                                group_alignment = .none;
                                            } else if (std.mem.eql(u8, val, "query")) {
                                                group_alignment = .query;
                                            } else if (std.mem.eql(u8, val, "reference")) {
                                                group_alignment = .reference;
                                            } else return error.ParseError;
                                        } else return error.ParseError;
                                    } else if (std.mem.eql(u8, key, "SS")) {
                                        if (split_iter.next()) |val| {
                                            if (std.mem.eql(u8, val, "unsorted")) {
                                                sub_sorting = .unsorted;
                                            } else if (std.mem.eql(u8, val, "queryname")) {
                                                sub_sorting = .query_name;
                                            } else if (std.mem.eql(u8, val, "coordinate")) {
                                                sub_sorting = .coordinate;
                                            } else return error.ParseError;
                                        } else return error.ParseError;
                                        while (split_iter.next()) |val| {
                                            try sub_sorting_tags.append(val);
                                        }
                                        begin += entry_column.buf.len; // save this string since its referenced for sub sorting tags
                                    }
                                    if (entry_column.last) break :blk;
                                }
                            }
                            return .{ 
                                .header_meta = .{ 
                                    .version = .{
                                        .major = self.major_version,
                                        .minor = self.minor_version,
                                    }, 
                                    .sub_sorting = .{ 
                                        .sort_order = sub_sorting, 
                                        .tags = sub_sorting_tags 
                                    }, 
                                    .sort_order = sort_order, 
                                    .group_alignment = group_alignment 
                                } 
                            };
                        } else if (std.mem.eql(u8, name_column.buf, "@SQ")) {
                            var sequence_len: u32 = 0;
                            var name_str: []const u8 = self.buffer[0..0];
                            var begin: usize = 0;

                            blk: while (true) {
                                var entry_column = self.streamReadColumn(self.buffer[begin..]) catch return error.ParseError;
                                var split_iter = std.mem.splitSequence(u8, entry_column.buf, ":");
                                if (split_iter.next()) |key| {
                                    if (std.mem.eql(u8, key, "SN")) {
                                        if (split_iter.next()) |val| {
                                            name_str = val;
                                            begin += entry_column.buf.len;
                                        } else return error.ParseError;
                                    } else if (std.mem.eql(u8, key, "LN")) {
                                        if (split_iter.next()) |val| {
                                            sequence_len = std.fmt.parseUnsigned(u32, val, 10) catch return error.ParseError;
                                        } else return error.ParseError;
                                    } else if (std.mem.eql(u8, key, "AH")) {
                                    } else if (std.mem.eql(u8, key, "AN")) {
                                    } else if (std.mem.eql(u8, key, "AS")) {
                                    } else if (std.mem.eql(u8, key, "M5")) {
                                    } else if (std.mem.eql(u8, key, "SP")) {
                                    } else if (std.mem.eql(u8, key, "TP")) {
                                    } else if (std.mem.eql(u8, key, "UR")) {
                                    }
                                }
                                if (entry_column.last) break :blk;
                            }
                            return .{ .ref_sequence = .{} };
                        } else if (std.mem.eql(u8, name_column.buf, "@RG")) {
                            var begin: usize = 0;

                            blk: while (true) {
                                var entry_column = self.streamReadColumn(self.buffer[begin..]) catch return error.ParseError;
                                var split_iter = std.mem.splitSequence(u8, entry_column.buf, ":");
                                if (split_iter.next()) |key| {
                                    if (std.mem.eql(u8, key, "ID")) {
                                        
                                    } else if (std.mem.eql(u8, key, "BC")) {
                                    } else if (std.mem.eql(u8, key, "CN")) {
                                    } else if (std.mem.eql(u8, key, "DS")) {
                                    } else if (std.mem.eql(u8, key, "DT")) {
                                    } else if (std.mem.eql(u8, key, "FO")) {
                                    } else if (std.mem.eql(u8, key, "KS")) {
                                    } else if (std.mem.eql(u8, key, "LB")) {
                                    } else if (std.mem.eql(u8, key, "PG")) {
                                    } else if (std.mem.eql(u8, key, "PI")) {
                                    } else if (std.mem.eql(u8, key, "PL")) {
                                    } else if (std.mem.eql(u8, key, "PM")) {
                                    } else if (std.mem.eql(u8, key, "PU")) {
                                    } else if (std.mem.eql(u8, key, "SM")) {
                                    }
                                }
                                if (entry_column.last) break :blk;
                            }
                            return .{ .ref_sequence = .{} };
                        } else if (std.mem.eql(u8, name_column.buf, "@PG")) {
                            var begin: usize = 0;
                            blk: while (true) {
                                var entry_column = self.streamReadColumn(self.buffer[begin..]) catch return error.ParseError;
                                var split_iter = std.mem.splitSequence(u8, entry_column.buf, ":");
                                if (split_iter.next()) |key| {
                                    _ = key;
                                }
                                if (entry_column.last) break :blk;
                            }
                            return .{ .ref_sequence = .{} };
                        } else if (std.mem.eql(u8, name_column.buf, "@CO")) {
                            var pos: usize = 0;
                            blk: while (true) {
                                const byte: u8 = reader.readByte() catch |err| switch (err) {
                                    error.EndOfStream => break :blk, // the buffer is exausted
                                    else => |e| return e,
                                };
                                switch (byte) {
                                    // skip \r
                                    std.ascii.control_code.cr => {},
                                    // horizontal tab
                                    std.ascii.control_code.lf => break :blk,
                                    else => {
                                        self.buffer[pos] = byte;
                                        pos += 1;
                                    },
                                }
                            }
                            self.state = .header;
                            return .{ .comment = self.buffer[0..pos] };
                        } else {
                            self.state = .begin_alignment;
                            //break :blk;
                        }
                    },
                    //.header_co => {
                    //    var pos: usize = 0;
                    //    blk: while (true) {
                    //        const byte: u8 = reader.readByte() catch |err| switch (err) {
                    //            error.EndOfStream => break :blk, // the buffer is exausted
                    //            else => |e| return e,
                    //        };
                    //        switch (byte) {
                    //            // skip \r
                    //            std.ascii.control_code.cr => {},
                    //            // horizontal tab
                    //            std.ascii.control_code.lf => break :blk,
                    //            else => {
                    //                self.buffer[pos] = byte;
                    //                pos += 1;
                    //            },
                    //        }
                    //    }

                    //    self.state = .header;
                    //    return .{ .comment = self.buffer[0..pos] };
                    //},
                    //.header_sq => {
                    //    var sequence_len: u32 = 0;
                    //    var name_str: ?[]const u8 = null;
                    //    var begin: usize = 0;
                    //    var pos: usize = 0;

                    //    blk: while (true) {
                    //        const byte: u8 = reader.readByte() catch |err| switch (err) {
                    //            error.EndOfStream => break :blk, // the buffer is exausted
                    //            else => |e| return e,
                    //        };
                    //        switch (byte) {
                    //            // skip \r
                    //            std.ascii.control_code.cr => break,
                    //            // horizontal tab
                    //            std.ascii.control_code.ht, std.ascii.control_code.lf => {
                    //                var splitIter = std.mem.splitSequence(u8, self.buffer[begin..pos], ":");
                    //                if (splitIter.next()) |key| {
                    //                    if (std.mem.eql(u8, key, "SN")) {
                    //                        if (splitIter.next()) |val| {
                    //                            name_str = val;
                    //                            begin = pos;
                    //                        } else return error.ParseError;
                    //                    } else if (std.mem.eql(u8, key, "LN")) {
                    //                        if (splitIter.next()) |val| {
                    //                            sequence_len = std.fmt.parseUnsigned(u32, val, 10) catch return error.ParseError;
                    //                        } else return error.ParseError;
                    //                    } else if (std.mem.eql(u8, key, "AH")) {} else if (std.mem.eql(u8, key, "AN")) {} else if (std.mem.eql(u8, key, "AS")) {} else if (std.mem.eql(u8, key, "M5")) {} else if (std.mem.eql(u8, key, "SP")) {} else if (std.mem.eql(u8, key, "TP")) {} else if (std.mem.eql(u8, key, "UR")) {}
                    //                }
                    //                pos = begin; // move the pos

                    //                if (std.ascii.control_code.lf == byte) {
                    //                    break :blk;
                    //                }
                    //            },
                    //            else => {
                    //                self.buffer[pos] = byte;
                    //                pos += 1;
                    //            },
                    //        }
                    //    }
                    //    self.state = .header;
                    //    return .{ .ref_sequence = .{} };
                    //},
                    //.header_rg => {
                    //    var begin: usize = 0;
                    //    var pos: usize = 0;

                    //    blk: while (true) {
                    //        const byte: u8 = reader.readByte() catch |err| switch (err) {
                    //            error.EndOfStream => break :blk, // the buffer is exausted
                    //            else => |e| return e,
                    //        };
                    //        switch (byte) {
                    //            // skip \r
                    //            std.ascii.control_code.cr => {},
                    //            // horizontal tab
                    //            std.ascii.control_code.ht, std.ascii.control_code.lf => {
                    //                var splitIter = std.mem.splitSequence(u8, self.buffer[begin..pos], ":");
                    //                if (splitIter.next()) |key| {
                    //                    if (std.mem.eql(u8, key, "ID")) {} else if (std.mem.eql(u8, key, "BC")) {} else if (std.mem.eql(u8, key, "CN")) {} else if (std.mem.eql(u8, key, "DS")) {} else if (std.mem.eql(u8, key, "DT")) {} else if (std.mem.eql(u8, key, "FO")) {} else if (std.mem.eql(u8, key, "KS")) {} else if (std.mem.eql(u8, key, "LB")) {} else if (std.mem.eql(u8, key, "PG")) {} else if (std.mem.eql(u8, key, "PI")) {} else if (std.mem.eql(u8, key, "PL")) {} else if (std.mem.eql(u8, key, "PM")) {} else if (std.mem.eql(u8, key, "PU")) {} else if (std.mem.eql(u8, key, "SM")) {}
                    //                }
                    //                pos = begin; // move the pos

                    //                if (std.ascii.control_code.lf == byte) {
                    //                    break :blk;
                    //                }
                    //            },
                    //            else => {
                    //                self.buffer[pos] = byte;
                    //                pos += 1;
                    //            },
                    //        }
                    //    }

                    //    self.state = .header;
                    //    return .{ .ref_sequence = .{} };
                    //},
                    //.header_pg => {
                    //    var pos: usize = 0;
                    //    blk: while (true) {
                    //        const byte: u8 = reader.readByte() catch |err| switch (err) {
                    //            error.EndOfStream => break :blk, // the buffer is exausted
                    //            else => |e| return e,
                    //        };
                    //        switch (byte) {
                    //            // skip \r
                    //            std.ascii.control_code.cr => {},
                    //            // horizontal tab
                    //            std.ascii.control_code.lf => break :blk,
                    //            else => {
                    //                self.buffer[pos] = byte;
                    //                pos += 1;
                    //            },
                    //        }
                    //    }

                    //    self.state = .header;
                    //    return .{ .program = .{} };
                    //},
                    //.header_hd => {
                    //    var sub_sorting: SortOrder = .unknown;
                    //    var sub_sorting_tags: std.BoundedArray([]const u8, 16) = .{};
                    //    var sort_order: SortOrder = .unknown;
                    //    var group_alignment: GroupAlignment = .none;
                    //    var begin: usize = 0;
                    //    var pos: usize = 0;

                    //    blk: while (true) {
                    //        const byte: u8 = reader.readByte() catch |err| switch (err) {
                    //            error.EndOfStream => break :blk, // the buffer is exausted
                    //            else => |e| return e,
                    //        };
                    //        switch (byte) {
                    //            // skip \r
                    //            std.ascii.control_code.cr => break,
                    //            // horizontal tab
                    //            std.ascii.control_code.ht, std.ascii.control_code.lf => {
                    //                var splitIter = std.mem.splitSequence(u8, self.buffer[begin..pos], ":");
                    //                if (splitIter.next()) |key| {
                    //                    if (std.mem.eql(u8, key, "VN")) {
                    //                        if (splitIter.next()) |val| {
                    //                            var verion_iter = std.mem.splitSequence(u8, val, ".");
                    //                            if (verion_iter.next()) |major_str| {
                    //                                self.major_version = std.fmt.parseUnsigned(u16, major_str, 10) catch return error.ParseError;
                    //                            } else return error.ParseError;
                    //                            if (verion_iter.next()) |minor_str| {
                    //                                self.minor_version = std.fmt.parseUnsigned(u16, minor_str, 10) catch return error.ParseError;
                    //                            } else return error.ParseError;
                    //                        } else return error.ParseError;
                    //                    } else if (std.mem.eql(u8, key, "SO")) {
                    //                        if (splitIter.next()) |val| {
                    //                            if (std.mem.eql(u8, val, "unsorted")) {
                    //                                sort_order = .unsorted;
                    //                            } else if (std.mem.eql(u8, val, "queryname")) {
                    //                                sort_order = .query_name;
                    //                            } else if (std.mem.eql(u8, val, "coordinate")) {
                    //                                sort_order = .coordinate;
                    //                            } else return error.ParseError;
                    //                        } else return error.ParseError;
                    //                    } else if (std.mem.eql(u8, key, "GO")) {
                    //                        if (splitIter.next()) |val| {
                    //                            if (std.mem.eql(u8, val, "none")) {
                    //                                group_alignment = .none;
                    //                            } else if (std.mem.eql(u8, val, "query")) {
                    //                                group_alignment = .query;
                    //                            } else if (std.mem.eql(u8, val, "reference")) {
                    //                                group_alignment = .reference;
                    //                            } else return error.ParseError;
                    //                        } else return error.ParseError;
                    //                    } else if (std.mem.eql(u8, key, "SS")) {
                    //                        if (splitIter.next()) |val| {
                    //                            if (std.mem.eql(u8, val, "unsorted")) {
                    //                                sub_sorting = .unsorted;
                    //                            } else if (std.mem.eql(u8, val, "queryname")) {
                    //                                sub_sorting = .query_name;
                    //                            } else if (std.mem.eql(u8, val, "coordinate")) {
                    //                                sub_sorting = .coordinate;
                    //                            } else return error.ParseError;
                    //                        } else return error.ParseError;
                    //                        while (splitIter.next()) |val| {
                    //                            try sub_sorting_tags.append(val);
                    //                        }
                    //                        begin = pos; // save this string since its referenced for sub sorting tags
                    //                    }
                    //                }
                    //                pos = begin; // move the pos consumed some amount of the buffer for something else

                    //                if (std.ascii.control_code.lf == byte) {
                    //                    break :blk;
                    //                }
                    //            },
                    //            else => {
                    //                self.buffer[pos] = byte;
                    //                pos += 1;
                    //            },
                    //        }
                    //    }
                    //    self.state = .header;
                    //    return .{ .header_meta = .{ .version = .{
                    //        .major = self.major_version,
                    //        .minor = self.minor_version,
                    //    }, .sub_sorting = .{ .sort_order = sub_sorting, .tags = sub_sorting_tags }, .sort_order = sort_order, .group_alignment = group_alignment } };
                    //},
                    .begin_alignment => {},
                    else => unreachable,
                }
            }
            return null;
        }
    };
}

pub fn scanner(stream: anytype, comptime options: ReaderOptions) Scanner(@TypeOf(stream), options) {
    return .{ .stream = stream };
}
//1 0x1 template having multiple segments in sequencing
//2 0x2 each segment properly aligned according to the aligner
//4 0x4 segment unmapped
//8 0x8 next segment in the template unmapped
//16 0x10 SEQ being reverse complemented
//32 0x20 SEQ of the next segment in the template being reverse complemented
//64 0x40 the first segment in the template
//128 0x80 the last segment in the template
//256 0x100 secondary alignment
//512 0x200 not passing filters, such as platform/vendor quality controls
//1024 0x400 PCR or optical duplicate
//2048 0x800 supplementary alignment

//1 QNAME String [!-?A-~]{1,254} Query template NAME
//2 FLAG Int [0, 216 − 1] bitwise FLAG
//3 RNAME String \*|[:rname:∧*=][:rname:]* Reference sequence NAME11
//4 POS Int [0, 231 − 1] 1-based leftmost mapping POSition
//5 MAPQ Int [0, 28 − 1] MAPping Quality
//6 CIGAR String \*|([0-9]+[MIDNSHPX=])+ CIGAR string
//7 RNEXT String \*|=|[:rname:∧*=][:rname:]* Reference name of the mate/next read
//8 PNEXT Int [0, 231 − 1] Position of the mate/next read
//9 TLEN Int [−231 + 1, 231 − 1] observed Template LENgth
//10 SEQ String \*|[A-Za-z=.]+ segment SEQuence
//11 QUAL String [!-~]+ ASCII of Phred-scaled base QUALity+33

test "validate header" {
    const header =
        \\@HD	VN:1.6	SO:coordinate
    ;
    var stream = std.io.fixedBufferStream(header);
    var scan = scanner(stream, .{});
    if (try scan.next()) |res| {
        switch (res) {
            .header_meta => |value| {
                try testing.expectEqual(value.version.major, 1);
                try testing.expectEqual(value.version.minor, 6);
            },
            else => try testing.expect(false),
        }
    } else try testing.expect(false);
}

//test "read sam record" {
//    const file = @embedFile("./test/t1.fq");
//    var stream = std.io.fixedBufferStream(file);
//    var iter = seq.fa.fastaReadIterator(stream, .{});
//    _ = iter;
//
//    const TestResult = struct {
//        const Self = @This();
//        name: std.ArrayListUnmanaged(u8),
//        qual: std.ArrayListUnmanaged(u8),
//        seq: std.ArrayListUnmanaged(u8),
//    };
//    var faTestRecord: TestResult = .{ .name = .{}, .seq = .{}, .qual = .{} };
//
//    var consumer = struct {
//        context: *TestResult,
//        const Self = @This();
//        pub const Error = error{OutOfMemory};
//        pub inline fn writeSeq(buf: []const u8) void {
//            _ = buf;
//        }
//        pub inline fn writeQual(buf: []const u8) void {
//            _ = buf;
//        }
//    }{ .context = &faTestRecord };
//    _ = consumer;
//}
