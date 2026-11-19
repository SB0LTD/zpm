//! @zpm/ps5 agc — the graphics library (libSceAgc), written in Sig: the
//! calls a game writes its GPU command buffers with.
//!
//! A PS5 game does not write GPU packets itself. It owns a command buffer
//! (`CommandBuffer`: words, and a cursor that moves up through them) and
//! calls this library, whose functions each write one packet, or a few, at
//! the cursor (pm4.sig has the format). The game then hands the buffer to
//! the driver (agcdriver.sig), which carries it out. Each writer returns
//! where its first word went, or null when it wrote nothing: an argument it
//! refuses, or no room (after asking the buffer's own callback for more).
//!
//! The packets are AMD's, as open projects document the PS5's use of them.
//! A few are this library pair's own (a flip, the wait for a display
//! buffer, markers, the context-state operations: a NOP with a sub-type,
//! pm4.SUB): those are what an open emulator writes, not what a console is
//! known to write, and only this project's driver reads them.
//!
//! Also here: calls that change a packet already written (a jump's target,
//! a wait's address: "patch" calls), the size of each packet before it is
//! written, and the small calls that are not packets (static buffers, the
//! semaphore area).
//!
//! This file is the library's table and its end-to-end tests; the calls
//! are in agc_buffer.sig (the buffer, NOPs, registers), agc_draw.sig
//! (draws, dispatches), agc_sync.sig (flow, memory, sync, display,
//! markers, workloads), agc_patch.sig (patches, reading packets, what is
//! not a packet) and agc_shader.sig (shader objects and linking them).
//!
//! Not here: the register defaults (a large table), joining the halves
//! of a shader, the SDMA engine's calls.
//!
//! No Sony code: the calls, their arguments and the packets' words are as
//! open projects document them. x86-64 only. Allocation-free.

const std = @import("std");
const nid = @import("nid.sig");
const pm4 = @import("pm4.sig");

const core = @import("agc_buffer.sig");
const draw = @import("agc_draw.sig");
const sync = @import("agc_sync.sig");
const patch = @import("agc_patch.sig");
/// Shader objects: their header, the list of those a game created.
pub const shader = @import("agc_shader.sig");

pub const ERROR = core.ERROR;
pub const CommandBuffer = core.CommandBuffer;
pub const Grow = core.Grow;
pub const ShaderRegister = core.ShaderRegister;
pub const MemoryRange = core.MemoryRange;

// ── The table ───────────────────────────────────────────────────────────────

fn entry(comptime name: []const u8, comptime f: anytype) struct { []const u8, *const anyopaque } {
    return .{ name, @ptrCast(f) };
}

/// A size query whose answer is a constant (bytes). Any argument a game
/// passes is not read.
fn Size(comptime bytes: u32) type {
    return struct {
        fn get() callconv(.c) u32 {
            return bytes;
        }
    };
}

/// Every name this library answers, by NID.
pub const exports = nid.Table(*const anyopaque, &[_]struct { []const u8, *const anyopaque }{
    entry("sceAgcSetNop", &core.sceAgcSetNop),
    entry("sceAgcCbNop", &core.sceAgcCbNop),
    entry("sceAgcCbNopGetSize", &core.sceAgcCbNopGetSize),

    entry("sceAgcDcbSetCxRegisterDirect", &core.sceAgcDcbSetCxRegisterDirect),
    entry("sceAgcDcbSetShRegisterDirect", &core.sceAgcDcbSetShRegisterDirect),
    entry("sceAgcDcbSetUcRegisterDirect", &core.sceAgcDcbSetUcRegisterDirect),
    entry("sceAgcDcbSetCfRegisterDirect", &core.sceAgcDcbSetCfRegisterDirect),
    entry("sceAgcDcbSetCfRegisterRangeDirect", &core.sceAgcDcbSetCfRegisterRangeDirect),
    entry("sceAgcCbSetShRegisterRangeDirect", &core.sceAgcCbSetShRegisterRangeDirect),
    entry("sceAgcCbSetUcRegisterRangeDirect", &core.sceAgcCbSetUcRegisterRangeDirect),
    entry("sceAgcCbSetShRegistersDirect", &core.sceAgcCbSetShRegistersDirect),
    entry("sceAgcCbSetUcRegistersDirect", &core.sceAgcCbSetUcRegistersDirect),
    entry("sceAgcDcbSetCxRegistersIndirect", &core.sceAgcDcbSetCxRegistersIndirect),
    entry("sceAgcDcbSetShRegistersIndirect", &core.sceAgcDcbSetShRegistersIndirect),
    entry("sceAgcDcbSetUcRegistersIndirect", &core.sceAgcDcbSetUcRegistersIndirect),
    entry("sceAgcDcbSetCxRegisterDirectGetSize", &Size(12).get),
    entry("sceAgcDcbSetShRegisterDirectGetSize", &Size(12).get),
    entry("sceAgcDcbSetUcRegisterDirectGetSize", &Size(12).get),
    entry("sceAgcDcbSetCxRegistersIndirectGetSize", &Size(20).get),
    entry("sceAgcDcbSetShRegistersIndirectGetSize", &Size(20).get),
    entry("sceAgcDcbSetUcRegistersIndirectGetSize", &Size(20).get),
    entry("sceAgcCbSetShRegisterRangeDirectGetSize", &core.sceAgcCbSetRegisterRangeDirectGetSize),
    entry("sceAgcCbSetUcRegisterRangeDirectGetSize", &core.sceAgcCbSetRegisterRangeDirectGetSize),
    entry("sceAgcCbSetShRegistersDirectGetSize", &core.sceAgcCbSetRegistersDirectGetSize),
    entry("sceAgcCbSetUcRegistersDirectGetSize", &core.sceAgcCbSetRegistersDirectGetSize),

    entry("sceAgcCreateShader", &shader.sceAgcCreateShader),
    entry("sceAgcCreatePrimState", &shader.sceAgcCreatePrimState),
    entry("sceAgcUpdatePrimState", &shader.sceAgcUpdatePrimState),
    entry("sceAgcCreateInterpolantMapping", &shader.sceAgcCreateInterpolantMapping),
    entry("sceAgcUpdateInterpolantMapping", &shader.sceAgcUpdateInterpolantMapping),
    entry("sceAgcLinkShaders", &shader.sceAgcLinkShaders),
    entry("sceAgcGetGsOversubscription", &shader.sceAgcGetGsOversubscription),

    entry("sceAgcDcbDrawIndex", &draw.sceAgcDcbDrawIndex),
    entry("sceAgcDcbDrawIndexAuto", &draw.sceAgcDcbDrawIndexAuto),
    entry("sceAgcDcbDrawIndexOffset", &draw.sceAgcDcbDrawIndexOffset),
    entry("sceAgcDcbDrawIndexIndirect", &draw.sceAgcDcbDrawIndexIndirect),
    entry("sceAgcDcbDrawIndirect", &draw.sceAgcDcbDrawIndirect),
    entry("sceAgcDcbDrawIndexIndirectMulti", &draw.sceAgcDcbDrawIndexIndirectMulti),
    entry("sceAgcDcbDrawIndirectMulti", &draw.sceAgcDcbDrawIndirectMulti),
    entry("sceAgcDcbDrawIndexMultiInstanced", &draw.sceAgcDcbDrawIndexMultiInstanced),
    entry("sceAgcDcbSetIndexSize", &draw.sceAgcDcbSetIndexSize),
    entry("sceAgcDcbSetIndexBuffer", &draw.sceAgcDcbSetIndexBuffer),
    entry("sceAgcDcbSetIndexCount", &draw.sceAgcDcbSetIndexCount),
    entry("sceAgcDcbSetNumInstances", &draw.sceAgcDcbSetNumInstances),
    entry("sceAgcDcbSetIndexIndirectArgs", &draw.sceAgcDcbSetIndexIndirectArgs),
    entry("sceAgcDcbSetBaseIndirectArgs", &draw.sceAgcDcbSetBaseIndirectArgs),
    entry("sceAgcCbDispatch", &draw.sceAgcCbDispatch),
    entry("sceAgcDcbDispatchIndirect", &draw.sceAgcDcbDispatchIndirect),
    entry("sceAgcAcbDispatchIndirect", &draw.sceAgcAcbDispatchIndirect),
    entry("sceAgcDcbDrawIndexGetSize", &Size(24).get),
    entry("sceAgcDcbDrawIndexAutoGetSize", &Size(12).get),
    entry("sceAgcDcbDrawIndexOffsetGetSize", &Size(20).get),
    entry("sceAgcDcbDrawIndexIndirectGetSize", &Size(20).get),
    entry("sceAgcDcbDrawIndirectGetSize", &Size(20).get),
    entry("sceAgcDcbDrawIndexIndirectMultiGetSize", &Size(64).get),
    entry("sceAgcDcbDrawIndirectMultiGetSize", &Size(64).get),
    entry("sceAgcDcbDrawIndexMultiInstancedGetSize", &Size(60).get),
    entry("sceAgcDcbSetIndexBufferGetSize", &Size(12).get),
    entry("sceAgcDcbSetIndexCountGetSize", &Size(8).get),
    entry("sceAgcDcbSetIndexSizeGetSize", &Size(12).get),
    entry("sceAgcDcbSetIndexIndirectArgsGetSize", &Size(16).get),
    entry("sceAgcDcbSetNumInstancesGetSize", &Size(8).get),
    entry("sceAgcDcbSetBaseDispatchIndirectArgsGetSize", &Size(16).get),
    entry("sceAgcDcbSetBaseDrawIndirectArgsGetSize", &Size(16).get),
    entry("sceAgcCbDispatchGetSize", &Size(20).get),
    entry("sceAgcDcbDispatchIndirectGetSize", &Size(12).get),
    entry("sceAgcAcbDispatchIndirectGetSize", &Size(16).get),

    entry("sceAgcDcbJump", &sync.sceAgcDcbJump),
    entry("sceAgcAcbJump", &sync.sceAgcAcbJump),
    entry("sceAgcCbBranch", &sync.sceAgcCbBranch),
    entry("sceAgcCbCondWrite", &sync.sceAgcCbCondWrite),
    entry("sceAgcDcbCondExec", &sync.sceAgcDcbCondExec),
    entry("sceAgcAcbCondExec", &sync.sceAgcAcbCondExec),
    entry("sceAgcDcbRewind", &sync.sceAgcDcbRewind),
    entry("sceAgcAcbRewind", &sync.sceAgcAcbRewind),
    entry("sceAgcDcbSetPredication", &sync.sceAgcDcbSetPredication),
    entry("sceAgcDcbStallCommandBufferParser", &sync.sceAgcDcbStallCommandBufferParser),
    entry("sceAgcDcbResetQueue", &sync.sceAgcDcbResetQueue),
    entry("sceAgcDcbClearState", &sync.sceAgcDcbClearState),
    entry("sceAgcAcbResetQueue", &sync.sceAgcAcbResetQueue),
    entry("sceAgcDcbContextStateOp", &sync.sceAgcDcbContextStateOp),
    entry("sceAgcDcbContextStateOpGetSize", &sync.sceAgcDcbContextStateOpGetSize),
    entry("sceAgcDcbJumpGetSize", &Size(16).get),
    entry("sceAgcAcbJumpGetSize", &Size(16).get),
    entry("sceAgcCbBranchGetSize", &Size(56).get),
    entry("sceAgcCbCondWriteGetSize", &Size(36).get),
    entry("sceAgcDcbCondExecGetSize", &Size(20).get),
    entry("sceAgcAcbCondExecGetSize", &Size(20).get),
    entry("sceAgcDcbRewindGetSize", &Size(8).get),
    entry("sceAgcAcbRewindGetSize", &Size(8).get),
    entry("sceAgcDcbStallCommandBufferParserGetSize", &Size(8).get),
    // (no writer of these three is exported; their packet is taken to be a
    // SET_PREDICATION's)
    entry("sceAgcDcbSetZPassPredicationEnableGetSize", &Size(16).get),
    entry("sceAgcDcbSetPredicationDisableGetSize", &Size(16).get),
    entry("sceAgcDcbSetBoolPredicationEnableGetSize", &Size(16).get),

    entry("sceAgcDcbWriteData", &sync.sceAgcDcbWriteData),
    entry("sceAgcAcbWriteData", &sync.sceAgcAcbWriteData),
    entry("sceAgcDcbCopyData", &sync.sceAgcDcbCopyData),
    entry("sceAgcAcbCopyData", &sync.sceAgcAcbCopyData),
    entry("sceAgcDcbDmaData", &sync.sceAgcDcbDmaData),
    entry("sceAgcAcbDmaData", &sync.sceAgcAcbDmaData),
    entry("sceAgcDcbAcquireMem", &sync.sceAgcDcbAcquireMem),
    entry("sceAgcAcbAcquireMem", &sync.sceAgcAcbAcquireMem),
    entry("sceAgcCbReleaseMem", &sync.sceAgcCbReleaseMem),
    entry("sceAgcDcbWaitRegMem", &sync.sceAgcDcbWaitRegMem),
    entry("sceAgcAcbWaitRegMem", &sync.sceAgcAcbWaitRegMem),
    entry("sceAgcDcbEventWrite", &sync.sceAgcDcbEventWrite),
    entry("sceAgcAcbEventWrite", &sync.sceAgcAcbEventWrite),
    entry("sceAgcDcbAtomicMem", &sync.sceAgcDcbAtomicMem),
    entry("sceAgcAcbAtomicMem", &sync.sceAgcAcbAtomicMem),
    entry("sceAgcDcbAtomicGds", &sync.sceAgcDcbAtomicGds),
    entry("sceAgcAcbAtomicGds", &sync.sceAgcAcbAtomicGds),
    entry("sceAgcDcbMemSemaphore", &sync.sceAgcDcbMemSemaphore),
    entry("sceAgcAcbMemSemaphore", &sync.sceAgcAcbMemSemaphore),
    entry("sceAgcCbMemSemaphore", &sync.sceAgcCbMemSemaphore),
    entry("sceAgcDcbPrimeUtcl2", &sync.sceAgcDcbPrimeUtcl2),
    entry("sceAgcAcbPrimeUtcl2", &sync.sceAgcAcbPrimeUtcl2),
    entry("sceAgcDcbGetLodStats", &sync.sceAgcDcbGetLodStats),
    entry("sceAgcDcbWriteDataGetSize", &sync.sceAgcDcbWriteDataGetSize),
    entry("sceAgcDcbCopyDataGetSize", &Size(24).get),
    entry("sceAgcAcbCopyDataGetSize", &Size(24).get),
    entry("sceAgcDcbDmaDataGetSize", &Size(28).get),
    entry("sceAgcAcbDmaDataGetSize", &Size(28).get),
    entry("sceAgcDcbAcquireMemGetSize", &Size(32).get),
    entry("sceAgcAcbAcquireMemGetSize", &Size(32).get),
    // (the end-of-pipe and end-of-shader writers are inline in the SDK; their
    // packet is taken to be RELEASE_MEM's)
    entry("sceAgcCbQueueEndOfPipeActionGetSize", &Size(32).get),
    entry("sceAgcDcbQueueEndOfShaderActionGetSize", &Size(32).get),
    entry("sceAgcAcbQueueEndOfShaderActionGetSize", &Size(32).get),
    entry("sceAgcDcbWaitOnAddressGetSize", &sync.sceAgcWaitOnAddressGetSize),
    entry("sceAgcAcbWaitOnAddressGetSize", &sync.sceAgcWaitOnAddressGetSize),
    entry("sceAgcDcbEventWriteGetSize", &sync.sceAgcDcbEventWriteGetSize),
    entry("sceAgcAcbEventWriteGetSize", &Size(8).get),
    entry("sceAgcDcbAtomicMemGetSize", &Size(36).get),
    entry("sceAgcAcbAtomicMemGetSize", &Size(36).get),
    entry("sceAgcDcbAtomicGdsGetSize", &Size(44).get),
    entry("sceAgcAcbAtomicGdsGetSize", &Size(44).get),
    entry("sceAgcDcbPrimeUtcl2GetSize", &Size(20).get),
    entry("sceAgcAcbPrimeUtcl2GetSize", &Size(20).get),
    entry("sceAgcDcbGetLodStatsGetSize", &Size(20).get),
    entry("sceAgcDcbBeginOcclusionQueryGetSize", &sync.sceAgcDcbBeginOcclusionQueryGetSize),
    entry("sceAgcDcbEndOcclusionQueryGetSize", &Size(16).get),

    entry("sceAgcDcbSetFlip", &sync.sceAgcDcbSetFlip),
    entry("sceAgcAcbSetFlip", &sync.sceAgcAcbSetFlip),
    entry("sceAgcDcbWaitUntilSafeForRendering", &sync.sceAgcDcbWaitUntilSafeForRendering),
    entry("sceAgcAcbWaitUntilSafeForRendering", &sync.sceAgcAcbWaitUntilSafeForRendering),
    entry("sceAgcDcbPushMarker", &sync.sceAgcDcbPushMarker),
    entry("sceAgcAcbPushMarker", &sync.sceAgcDcbPushMarker),
    entry("sceAgcDcbPushMarkerSpan", &sync.sceAgcDcbPushMarkerSpan),
    entry("sceAgcAcbPushMarkerSpan", &sync.sceAgcDcbPushMarkerSpan),
    entry("sceAgcDcbSetMarker", &sync.sceAgcDcbSetMarker),
    entry("sceAgcAcbSetMarker", &sync.sceAgcDcbSetMarker),
    entry("sceAgcDcbSetMarkerSpan", &sync.sceAgcDcbSetMarkerSpan),
    entry("sceAgcAcbSetMarkerSpan", &sync.sceAgcDcbSetMarkerSpan),
    entry("sceAgcDcbPopMarker", &sync.sceAgcDcbPopMarker),
    entry("sceAgcAcbPopMarker", &sync.sceAgcDcbPopMarker),
    entry("sceAgcDcbSetWorkloadsActive", &sync.sceAgcDcbSetWorkloadsActive),
    entry("sceAgcAcbSetWorkloadsActive", &sync.sceAgcDcbSetWorkloadsActive),
    entry("sceAgcDcbSetWorkloadComplete", &sync.sceAgcDcbSetWorkloadComplete),
    entry("sceAgcAcbSetWorkloadComplete", &sync.sceAgcDcbSetWorkloadComplete),
    entry("sceAgcDcbSetWorkloadStreamInactive", &sync.sceAgcDcbSetWorkloadStreamInactive),
    entry("sceAgcAcbSetWorkloadStreamInactive", &sync.sceAgcDcbSetWorkloadStreamInactive),

    entry("sceAgcSetCxRegIndirectPatchSetAddress", &patch.CxIndirect.setAddress),
    entry("sceAgcSetShRegIndirectPatchSetAddress", &patch.ShIndirect.setAddress),
    entry("sceAgcSetUcRegIndirectPatchSetAddress", &patch.UcIndirect.setAddress),
    entry("sceAgcSetCxRegIndirectPatchSetNumRegisters", &patch.CxIndirect.setCount),
    entry("sceAgcSetShRegIndirectPatchSetNumRegisters", &patch.ShIndirect.setCount),
    entry("sceAgcSetUcRegIndirectPatchSetNumRegisters", &patch.UcIndirect.setCount),
    entry("sceAgcSetCxRegIndirectPatchAddRegisters", &patch.CxIndirect.add),
    entry("sceAgcSetShRegIndirectPatchAddRegisters", &patch.ShIndirect.add),
    entry("sceAgcSetUcRegIndirectPatchAddRegisters", &patch.UcIndirect.add),
    entry("sceAgcJumpPatchSetTarget", &patch.sceAgcJumpPatchSetTarget),
    entry("sceAgcBranchPatchSetCompareAddress", &patch.sceAgcBranchPatchSetCompareAddress),
    entry("sceAgcBranchPatchSetThenTarget", &patch.sceAgcBranchPatchSetThenTarget),
    entry("sceAgcBranchPatchSetElseTarget", &patch.sceAgcBranchPatchSetElseTarget),
    entry("sceAgcCondExecPatchSetCommandAddress", &patch.sceAgcCondExecPatchSetCommandAddress),
    entry("sceAgcAsyncCondExecPatchSetCommandAddress", &patch.sceAgcCondExecPatchSetCommandAddress),
    entry("sceAgcCondExecPatchSetEnd", &patch.sceAgcCondExecPatchSetEnd),
    entry("sceAgcAsyncCondExecPatchSetEnd", &patch.sceAgcCondExecPatchSetEnd),
    entry("sceAgcRewindPatchSetRewindState", &patch.sceAgcRewindPatchSetRewindState),
    entry("sceAgcAsyncRewindPatchSetRewindState", &patch.sceAgcRewindPatchSetRewindState),
    entry("sceAgcDmaDataPatchSetDstAddressOrOffset", &patch.sceAgcDmaDataPatchSetDstAddressOrOffset),
    entry("sceAgcDmaDataPatchSetSrcAddressOrOffsetOrImmediate", &patch.sceAgcDmaDataPatchSetSrcAddressOrOffsetOrImmediate),
    entry("sceAgcWaitRegMemPatchAddress", &patch.sceAgcWaitRegMemPatchAddress),
    entry("sceAgcWaitRegMemPatchReference", &patch.sceAgcWaitRegMemPatchReference),
    entry("sceAgcWaitRegMemPatchMask", &patch.sceAgcWaitRegMemPatchMask),
    entry("sceAgcWaitRegMemPatchCompareFunction", &patch.sceAgcWaitRegMemPatchCompareFunction),
    entry("sceAgcQueueEndOfPipeActionPatchAddress", &patch.sceAgcQueueEndOfPipeActionPatchAddress),
    entry("sceAgcQueueEndOfPipeActionPatchData", &patch.sceAgcQueueEndOfPipeActionPatchData),
    entry("sceAgcQueueEndOfPipeActionPatchGcrCntl", &patch.sceAgcQueueEndOfPipeActionPatchGcrCntl),
    entry("sceAgcQueueEndOfPipeActionPatchType", &patch.sceAgcQueueEndOfPipeActionPatchType),
    entry("sceAgcAcquireMemSetEngine", &patch.sceAgcAcquireMemSetEngine),
    entry("sceAgcSetPacketPredication", &patch.sceAgcSetPacketPredication),
    entry("sceAgcSetRangePredication", &patch.sceAgcSetRangePredication),

    entry("sceAgcGetPacketSize", &patch.sceAgcGetPacketSize),
    entry("sceAgcGetDataPacketPayloadAddress", &patch.sceAgcGetDataPacketPayloadAddress),
    entry("sceAgcGetDataPacketPayloadRange", &patch.sceAgcGetDataPacketPayloadRange),
    entry("sceAgcInit", &patch.sceAgcInit),
    entry("sceAgcSetStaticBuffer", &patch.sceAgcSetStaticBuffer),
    entry("sceAgcGetStaticBuffer", &patch.sceAgcGetStaticBuffer),
    entry("sceAgcSetAmmSemaphoreMemory", &patch.sceAgcSetAmmSemaphoreMemory),
    entry("sceAgcGetSemaphoreLabel", &patch.sceAgcGetSemaphoreLabel),
    entry("sceAgcDebugRaiseException", &patch.sceAgcDebugRaiseException),
    entry("sceAgcSuspendPoint", &patch.sceAgcSuspendPoint),
    entry("sceAgcSetSubmitMode", &patch.sceAgcSetSubmitMode),
});

/// The address of one of this library's functions, by the library a game
/// named and its NID; null when this is not the library or it has no such
/// function.
pub fn find(library: []const u8, n: nid.Nid) ?u64 {
    if (!std.mem.eql(u8, library, "libSceAgc")) return null;
    const p = exports.find(n) orelse return null;
    return @intFromPtr(p);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "names resolve by NID under the library's name" {
    try testing.expect(find("libSceAgc", nid.of("sceAgcCbNop")) != null);
    try testing.expectEqual(@as(?u64, null), find("libSceAgcDriver", nid.of("sceAgcCbNop")));
}

// End to end: buffers written with this library's calls (found by NID in
// its table, as a game's would be), submitted to the driver, carried out.
// The test is the driver's worker (agcdriver.waitIdle).

const agcdriver = @import("agcdriver.sig");
const videoout = @import("videoout.sig");
const lo32 = core.lo32;
const hi32 = core.hi32;

/// A function of this library by its name, through the table.
fn call(comptime T: type, comptime name: []const u8) T {
    return @ptrCast(exports.find(comptime nid.of(name)).?);
}

const Seen = struct {
    var drawn: [16]agcdriver.Draw = undefined;
    var cx80: [16]u32 = undefined;
    var draws: usize = 0;
    var syncs: usize = 0;

    fn onDraw(s: *const agcdriver.State, d: agcdriver.Draw) void {
        if (draws < drawn.len) {
            drawn[draws] = d;
            cx80[draws] = s.cx[0x80];
        }
        draws += 1;
    }
    fn onSync() void {
        syncs += 1;
    }

    fn reset() void {
        agcdriver.waitIdle();
        draws = 0;
        syncs = 0;
        agcdriver.renderer = .{ .draw = onDraw, .sync = onSync };
        inline for (.{ "submissions", "packets", "draws", "flips", "labels", "interrupts", "skipped", "refused" }) |name| @field(agcdriver.stats, name) = 0;
    }

    /// Submits as a game does (the driver's own export), and waits.
    fn run(words: []const u32) !void {
        const submit: *const fn (?*const agcdriver.Submission) callconv(.c) i32 = @ptrCast(agcdriver.exports.find(comptime nid.of("sceAgcDriverSubmitDcb")).?);
        const s = agcdriver.Submission{ .commands = words.ptr, .words = @intCast(words.len) };
        try testing.expectEqual(@as(i32, 0), submit(&s));
        agcdriver.waitIdle();
    }
};

test "a buffer written with these calls, carried out by the driver: state, draws, labels, flow" {
    Seen.reset();
    var idx32 = [_]u32{ 0, 1, 2, 2, 1, 3 };
    var idx16 = [_]u16{ 0, 1, 2, 2, 1, 3 };
    var records align(16) = [_]u32{ 4, 1, 0, 0 };
    var table align(16) = [_]u32{ lo32(@intFromPtr(&idx32)), hi32(@intFromPtr(&idx32)), 6, 1 };
    var gate: u32 = 1;
    // SET_PREDICATION encodes its address on a 16-byte boundary.
    var zero: u32 align(16) = 0;
    var one: u32 = 1;
    var row = [_]u32{0} ** 4;
    var wide: u64 align(8) = 0;
    var copy: u32 = 0;
    var bytes = [_]u8{0} ** 8;
    const data = [_]u32{ 1, 2, 3 };

    // A buffer that is called: a draw of 9.
    var inner: [8]u32 = undefined;
    var ib = CommandBuffer.over(&inner);
    _ = call(*const fn (?*CommandBuffer, u32, u64) callconv(.c) ?[*]u32, "sceAgcDcbDrawIndexAuto")(&ib, 9, 0);

    var mem: [512]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    const b = &cb;
    // (the predicate on, one instance: whatever the queue held before)
    _ = sync.sceAgcDcbSetPredication(b, 0, 0, 0, 0, 0);
    _ = draw.sceAgcDcbSetNumInstances(b, 1);
    _ = core.sceAgcDcbSetCxRegisterDirect(b, .{ .offset = 0x80, .value = 0x11 });
    _ = core.sceAgcDcbSetUcRegisterDirect(b, .{ .offset = agcdriver.UC.INDEX_OFFSET, .value = 7 });
    _ = sync.sceAgcDcbPushMarker(b, "frame", 0);
    _ = draw.sceAgcDcbDrawIndexAuto(b, 3, 0);
    _ = draw.sceAgcDcbSetNumInstances(b, 2);
    _ = draw.sceAgcDcbSetIndexSize(b, 1, 0);
    _ = draw.sceAgcDcbDrawIndex(b, 6, @intFromPtr(&idx32), 0);
    _ = draw.sceAgcDcbSetIndexSize(b, 0, 0);
    _ = draw.sceAgcDcbSetIndexBuffer(b, @intFromPtr(&idx16));
    _ = draw.sceAgcDcbSetIndexCount(b, 6);
    _ = draw.sceAgcDcbDrawIndexOffset(b, 0, 6, 0);
    _ = draw.sceAgcDcbSetBaseIndirectArgs(b, 0, @intFromPtr(&records));
    _ = draw.sceAgcDcbDrawIndirect(b, 0, 0);
    // The context registers put aside and cleared, then brought back.
    _ = sync.sceAgcDcbContextStateOp(b, 3);
    _ = draw.sceAgcDcbDrawIndexAuto(b, 5, 0);
    _ = sync.sceAgcDcbContextStateOp(b, 2);
    _ = draw.sceAgcDcbDrawIndexAuto(b, 6, 0);
    _ = sync.sceAgcDcbPopMarker(b);
    // A wait that holds at once; words, a 64-bit label, a copy, a fill.
    _ = sync.sceAgcDcbWaitRegMem(b, 0, 3, 0, 0, @intFromPtr(&gate), 1, 0xFFFF_FFFF, 0x40);
    _ = sync.sceAgcDcbWriteData(b, 2, 0, @intFromPtr(&row), &data, 3, 0, 0);
    _ = sync.sceAgcCbReleaseMem(b, 0x28, 0, 0, 0, @intFromPtr(&wide), 2, 0x1111_2222_3333_4444, 0, 0, 0, 0);
    _ = sync.sceAgcAcbCopyData(b, 5, 0, @intFromPtr(&copy), 1, 0, @intFromPtr(&row[1]), 0, 0);
    _ = sync.sceAgcAcbDmaData(b, 0, 0, @intFromPtr(&bytes), 2, 0, 0x4433_2211, 6, 0, 0);
    // A word that is 0: the next packet (3 words) is skipped; one that is
    // not: it runs.
    _ = sync.sceAgcDcbCondExec(b, @intFromPtr(&zero), 3);
    _ = draw.sceAgcDcbDrawIndexAuto(b, 100, 0);
    _ = sync.sceAgcDcbCondExec(b, @intFromPtr(&one), 3);
    _ = draw.sceAgcDcbDrawIndexAuto(b, 7, 0);
    // The other buffer, then on with this one.
    _ = sync.sceAgcDcbJump(b, 0, 0, @intFromPtr(&inner), @intCast(ib.written().len));
    // A packet marked for the predicate, while it does not hold.
    _ = sync.sceAgcDcbSetPredication(b, 1, 4, 0, @intFromPtr(&zero), 0);
    const marked = draw.sceAgcDcbDrawIndexAuto(b, 200, 0).?;
    try testing.expectEqual(@as(i32, 0), patch.sceAgcSetPacketPredication(marked, 1));
    _ = sync.sceAgcDcbSetPredication(b, 0, 0, 0, 0, 0);
    // What only orders the GPU's caches and pipeline.
    _ = sync.sceAgcDcbAcquireMem(b, 0, 0, 0x1234, @intFromPtr(&mem), 0x100, 0);
    _ = sync.sceAgcDcbEventWrite(b, 7, 0);
    _ = sync.sceAgcDcbStallCommandBufferParser(b);
    // The index buffer from a table record (32-bit indices).
    _ = draw.sceAgcDcbSetIndexIndirectArgs(b, @intFromPtr(&table), 0);
    _ = draw.sceAgcDcbDrawIndexOffset(b, 0, 6, 0);
    // A rewind already let go; a draw of nothing (counted, not drawn).
    _ = sync.sceAgcDcbRewind(b, 1);
    _ = draw.sceAgcDcbDrawIndexAuto(b, 0, 0);
    try testing.expect(cb.written().len > 100);
    try Seen.run(cb.written());

    try testing.expectEqual(@as(u64, 0), agcdriver.stats.skipped + agcdriver.stats.refused);
    try testing.expectEqual(@as(usize, 9), Seen.draws);
    try testing.expectEqual(@as(u64, 10), agcdriver.stats.draws);
    const D = agcdriver.Draw;
    const want = [_]D{
        .{ .count = 3, .instances = 1, .base_vertex = 7 },
        // (with indices, the same register is added to each of them)
        .{ .count = 6, .instances = 2, .index_address = @intFromPtr(&idx32), .index_size = 4, .base_vertex = 7 },
        .{ .count = 6, .instances = 2, .index_address = @intFromPtr(&idx16), .index_size = 2, .base_vertex = 7 },
        .{ .count = 4, .instances = 1 },
        .{ .count = 5, .instances = 2, .base_vertex = 7 },
        .{ .count = 6, .instances = 2, .base_vertex = 7 },
        .{ .count = 7, .instances = 2, .base_vertex = 7 },
        .{ .count = 9, .instances = 2, .base_vertex = 7 },
        .{ .count = 6, .instances = 2, .index_address = @intFromPtr(&idx32), .index_size = 4, .base_vertex = 7 },
    };
    for (want, Seen.drawn[0..want.len]) |w, d| try testing.expectEqual(w, d);
    // The register a draw saw: set, cleared with the context, brought back.
    try testing.expectEqual(@as(u32, 0x11), Seen.cx80[0]);
    try testing.expectEqual(@as(u32, 0), Seen.cx80[4]);
    try testing.expectEqual(@as(u32, 0x11), Seen.cx80[5]);

    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 0 }, &row);
    try testing.expectEqual(@as(u64, 0x1111_2222_3333_4444), wide);
    try testing.expectEqual(@as(u32, 2), copy);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44, 0x11, 0x22, 0, 0 }, &bytes);
    try testing.expectEqual(@as(u64, 4), agcdriver.stats.labels);
    try testing.expect(Seen.syncs >= 4);
}

test "a flip and the rendering wait written here, carried out by the driver and shown" {
    Seen.reset();
    const h = videoout.testOpen();
    defer videoout.testClose(h);
    var pixels = [_]u32{0xFF10_2030} ** 4;
    try testing.expectEqual(@as(i32, 0), videoout.testRegister(h, 0, &pixels, 2, 2));

    var mem: [32]u32 = undefined;
    var cb = CommandBuffer.over(&mem);
    _ = sync.sceAgcDcbWaitUntilSafeForRendering(&cb, @intCast(h), 0);
    _ = draw.sceAgcDcbDrawIndexAuto(&cb, 3, 0);
    _ = call(*const fn (?*CommandBuffer, u32, i32, u32, i64) callconv(.c) ?[*]u32, "sceAgcDcbSetFlip")(&cb, @intCast(h), 0, 1, 0x7777);
    try Seen.run(cb.written());
    try testing.expectEqual(@as(u64, 1), agcdriver.stats.flips);
    try testing.expectEqual(@as(u64, 0), agcdriver.stats.skipped + agcdriver.stats.refused);
    try testing.expectEqual(@as(usize, 1), Seen.draws);
    try testing.expectEqual(@as(i32, 1), videoout.pendingFlips(h));
    videoout.tick();
    try testing.expectEqual(@as(i64, 0x7777), videoout.lastFlipArg(h));

    // The rendering wait is the driver's own packet, word for word.
    var theirs: [4]u32 = undefined;
    var at: [*]u32 = &theirs;
    const write: *const fn (?*[*]u32, u32, u32, u32, i32) callconv(.c) i32 = @ptrCast(agcdriver.exports.find(comptime nid.of("sceAgcDriverWaitUntilSafeForRendering")).?);
    try testing.expectEqual(@as(i32, 0), write(&at, 4, 0, @intCast(h), 0));
    try testing.expectEqualSlices(u32, &theirs, mem[0..4]);
}
