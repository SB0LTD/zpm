//! Intel I219 Ethernet: the gigabit MAC inside Intel's PCH with an I219 PHY
//! beside it (the wired port of most Intel desktops and laptops since
//! Skylake; the I219-V on a Z390 board is PCI 8086:15BC), as a polled
//! network interface. Legacy descriptors, a receive and a transmit ring of
//! 2 KiB buffers, no interrupts: the shape of Galaxy's e1000 driver, plus
//! what a PCH port needs before its PHY answers at all.
//!
//! Zero allocation, freestanding. The host gives the driver its registers
//! and its memory through `Io` and `Memory`, so the same code runs in a
//! kernel and under the register-level model in this file's tests.
//!
//! What a PCH port needs that an 82574 does not:
//!
//! 1. The PHY may not be listening. The last system (Windows, or the
//!    firmware's low-power state) can leave it in Ultra Low Power mode or
//!    on SMBus instead of the PCIe-based link to the MAC. The driver asks
//!    the Management Engine to undo ULP when its firmware runs, else undoes
//!    it itself, then finds the PHY: as it is, with the MAC forced to SMBus,
//!    and last by cycling the PHY's power (LANPHYPC).
//! 2. PHY registers are paged (page << 5 | register), on MDIO address 2
//!    below page 768 and address 1 from there up; registers above 15 need
//!    the page written first, to address 1, register 31.
//! 3. The Management Engine shares the port. It can refuse a PHY reset
//!    (FWSM), and it writes registers of its own: a write waits while its
//!    arbiter is busy, and a ring tail is read back.
//! 4. After the link comes up, the MAC and PHY are tuned to its speed (the
//!    inter-packet gap, the PHY's receive configuration, its PLL clock gate
//!    timer, K1's clock request and the pointer gap at 1000 Mb/s).
//!
//! The order of each step, the register offsets and the bit values are
//! Intel's, as its BSD-licensed shared code (FreeBSD's sys/dev/e1000:
//! e1000_ich8lan.c, e1000_phy.c) gives them; that code is documentation
//! here, none of it is copied.
//!
//! Not done: the descriptor-ring flush Intel applies before a reset when a
//! previous owner left a ring in use (logged instead: `TDLEN`), Energy
//! Efficient Ethernet (switched off), flow control, multicast filters,
//! latency tolerance reporting, the NVM (the address is the one the
//! firmware loaded into receive address 0).
//!
//! State: the logic is proved against the model below. It has not run on
//! hardware yet.

// ══════════════════════════════════════════════════════════════════════════════
// PCI ids
// ══════════════════════════════════════════════════════════════════════════════

/// The MAC generations this driver knows: Sunrise Point (100/200 series)
/// and Cannon Point (300 series and the Ice Lake / Comet Lake parts Intel
/// groups with it). Tiger Lake and later need a K1 exit-timeout change this
/// driver does not make, and are not claimed.
pub const Family = enum { spt, cnp };

/// The family of an Intel (8086) Ethernet device id, or null when it is not
/// an I219 this driver takes.
pub fn family(device: u16) ?Family {
    return switch (device) {
        // I219-LM, -V, (2), (3), (4), (5); Comet Lake's (12) is grouped here
        0x156F, 0x1570, 0x15B7, 0x15B8, 0x15B9, 0x15D7, 0x15D8, 0x15E3, 0x15D6, 0x0D53, 0x0D55 => .spt,
        // (6), (7): Cannon Lake; (8), (9): Ice Lake; (10), (11): Comet Lake
        0x15BD, 0x15BE, 0x15BB, 0x15BC, 0x15DF, 0x15E0, 0x15E1, 0x15E2, 0x0D4E, 0x0D4F, 0x0D4C, 0x0D4D => .cnp,
        else => null,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Registers (BAR 0, 128 KiB)
// ══════════════════════════════════════════════════════════════════════════════

pub const R = struct {
    pub const CTRL: u32 = 0x0000;
    pub const STATUS: u32 = 0x0008;
    pub const FEXTNVM6: u32 = 0x0010;
    pub const CTRL_EXT: u32 = 0x0018;
    pub const MDIC: u32 = 0x0020;
    pub const FEXTNVM3: u32 = 0x003C;
    pub const ICR: u32 = 0x00C0;
    pub const IMC: u32 = 0x00D8;
    pub const FEXTNVM7: u32 = 0x00E4;
    pub const RCTL: u32 = 0x0100;
    pub const TCTL: u32 = 0x0400;
    pub const TIPG: u32 = 0x0410;
    pub const EXTCNF_CTRL: u32 = 0x0F00;
    pub const PCIEANACFG: u32 = 0x0F18;
    pub const IOSFPC: u32 = 0x0F28;
    pub const PBECCSTS: u32 = 0x100C;
    pub const RDBAL: u32 = 0x2800;
    pub const RDBAH: u32 = 0x2804;
    pub const RDLEN: u32 = 0x2808;
    pub const RDH: u32 = 0x2810;
    pub const RDT: u32 = 0x2818;
    pub const KABGTXD: u32 = 0x3004;
    pub const TDBAL: u32 = 0x3800;
    pub const TDBAH: u32 = 0x3804;
    pub const TDLEN: u32 = 0x3808;
    pub const TDH: u32 = 0x3810;
    pub const TDT: u32 = 0x3818;
    pub const TXDCTL0: u32 = 0x3828;
    pub const TARC0: u32 = 0x3840;
    pub const TXDCTL1: u32 = 0x3928;
    pub const TARC1: u32 = 0x3940;
    pub const RFCTL: u32 = 0x5008;
    pub const MTA: u32 = 0x5200;
    pub const RAL0: u32 = 0x5400;
    pub const RAH0: u32 = 0x5404;
    pub const H2ME: u32 = 0x5B50;
    pub const FWSM: u32 = 0x5B54;
    pub const FEXTNVM11: u32 = 0x5BBC;
};

pub const CTRL_SLU: u32 = 1 << 6;
pub const CTRL_FRCSPD: u32 = 1 << 11;
pub const CTRL_FRCDPX: u32 = 1 << 12;
pub const CTRL_LANPHYPC_OVERRIDE: u32 = 1 << 16;
pub const CTRL_LANPHYPC_VALUE: u32 = 1 << 17;
pub const CTRL_MEHE: u32 = 1 << 19;
pub const CTRL_RST: u32 = 1 << 26;
pub const CTRL_PHY_RST: u32 = 1 << 31;

pub const STATUS_FD: u32 = 1 << 0;
pub const STATUS_LU: u32 = 1 << 1;
pub const STATUS_SPEED_SHIFT = 6; // 0: 10, 1: 100, 2 and 3: 1000 Mb/s
pub const STATUS_LAN_INIT_DONE: u32 = 1 << 9;
pub const STATUS_PHYRA: u32 = 1 << 10;

pub const CTRL_EXT_LPCD: u32 = 1 << 2;
pub const CTRL_EXT_FORCE_SMBUS: u32 = 1 << 11;
pub const CTRL_EXT_RO_DIS: u32 = 1 << 17;
pub const CTRL_EXT_PHYPDEN: u32 = 1 << 20;
pub const CTRL_EXT_DMA_GATING: u32 = 1 << 22;

pub const MDIC_OP_WRITE: u32 = 1 << 26;
pub const MDIC_OP_READ: u32 = 1 << 27;
pub const MDIC_READY: u32 = 1 << 28;
pub const MDIC_ERROR: u32 = 1 << 30;

pub const EXTCNF_SWFLAG: u32 = 1 << 5;
pub const EXTCNF_GATE_PHY_CFG: u32 = 1 << 7;

pub const FWSM_RSPCIPHY: u32 = 1 << 6;
pub const FWSM_ULP_CFG_DONE: u32 = 1 << 10;
pub const FWSM_FW_VALID: u32 = 1 << 15;
pub const FWSM_PCIM2PCI: u32 = 1 << 24;

pub const H2ME_ULP: u32 = 1 << 11;
pub const H2ME_ENFORCE: u32 = 1 << 12;

pub const FEXTNVM3_PHY_CFG_COUNTER_MASK: u32 = 0x0C00_0000;
pub const FEXTNVM3_PHY_CFG_COUNTER_50MS: u32 = 0x0800_0000;
pub const FEXTNVM6_K1_OFF: u32 = 1 << 31;
pub const FEXTNVM7_DISABLE_SMB_PERST: u32 = 1 << 5;
pub const FEXTNVM11_DISABLE_MULR_FIX: u32 = 1 << 13;
pub const KABGTXD_BGSQLBIAS: u32 = 0x0005_0000;

pub const RCTL_EN: u32 = 1 << 1;
pub const RCTL_BAM: u32 = 1 << 15;
pub const RCTL_SECRC: u32 = 1 << 26;
pub const TCTL_EN: u32 = 1 << 1;
pub const TCTL_PSP: u32 = 1 << 3;
pub const TCTL_RTLC: u32 = 1 << 24;
pub const TCTL_MULR: u32 = 1 << 28;
pub const TIPG_IPGT_MASK: u32 = 0x3FF;
pub const TXDCTL_PTHRESH_MASK: u32 = 0x0000_003F;
pub const TXDCTL_WTHRESH_MASK: u32 = 0x003F_0000;
pub const TXDCTL_FULL_WRITEBACK: u32 = 0x0101_0000; // granularity 1, WTHRESH 1
pub const TXDCTL_MAX_PREFETCH: u32 = 0x0100_001F; // granularity 1, PTHRESH 31
pub const RFCTL_NFSW_DIS: u32 = 1 << 6;
pub const RFCTL_NFSR_DIS: u32 = 1 << 7;
pub const RFCTL_EXTEN: u32 = 1 << 15;
pub const PBECCSTS_ECC_ENABLE: u32 = 1 << 16;
pub const TARC0_REQUESTS_MASK: u32 = 0x3000_0000;
pub const TARC0_REQUESTS_2: u32 = 0x2000_0000;
pub const IOSFPC_RDMTS_HEX: u32 = 1 << 16;
pub const RAH_AV: u32 = 1 << 31;

/// Descriptor bits.
pub const RXD_DD: u8 = 1 << 0;
pub const TXD_DD: u8 = 1 << 0;
pub const TXD_CMD_EOP: u8 = 1 << 0;
pub const TXD_CMD_IFCS: u8 = 1 << 1;
pub const TXD_CMD_RS: u8 = 1 << 3;

// ══════════════════════════════════════════════════════════════════════════════
// PHY registers: page << 5 | register
// ══════════════════════════════════════════════════════════════════════════════

/// From this page up the PHY answers on MDIO address 1, below it on 2.
pub const PAGE_HIGH = 768;

fn phyReg(page: u32, num: u32) u32 {
    return (page << 5) | (num & 0x1F);
}

pub const P = struct {
    pub const BMCR: u32 = 0;
    pub const BMSR: u32 = 1;
    pub const ID1: u32 = 2;
    pub const ID2: u32 = 3;
    pub const EMI_ADDR: u32 = 0x10;
    pub const EMI_DATA: u32 = 0x11;
    pub const PORT_GEN_CFG: u32 = phyReg(769, 17);
    pub const SMB_CTRL: u32 = phyReg(769, 23);
    pub const PM_CTRL: u32 = phyReg(770, 17);
    pub const LPI_CTRL: u32 = phyReg(772, 20);
    pub const PLL_CLOCK_GATE: u32 = phyReg(772, 28);
    pub const POINTER_GAP: u32 = phyReg(776, 20);
    pub const ULP_CONFIG1: u32 = phyReg(779, 16);
};

pub const BMCR_RESTART_AN: u16 = 1 << 9;
pub const BMCR_AN_ENABLE: u16 = 1 << 12;
pub const BMSR_LINK: u16 = 1 << 2;
pub const PORT_GEN_HOST_WAKE: u16 = 1 << 4;
pub const SMB_CTRL_FORCE_SMBUS: u16 = 1 << 0;
pub const PM_CTRL_K1_CLK_REQ: u16 = 1 << 9;
pub const PM_CTRL_K1_ENABLE: u16 = 1 << 14;
pub const LPI_CTRL_ENABLE_MASK: u16 = 0x6000;
pub const PLL_CLOCK_GATE_MASK: u16 = 0x07FF;
pub const POINTER_GAP_MASK: u16 = 0x3FF << 2;
/// The extended (EMI) register holding the PHY's receive configuration.
pub const EMI_RX_CONFIG: u16 = 0xB20C;
/// ULP_CONFIG1: every bit that keeps the PHY in, or sends it back to, ULP.
pub const ULP_START: u16 = 1 << 0;
pub const ULP_CLEAR: u16 = (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 11) | (1 << 12);

// ══════════════════════════════════════════════════════════════════════════════
// The driver
// ══════════════════════════════════════════════════════════════════════════════

/// Descriptors in each ring, and the bytes of each buffer.
pub const N = 64;
pub const BUF = 2048;
/// What the host allocates: a ring is RING_BYTES, a ring's buffers
/// BUFFERS_BYTES, each physically contiguous.
pub const RING_BYTES = N * 16;
pub const BUFFERS_BYTES = N * BUF;

/// The driver's memory. Each address is used both by the CPU and by the
/// device (the host maps it one to one, with no IOMMU in between), and the
/// rings are aligned to 16 bytes.
pub const Memory = struct {
    rx_ring: u64,
    tx_ring: u64,
    rx_buffers: u64,
    tx_buffers: u64,
};

pub const RxDesc = extern struct { addr: u64, len: u16, csum: u16, status: u8, errors: u8, special: u16 };
pub const TxDesc = extern struct { addr: u64, len: u16, cso: u8, cmd: u8, status: u8, css: u8, special: u16 };

pub const Link = struct {
    up: bool = false,
    mbps: u16 = 0,
    full_duplex: bool = false,
};

pub const Error = error{
    /// Receive address 0 holds no usable address, before or after the reset.
    NoAddress,
};

const PhyError = error{ MdioTimeout, MdioError, Semaphore };

/// MDIC is polled every 50 us, at most this often (96 ms).
const MDIO_POLLS = 1920;

/// The driver over a host's `Io`, which gives it:
///   read32(reg: u32) u32, write32(reg: u32, value: u32) void: BAR 0;
///   delayUs(us: u32) void: a busy wait;
///   barrier() void: a full memory barrier, before the device is told of
///     descriptors the CPU just wrote;
///   note(text: []const u8, value: u32) void: one log line.
pub fn Driver(comptime Io: type) type {
    return struct {
        const Self = @This();

        io: *Io,
        fam: Family,
        mem: Memory,
        mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
        /// The Management Engine's firmware runs (FWSM): it shares the port.
        me: bool = false,
        /// The ME refuses a PHY reset: the PHY stays as the firmware set it.
        phy_reset_blocked: bool = false,
        /// The PHY answers on MDIO. When it does not, the port still runs,
        /// on the PHY's own defaults and without the per-speed tuning.
        phy_ok: bool = false,
        phy_id: u32 = 0,
        link: Link = .{},
        rx_next: u32 = 0,
        tx_next: u32 = 0,
        /// Ring tails that did not read back as written (the ME wrote at
        /// the same moment) and were written again.
        tail_rewrites: u32 = 0,
        /// This driver holds the PHY's semaphore.
        held: bool = false,

        pub fn init(io: *Io, fam: Family, mem: Memory) Self {
            return .{ .io = io, .fam = fam, .mem = mem };
        }

        // ── Registers ────────────────────────────────────────────────────

        fn r(self: *Self, reg: u32) u32 {
            return self.io.read32(reg);
        }

        /// A register write. With the ME running, it waits (at most 100 ms)
        /// while the ME's own write is in the arbiter.
        fn w(self: *Self, reg: u32, v: u32) void {
            if (self.me) {
                var i: u32 = 0;
                while (i < 2000 and self.io.read32(R.FWSM) & FWSM_PCIM2PCI != 0) : (i += 1) self.io.delayUs(50);
            }
            self.io.write32(reg, v);
        }

        /// A ring's tail: read back when the ME shares the port.
        fn tail(self: *Self, reg: u32, v: u32) void {
            self.w(reg, v);
            if (!self.me or self.r(reg) == v) return;
            self.tail_rewrites += 1;
            self.w(reg, v);
        }

        // ── The PHY ──────────────────────────────────────────────────────

        /// The software's hold on the PHY and NVM (EXTCNF_CTRL's flag): the
        /// ME and the hardware's own configuration take turns with it.
        fn acquire(self: *Self) PhyError!void {
            if (self.held) return;
            // (someone else's hold is waited for, never taken away)
            var ms: u32 = 0;
            while (self.r(R.EXTCNF_CTRL) & EXTCNF_SWFLAG != 0) : (ms += 1) {
                if (ms == 100) return error.Semaphore;
                self.io.delayUs(1000);
            }
            self.w(R.EXTCNF_CTRL, self.r(R.EXTCNF_CTRL) | EXTCNF_SWFLAG);
            ms = 0;
            while (self.r(R.EXTCNF_CTRL) & EXTCNF_SWFLAG == 0) : (ms += 1) {
                if (ms == 1000) {
                    self.w(R.EXTCNF_CTRL, self.r(R.EXTCNF_CTRL) & ~EXTCNF_SWFLAG);
                    return error.Semaphore;
                }
                self.io.delayUs(1000);
            }
            self.held = true;
        }

        /// Gives the hold back, if this driver has it.
        fn release(self: *Self) void {
            if (!self.held) return;
            self.held = false;
            const v = self.r(R.EXTCNF_CTRL);
            if (v & EXTCNF_SWFLAG != 0) self.w(R.EXTCNF_CTRL, v & ~EXTCNF_SWFLAG);
        }

        fn worked(result: PhyError!void) bool {
            result catch return false;
            return true;
        }

        /// One MDIO transaction through MDIC.
        fn mdio(self: *Self, addr: u32, num: u32, write: ?u16) PhyError!u16 {
            var cmd: u32 = (num << 16) | (addr << 21);
            if (write) |v| {
                cmd |= MDIC_OP_WRITE | v;
            } else {
                cmd |= MDIC_OP_READ;
            }
            self.w(R.MDIC, cmd);
            var i: u32 = 0;
            while (i < MDIO_POLLS) : (i += 1) {
                self.io.delayUs(50);
                const v = self.r(R.MDIC);
                if (v & MDIC_READY == 0) continue;
                if (v & MDIC_ERROR != 0) return error.MdioError;
                return @as(u16, @truncate(v));
            }
            return error.MdioTimeout;
        }

        /// A paged PHY register (the semaphore held): the address by its
        /// page, and the page written first for registers above 15.
        fn phy(self: *Self, off: u32, write: ?u16) PhyError!u16 {
            var page = off >> 5;
            const num = off & 0x1F;
            const addr: u32 = if (page >= PAGE_HIGH) 1 else 2;
            if (page == PAGE_HIGH) page = 0;
            if (num > 0xF) _ = try self.mdio(1, 31, @as(u16, @intCast(page << 5)));
            return self.mdio(addr, num, write);
        }

        fn phyRead(self: *Self, off: u32) PhyError!u16 {
            return self.phy(off, null);
        }

        fn phyWrite(self: *Self, off: u32, v: u16) PhyError!void {
            _ = try self.phy(off, v);
        }

        /// The PHY's id read twice at most; with no ME, a PHY found on SMBus
        /// is put back on the PCIe link, and the MAC with it.
        fn phyAnswers(self: *Self) bool {
            var tries: u32 = 0;
            while (tries < 2) : (tries += 1) {
                const id1 = self.phyRead(P.ID1) catch continue;
                if (id1 == 0xFFFF or id1 == 0) continue;
                const id2 = self.phyRead(P.ID2) catch continue;
                self.phy_id = (@as(u32, id1) << 16) | (id2 & 0xFFF0);
                if (!self.me) {
                    if (self.phyRead(P.SMB_CTRL)) |smb| {
                        self.phyWrite(P.SMB_CTRL, smb & ~SMB_CTRL_FORCE_SMBUS) catch {};
                    } else |_| {}
                    self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) & ~CTRL_EXT_FORCE_SMBUS);
                }
                return true;
            }
            return false;
        }

        /// The PHY's power cycled through LANPHYPC: it comes back on the
        /// PCIe link, out of ULP, with its configuration loading for 50 ms.
        fn cyclePhyPower(self: *Self) void {
            self.w(R.FEXTNVM3, (self.r(R.FEXTNVM3) & ~FEXTNVM3_PHY_CFG_COUNTER_MASK) | FEXTNVM3_PHY_CFG_COUNTER_50MS);
            var c = self.r(R.CTRL);
            c |= CTRL_LANPHYPC_OVERRIDE;
            c &= ~CTRL_LANPHYPC_VALUE;
            self.w(R.CTRL, c);
            _ = self.r(R.STATUS);
            self.io.delayUs(1000);
            self.w(R.CTRL, c & ~CTRL_LANPHYPC_OVERRIDE);
            _ = self.r(R.STATUS);
            var count: u32 = 0;
            while (count <= 20) : (count += 1) {
                self.io.delayUs(5000);
                if (self.r(R.CTRL_EXT) & CTRL_EXT_LPCD != 0) break;
            }
            self.io.delayUs(30_000);
        }

        /// Whether the ME refuses a PHY reset (asked for 300 ms).
        fn resetBlocked(self: *Self) bool {
            var i: u32 = 0;
            while (i <= 30) : (i += 1) {
                if (self.r(R.FWSM) & FWSM_RSPCIPHY != 0) return false;
                self.io.delayUs(10_000);
            }
            return true;
        }

        /// After a PHY reset: the hardware loads the PHY's configuration
        /// (LAN_INIT_DONE, at most 150 ms), and both marks are cleared.
        fn configDone(self: *Self) void {
            self.io.delayUs(10_000);
            var i: u32 = 0;
            while (i < 1500 and self.r(R.STATUS) & STATUS_LAN_INIT_DONE == 0) : (i += 1) self.io.delayUs(100);
            if (i == 1500) self.io.note("the PHY's configuration did not finish (STATUS)", self.r(R.STATUS));
            self.w(R.STATUS, self.r(R.STATUS) & ~STATUS_LAN_INIT_DONE);
            const st = self.r(R.STATUS);
            if (st & STATUS_PHYRA != 0) self.w(R.STATUS, st & ~STATUS_PHYRA);
        }

        /// The PHY alone reset (not when the ME refuses it, nor without the
        /// semaphore).
        fn resetPhy(self: *Self) void {
            if (self.phy_reset_blocked) return;
            self.acquire() catch return;
            const c = self.r(R.CTRL);
            self.w(R.CTRL, c | CTRL_PHY_RST);
            _ = self.r(R.STATUS);
            self.io.delayUs(100);
            self.w(R.CTRL, c);
            _ = self.r(R.STATUS);
            self.io.delayUs(300);
            self.release();
            self.configDone();
        }

        /// Out of Ultra Low Power, however the last system left the PHY.
        fn leaveUlp(self: *Self) void {
            if (self.me) {
                // The ME owns ULP: it is asked to undo it, and given 2.5 s.
                self.w(R.H2ME, (self.r(R.H2ME) & ~H2ME_ULP) | H2ME_ENFORCE);
                var i: u32 = 0;
                while (i < 250 and self.r(R.FWSM) & FWSM_ULP_CFG_DONE != 0) : (i += 1) self.io.delayUs(10_000);
                if (i == 250) self.io.note("the ME did not take the PHY out of ULP (FWSM)", self.r(R.FWSM));
                self.w(R.H2ME, self.r(R.H2ME) & ~H2ME_ENFORCE);
                return;
            }
            self.undoUlp() catch |e| self.io.note(if (e == error.Semaphore) "ULP: the PHY's semaphore is held" else "ULP: the PHY did not answer", self.r(R.CTRL_EXT));
            self.release();
            self.resetPhy();
            self.io.delayUs(50_000);
        }

        fn undoUlp(self: *Self) PhyError!void {
            try self.acquire();
            self.cyclePhyPower();
            const smb = self.phyRead(P.SMB_CTRL) catch blk: {
                // (the MAC may be on the PCIe link while the PHY is on SMBus)
                self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) | CTRL_EXT_FORCE_SMBUS);
                self.io.delayUs(50_000);
                break :blk try self.phyRead(P.SMB_CTRL);
            };
            try self.phyWrite(P.SMB_CTRL, smb & ~SMB_CTRL_FORCE_SMBUS);
            self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) & ~CTRL_EXT_FORCE_SMBUS);
            // (ULP switched K1 off in the PHY)
            try self.phyWrite(P.PM_CTRL, (try self.phyRead(P.PM_CTRL)) | PM_CTRL_K1_ENABLE);
            const ulp = (try self.phyRead(P.ULP_CONFIG1)) & ~ULP_CLEAR;
            try self.phyWrite(P.ULP_CONFIG1, ulp);
            try self.phyWrite(P.ULP_CONFIG1, ulp | ULP_START);
            self.w(R.FEXTNVM7, self.r(R.FEXTNVM7) & ~FEXTNVM7_DISABLE_SMB_PERST);
        }

        /// The PHY found: as it is, with the MAC forced to SMBus, after a
        /// power cycle, and after a power cycle with the MAC back on PCIe.
        fn reachPhy(self: *Self) PhyError!void {
            try self.acquire();
            defer self.release();
            if (self.phyAnswers()) return;
            self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) | CTRL_EXT_FORCE_SMBUS);
            self.io.delayUs(50_000);
            if (self.phyAnswers()) return;
            if (self.phy_reset_blocked) return error.MdioError;
            self.cyclePhyPower();
            if (self.phyAnswers()) return;
            self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) & ~CTRL_EXT_FORCE_SMBUS);
            if (self.phyAnswers()) return;
            return error.MdioError;
        }

        // ── Bring-up ─────────────────────────────────────────────────────

        /// The port from whatever state it was left in to receiving and
        /// sending, its link negotiating. Takes up to a few seconds when
        /// the PHY has to be woken. Only a missing address fails it.
        pub fn bringUp(self: *Self) Error!void {
            const fwsm = self.r(R.FWSM);
            self.me = fwsm & FWSM_FW_VALID != 0;
            self.io.note(if (self.me) "the ME shares this port (FWSM)" else "no ME firmware on this port (FWSM)", fwsm);
            const saved_lo = self.r(R.RAL0);
            const saved_hi = self.r(R.RAH0);

            // Quiet: no interrupts, receiver and transmitter off.
            self.w(R.IMC, 0xFFFF_FFFF);
            self.w(R.RCTL, 0);
            self.w(R.TCTL, TCTL_PSP);
            _ = self.r(R.STATUS);
            self.io.delayUs(10_000);
            const left = self.r(R.TDLEN);
            if (left != 0) self.io.note("a transmit ring was left in place (TDLEN)", left);
            self.w(R.FEXTNVM11, self.r(R.FEXTNVM11) | FEXTNVM11_DISABLE_MULR_FIX);

            // The PHY: the hardware's own configuration gated, out of ULP,
            // found, and reset when the ME allows.
            self.w(R.EXTCNF_CTRL, self.r(R.EXTCNF_CTRL) | EXTCNF_GATE_PHY_CFG);
            self.phy_reset_blocked = self.resetBlocked();
            self.leaveUlp();
            // (asked again once the ME has undone ULP: its answer can change)
            if (self.me) self.phy_reset_blocked = self.resetBlocked();
            if (self.phy_reset_blocked) self.io.note("the ME refuses a PHY reset (FWSM)", self.r(R.FWSM));
            self.phy_ok = worked(self.reachPhy());
            if (self.phy_ok) self.resetPhy();

            // The MAC, and the PHY with it: their link to each other is
            // only reset when both are.
            var c = self.r(R.CTRL);
            if (!self.phy_reset_blocked) c |= CTRL_PHY_RST;
            self.acquire() catch {};
            self.w(R.CTRL, c | CTRL_RST);
            // (no register is read for 20 ms: a read here can hang the MAC;
            // the reset itself drops the semaphore)
            self.io.delayUs(20_000);
            self.held = false;
            if (c & CTRL_PHY_RST != 0) {
                self.configDone();
                self.io.delayUs(10_000);
            }
            self.w(R.IMC, 0xFFFF_FFFF);
            _ = self.r(R.ICR);
            self.w(R.KABGTXD, self.r(R.KABGTXD) | KABGTXD_BGSQLBIAS);

            // The PHY again, now that both are reset.
            self.phy_ok = worked(self.reachPhy());
            if (self.phy_ok) {
                self.io.note("PHY id", self.phy_id);
                self.afterPhyReset() catch {};
                self.release();
            } else {
                self.io.note("the PHY does not answer: going on with its defaults (CTRL_EXT)", self.r(R.CTRL_EXT));
            }

            // The address the firmware loaded into receive address 0.
            var lo = self.r(R.RAL0);
            var hi = self.r(R.RAH0) & 0xFFFF;
            if (!usable(lo, hi)) {
                lo = saved_lo;
                hi = saved_hi & 0xFFFF;
            }
            if (!usable(lo, hi)) return error.NoAddress;
            self.mac = .{ @truncate(lo), @truncate(lo >> 8), @truncate(lo >> 16), @truncate(lo >> 24), @truncate(hi), @truncate(hi >> 8) };
            self.w(R.RAL0, lo);
            self.w(R.RAH0, hi | RAH_AV);
            for (0..32) |i| self.w(R.MTA + @as(u32, @intCast(i)) * 4, 0);

            self.setBits();
            self.startLink();
            self.setRings();

            // Receiver on: this address and broadcast, 2 KiB buffers, the
            // CRC stripped. Transmitter on: short frames padded, late
            // collisions sent again, 15 tries, a 63-byte collision distance.
            self.w(R.RCTL, RCTL_EN | RCTL_BAM | RCTL_SECRC);
            self.w(R.TCTL, TCTL_EN | TCTL_PSP | TCTL_RTLC | (15 << 4) | (63 << 12));
            self.link = .{};
        }

        fn usable(lo: u32, hi: u32) bool {
            if (lo == 0 and hi == 0) return false;
            if (lo == 0xFFFF_FFFF and hi == 0xFFFF) return false;
            return lo & 1 == 0; // (not a group address)
        }

        /// After a PHY reset (the semaphore taken here, released by the
        /// caller): the host wake bit off, which otherwise stalls receive
        /// while the ME also wakes on this port; no low power idle.
        fn afterPhyReset(self: *Self) PhyError!void {
            try self.acquire();
            const gen = try self.phyRead(P.PORT_GEN_CFG);
            try self.phyWrite(P.PORT_GEN_CFG, gen & ~PORT_GEN_HOST_WAKE);
            const lpi = try self.phyRead(P.LPI_CTRL);
            try self.phyWrite(P.LPI_CTRL, lpi & ~LPI_CTRL_ENABLE_MASK);
        }

        /// The MAC's fixed settings for a PCH port.
        fn setBits(self: *Self) void {
            self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) | CTRL_EXT_DMA_GATING | CTRL_EXT_PHYPDEN);
            self.w(R.TXDCTL0, self.r(R.TXDCTL0) | (1 << 22));
            self.w(R.TXDCTL1, self.r(R.TXDCTL1) | (1 << 22));
            self.w(R.TARC0, self.r(R.TARC0) | (1 << 23) | (1 << 24) | (1 << 26) | (1 << 27));
            var t1 = self.r(R.TARC1);
            if (self.r(R.TCTL) & TCTL_MULR != 0) t1 &= ~@as(u32, 1 << 28) else t1 |= 1 << 28;
            self.w(R.TARC1, t1 | (1 << 24) | (1 << 26) | (1 << 30));
            // Legacy receive descriptors; no NFS filtering (it corrupts
            // descriptors under some UDP traffic).
            self.w(R.RFCTL, (self.r(R.RFCTL) | RFCTL_NFSW_DIS | RFCTL_NFSR_DIS) & ~RFCTL_EXTEN);
            // The packet buffer's ECC, and a halt on an error it cannot fix.
            self.w(R.PBECCSTS, self.r(R.PBECCSTS) | PBECCSTS_ECC_ENABLE);
            self.w(R.CTRL, self.r(R.CTRL) | CTRL_MEHE);
            // Descriptors written back one at a time, 31 prefetched.
            for ([_]u32{ R.TXDCTL0, R.TXDCTL1 }) |reg| {
                const v = self.r(reg) & ~(TXDCTL_PTHRESH_MASK | TXDCTL_WTHRESH_MASK);
                self.w(reg, v | TXDCTL_FULL_WRITEBACK | TXDCTL_MAX_PREFETCH);
            }
            self.w(R.CTRL_EXT, self.r(R.CTRL_EXT) | CTRL_EXT_RO_DIS);
            if (self.fam == .spt) {
                // Sunrise Point errata: fewer outstanding transmit requests
                // (a buffer overrun hangs transmit), and the receive
                // threshold that avoids corrupted data.
                self.w(R.IOSFPC, self.r(R.IOSFPC) | IOSFPC_RDMTS_HEX);
                self.w(R.TARC0, (self.r(R.TARC0) & ~TARC0_REQUESTS_MASK) | TARC0_REQUESTS_2);
            }
        }

        /// The link set going: the MAC follows the PHY's speed and duplex,
        /// and the PHY negotiates again from its defaults (10/100/1000).
        fn startLink(self: *Self) void {
            self.w(R.CTRL, (self.r(R.CTRL) | CTRL_SLU) & ~(CTRL_FRCSPD | CTRL_FRCDPX));
            if (!self.phy_ok) return;
            self.acquire() catch return;
            defer self.release();
            const bmcr = self.phyRead(P.BMCR) catch return;
            self.phyWrite(P.BMCR, bmcr | BMCR_AN_ENABLE | BMCR_RESTART_AN) catch {};
        }

        fn setRings(self: *Self) void {
            const rx: *[N]RxDesc = @ptrFromInt(self.mem.rx_ring);
            const tx: *[N]TxDesc = @ptrFromInt(self.mem.tx_ring);
            for (0..N) |i| {
                rx[i] = .{ .addr = self.mem.rx_buffers + @as(u64, i) * BUF, .len = 0, .csum = 0, .status = 0, .errors = 0, .special = 0 };
                tx[i] = .{ .addr = self.mem.tx_buffers + @as(u64, i) * BUF, .len = 0, .cso = 0, .cmd = 0, .status = TXD_DD, .css = 0, .special = 0 };
            }
            self.io.barrier();
            self.w(R.RDBAL, @truncate(self.mem.rx_ring));
            self.w(R.RDBAH, @truncate(self.mem.rx_ring >> 32));
            self.w(R.RDLEN, RING_BYTES);
            self.w(R.RDH, 0);
            self.w(R.RDT, N - 1);
            self.w(R.TDBAL, @truncate(self.mem.tx_ring));
            self.w(R.TDBAH, @truncate(self.mem.tx_ring >> 32));
            self.w(R.TDLEN, RING_BYTES);
            self.w(R.TDH, 0);
            self.w(R.TDT, 0);
            self.rx_next = 0;
            self.tx_next = 0;
        }

        // ── The link ─────────────────────────────────────────────────────

        /// The link as it is now. Cheap while nothing changes (one register
        /// read); when the link comes up, the PHY is asked too and the MAC
        /// and PHY are tuned to the speed, which takes a few milliseconds.
        pub fn poll(self: *Self) Link {
            const st = self.r(R.STATUS);
            const lu = st & STATUS_LU != 0;
            if (self.link.up) {
                if (!lu) self.link = .{};
                return self.link;
            }
            if (!lu) return self.link;
            const l: Link = .{
                .up = true,
                .full_duplex = st & STATUS_FD != 0,
                .mbps = switch ((st >> STATUS_SPEED_SHIFT) & 3) {
                    0 => 10,
                    1 => 100,
                    else => 1000,
                },
            };
            if (self.phy_ok) {
                if (!self.phyHasLink()) return self.link;
                self.tune(l);
            }
            self.link = l;
            return l;
        }

        /// The PHY's own word (its link bit latches low: the second read is
        /// the link now).
        fn phyHasLink(self: *Self) bool {
            self.acquire() catch return false;
            defer self.release();
            _ = self.phyRead(P.BMSR) catch return false;
            const bmsr = self.phyRead(P.BMSR) catch return false;
            return bmsr & BMSR_LINK != 0;
        }

        /// The MAC and the PHY set for the link's speed and duplex.
        fn tune(self: *Self, l: Link) void {
            // The inter-packet gap: wide at 10 Mb/s half duplex (the part
            // is too eager and collides), 12 at 10/100 full, 8 otherwise.
            var tipg = self.r(R.TIPG) & ~TIPG_IPGT_MASK;
            var rx_config: u16 = 1;
            if (!l.full_duplex and l.mbps == 10) {
                tipg |= 0xFF;
                rx_config = 0; // (and less receive latency in the PHY)
            } else if (l.full_duplex and l.mbps != 1000) {
                tipg |= 0x0C;
            } else {
                tipg |= 0x08;
            }
            self.w(R.TIPG, tipg);
            self.tunePhy(l, rx_config) catch {};
            self.release();
            if (self.fam == .spt) {
                // Sunrise Point: K1 off as the analog configuration says.
                var f6 = self.r(R.FEXTNVM6) & ~FEXTNVM6_K1_OFF;
                if (self.r(R.PCIEANACFG) & FEXTNVM6_K1_OFF != 0) f6 |= FEXTNVM6_K1_OFF;
                self.w(R.FEXTNVM6, f6);
            }
        }

        fn tunePhy(self: *Self, l: Link, rx_config: u16) PhyError!void {
            try self.acquire();
            try self.phyWrite(P.EMI_ADDR, EMI_RX_CONFIG);
            try self.phyWrite(P.EMI_DATA, rx_config);
            const gate = (try self.phyRead(P.PLL_CLOCK_GATE)) & ~PLL_CLOCK_GATE_MASK;
            try self.phyWrite(P.PLL_CLOCK_GATE, gate | @as(u16, if (l.mbps == 1000) 0xFA else 0x3E8));
            if (l.mbps == 1000) {
                try self.phyWrite(P.PM_CTRL, (try self.phyRead(P.PM_CTRL)) | PM_CTRL_K1_CLK_REQ);
                // (the receive pointer gap: at least 0x18 at 1000 Mb/s)
                const gap = try self.phyRead(P.POINTER_GAP);
                if ((gap & POINTER_GAP_MASK) >> 2 < 0x18) try self.phyWrite(P.POINTER_GAP, (gap & ~POINTER_GAP_MASK) | (0x18 << 2));
            } else {
                try self.phyWrite(P.POINTER_GAP, 0xC023);
            }
        }

        // ── Frames ───────────────────────────────────────────────────────

        /// One frame to the wire (without its CRC, which the MAC adds).
        /// False when the ring is full: its next slot, or the one after,
        /// is still being sent. One slot always stays free, so the tail
        /// never catches the head (to the MAC an equal head and tail is an
        /// empty ring, and N frames waiting would never leave).
        pub fn send(self: *Self, frame: []const u8) bool {
            if (frame.len == 0 or frame.len > BUF) return false;
            const tx: *[N]TxDesc = @ptrFromInt(self.mem.tx_ring);
            const d = &tx[self.tx_next];
            const after = &tx[(self.tx_next + 1) % N];
            if (@atomicLoad(u8, &d.status, .acquire) & TXD_DD == 0) return false;
            if (@atomicLoad(u8, &after.status, .acquire) & TXD_DD == 0) return false;
            const buf: [*]u8 = @ptrFromInt(self.mem.tx_buffers + @as(u64, self.tx_next) * BUF);
            @memcpy(buf[0..frame.len], frame);
            d.len = @intCast(frame.len);
            d.status = 0;
            d.cmd = TXD_CMD_EOP | TXD_CMD_IFCS | TXD_CMD_RS;
            self.io.barrier();
            self.tx_next = (self.tx_next + 1) % N;
            self.tail(R.TDT, self.tx_next);
            return true;
        }

        /// The next received frame into `out` (cut to its length), or null
        /// when there is none. The slot goes back to the MAC.
        pub fn recv(self: *Self, out: []u8) ?usize {
            const rx: *[N]RxDesc = @ptrFromInt(self.mem.rx_ring);
            const d = &rx[self.rx_next];
            if (@atomicLoad(u8, &d.status, .acquire) & RXD_DD == 0) return null;
            const n: usize = @min(d.len, out.len);
            const buf: [*]const u8 = @ptrFromInt(self.mem.rx_buffers + @as(u64, self.rx_next) * BUF);
            @memcpy(out[0..n], buf[0..n]);
            d.status = 0;
            self.io.barrier();
            self.tail(R.RDT, self.rx_next);
            self.rx_next = (self.rx_next + 1) % N;
            return n;
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// The model: the PCH's MAC and an I219 PHY at register level (tests only)
// ══════════════════════════════════════════════════════════════════════════════

const Model = struct {
    regs: [0x6000 / 4]u32 = [_]u32{0} ** (0x6000 / 4),
    time_us: u64 = 0,

    // The machine.
    nvm_mac: [6]u8 = .{ 0x18, 0xC0, 0x4D, 0x12, 0x34, 0x56 },
    /// The ME's firmware runs.
    me: bool = false,
    /// The ME lets the PHY be reset.
    reset_allowed: bool = true,
    /// Reads of FWSM that still show the ME's write in the arbiter.
    arbiter_busy: u32 = 0,
    /// Something else holds the PHY's semaphore.
    flag_taken: bool = false,
    /// Writes of the transmit tail that will be lost.
    lose_tail_writes: u32 = 0,

    // The PHY.
    pages: [PAGES.len][32]u16 = [_][32]u16{[_]u16{0} ** 32} ** PAGES.len,
    page: u32 = 0,
    /// It listens on SMBus, not on the PCIe link.
    phy_smbus: bool = false,
    /// It is in Ultra Low Power: silent until its power is cycled or the ME
    /// takes it out.
    ulp: bool = false,
    /// It is silent until its power is cycled.
    wedged: bool = false,
    /// It never answers.
    dead: bool = false,
    link_mbps: u16 = 0,
    link_full: bool = true,

    // What happened.
    mac_resets: u32 = 0,
    phy_resets: u32 = 0,
    phy_reset_writes: u32 = 0,
    power_cycles: u32 = 0,
    arbiter_violations: u32 = 0,
    wrong_address: u32 = 0,
    armed: bool = false,
    tx_stalled: bool = false,
    sent: [4][64]u8 = undefined,
    sent_len: [4]usize = .{ 0, 0, 0, 0 },
    sent_count: usize = 0,
    notes: u32 = 0,

    const PAGES = [_]u32{ 0, 769, 770, 772, 776, 779 };

    fn pageIndex(page: u32) ?usize {
        for (PAGES, 0..) |p, i| if (p == page) return i;
        return null;
    }

    fn start(self: *Model) void {
        self.loadMacDefaults();
        self.loadPhyDefaults();
    }

    fn loadMacDefaults(self: *Model) void {
        @memset(&self.regs, 0);
        self.regs[R.TIPG / 4] = 0x0060_2008;
        const m = self.nvm_mac;
        self.regs[R.RAL0 / 4] = @as(u32, m[0]) | @as(u32, m[1]) << 8 | @as(u32, m[2]) << 16 | @as(u32, m[3]) << 24;
        self.regs[R.RAH0 / 4] = @as(u32, m[4]) | @as(u32, m[5]) << 8 | RAH_AV;
    }

    fn loadPhyDefaults(self: *Model) void {
        for (&self.pages) |*p| @memset(p, 0);
        self.pages[0][P.BMCR] = 0x1140;
        self.pages[0][P.ID1] = 0x0154;
        self.pages[0][P.ID2] = 0x10A3;
        self.pages[pageIndex(769).?][17] = PORT_GEN_HOST_WAKE | 0x0004;
        self.pages[pageIndex(772).?][20] = LPI_CTRL_ENABLE_MASK | 0x0100;
        self.pages[pageIndex(772).?][28] = 0x0123;
        self.pages[pageIndex(776).?][20] = (0x10 << 2) | 0x3;
        self.page = 0;
    }

    fn phyListens(self: *const Model) bool {
        if (self.dead or self.ulp or self.wedged) return false;
        const mac_smbus = self.regs[R.CTRL_EXT / 4] & CTRL_EXT_FORCE_SMBUS != 0;
        return mac_smbus == self.phy_smbus;
    }

    fn resetPhy(self: *Model) void {
        self.phy_reset_writes += 1;
        if (!self.reset_allowed) return;
        self.phy_resets += 1;
        self.loadPhyDefaults();
        self.phy_smbus = false;
        self.regs[R.STATUS / 4] |= STATUS_LAN_INIT_DONE | STATUS_PHYRA;
    }

    fn cyclePower(self: *Model) void {
        self.power_cycles += 1;
        self.loadPhyDefaults();
        self.phy_smbus = false;
        self.ulp = false;
        self.wedged = false;
        self.regs[R.CTRL_EXT / 4] |= CTRL_EXT_LPCD;
    }

    fn mdio(self: *Model, cmd: u32) u32 {
        if (self.dead) return cmd & ~MDIC_READY; // (never ready)
        const num = (cmd >> 16) & 0x1F;
        const addr = (cmd >> 21) & 0x1F;
        const is_write = cmd & MDIC_OP_WRITE != 0;
        var data: u16 = @truncate(cmd);
        var ok = self.phyListens();
        if (ok) {
            if (addr == 1 and num == 31) {
                if (is_write) self.page = data >> 5 else data = @intCast(self.page << 5);
            } else if (num <= 0xF) {
                // (the IEEE registers: the same on every page, address 2)
                if (addr != 2) {
                    self.wrong_address += 1;
                    ok = false;
                } else if (is_write) {
                    self.pages[0][num] = if (num == P.BMCR) data & ~BMCR_RESTART_AN else data;
                } else {
                    data = self.pages[0][num];
                    if (num == P.BMSR) data = if (self.link_mbps != 0) BMSR_LINK | 0x0020 else 0;
                }
            } else {
                const want: u32 = if (self.page >= PAGE_HIGH) 1 else 2;
                const idx = pageIndex(self.page);
                if (addr != want or idx == null) {
                    self.wrong_address += 1;
                    ok = false;
                } else if (is_write) {
                    self.pages[idx.?][num] = data;
                    if (self.page == 769 and num == 23) self.phy_smbus = data & SMB_CTRL_FORCE_SMBUS != 0;
                } else {
                    data = self.pages[idx.?][num];
                    if (self.page == 769 and num == 23) data = if (self.phy_smbus) SMB_CTRL_FORCE_SMBUS else 0;
                }
            }
        }
        return (cmd & 0xFFFF_0000) | data | MDIC_READY | (if (ok) @as(u32, 0) else MDIC_ERROR);
    }

    fn transmit(self: *Model, tdt: u32) void {
        const ring: [*]TxDesc = @ptrFromInt(@as(u64, self.regs[R.TDBAH / 4]) << 32 | self.regs[R.TDBAL / 4]);
        const count = self.regs[R.TDLEN / 4] / 16;
        var head = self.regs[R.TDH / 4];
        while (head != tdt) {
            if (self.tx_stalled or self.regs[R.TCTL / 4] & TCTL_EN == 0) break;
            const d = &ring[head];
            if (self.sent_count < self.sent.len) {
                const n = @min(d.len, self.sent[0].len);
                const from: [*]const u8 = @ptrFromInt(d.addr);
                @memcpy(self.sent[self.sent_count][0..n], from[0..n]);
                self.sent_len[self.sent_count] = d.len;
            }
            self.sent_count += 1;
            d.status = TXD_DD;
            head = (head + 1) % count;
        }
        self.regs[R.TDH / 4] = head;
    }

    /// A frame from the wire: into the next free receive descriptor.
    fn deliver(self: *Model, frame: []const u8) bool {
        if (self.regs[R.RCTL / 4] & RCTL_EN == 0) return false;
        const ring: [*]RxDesc = @ptrFromInt(@as(u64, self.regs[R.RDBAH / 4]) << 32 | self.regs[R.RDBAL / 4]);
        const count = self.regs[R.RDLEN / 4] / 16;
        const head = self.regs[R.RDH / 4];
        if (head == self.regs[R.RDT / 4]) return false; // (no free descriptor)
        const d = &ring[head];
        const to: [*]u8 = @ptrFromInt(d.addr);
        @memcpy(to[0..frame.len], frame);
        d.len = @intCast(frame.len);
        d.status = RXD_DD | 0x02;
        self.regs[R.RDH / 4] = (head + 1) % count;
        return true;
    }

    // ── Io ──

    pub fn read32(self: *Model, reg: u32) u32 {
        switch (reg) {
            R.STATUS => {
                var v = self.regs[reg / 4];
                if (self.link_mbps != 0 and self.regs[R.CTRL / 4] & CTRL_SLU != 0 and !self.ulp and !self.dead) {
                    v |= STATUS_LU;
                    if (self.link_full) v |= STATUS_FD;
                    v |= @as(u32, switch (self.link_mbps) {
                        10 => 0,
                        100 => 1,
                        else => 2,
                    }) << STATUS_SPEED_SHIFT;
                }
                return v;
            },
            R.FWSM => {
                var v: u32 = 0;
                if (self.me) v |= FWSM_FW_VALID;
                if (self.reset_allowed) v |= FWSM_RSPCIPHY;
                if (self.me and self.ulp) v |= FWSM_ULP_CFG_DONE;
                if (self.arbiter_busy != 0) {
                    self.arbiter_busy -= 1;
                    v |= FWSM_PCIM2PCI;
                }
                return v;
            },
            else => return self.regs[reg / 4],
        }
    }

    pub fn write32(self: *Model, reg: u32, v: u32) void {
        if (self.arbiter_busy != 0) self.arbiter_violations += 1;
        switch (reg) {
            R.CTRL => {
                if (v & CTRL_RST != 0) {
                    self.mac_resets += 1;
                    self.loadMacDefaults();
                    if (v & CTRL_PHY_RST != 0) self.resetPhy();
                    return;
                }
                if (v & CTRL_PHY_RST != 0 and self.regs[reg / 4] & CTRL_PHY_RST == 0) self.resetPhy();
                if (v & CTRL_LANPHYPC_OVERRIDE != 0 and v & CTRL_LANPHYPC_VALUE == 0) {
                    self.armed = true;
                } else if (self.armed and v & CTRL_LANPHYPC_OVERRIDE == 0) {
                    self.armed = false;
                    self.cyclePower();
                }
                self.regs[reg / 4] = v;
            },
            R.MDIC => self.regs[reg / 4] = self.mdio(v),
            R.EXTCNF_CTRL => {
                // (the flag is only granted when nothing else holds it)
                self.regs[reg / 4] = if (self.flag_taken) v & ~EXTCNF_SWFLAG else v;
            },
            R.H2ME => {
                self.regs[reg / 4] = v;
                // (the ME takes the PHY out of ULP when told to enforce "no ULP")
                if (self.me and v & H2ME_ENFORCE != 0 and v & H2ME_ULP == 0) self.ulp = false;
            },
            R.TDT => {
                // (the ME's own write can win the arbiter: this one is lost)
                if (self.lose_tail_writes != 0) {
                    self.lose_tail_writes -= 1;
                    return;
                }
                self.regs[reg / 4] = v;
                self.transmit(v);
            },
            else => self.regs[reg / 4] = v,
        }
    }

    pub fn delayUs(self: *Model, us: u32) void {
        self.time_us += us;
    }

    pub fn barrier(_: *Model) void {}

    pub fn note(self: *Model, _: []const u8, _: u32) void {
        self.notes += 1;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

const Nic = Driver(Model);

/// A test's machine: the model and the driver's memory, static (the buffers
/// are a quarter of a megabyte).
const Bench = struct {
    var model: Model = .{};
    var rx_ring: [N]RxDesc = undefined;
    var tx_ring: [N]TxDesc = undefined;
    var rx_buffers: [BUFFERS_BYTES]u8 = undefined;
    var tx_buffers: [BUFFERS_BYTES]u8 = undefined;

    fn fresh() *Model {
        model = .{};
        model.start();
        return &model;
    }

    fn nic(fam: Family) Nic {
        return Nic.init(&model, fam, .{
            .rx_ring = @intFromPtr(&rx_ring),
            .tx_ring = @intFromPtr(&tx_ring),
            .rx_buffers = @intFromPtr(&rx_buffers),
            .tx_buffers = @intFromPtr(&tx_buffers),
        });
    }
};

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

test "i219: the device ids, by family" {
    try expect(family(0x15BC) == .cnp); // I219-V (7): the Z390's
    try expect(family(0x15BB) == .cnp);
    try expect(family(0x0D4F) == .cnp);
    try expect(family(0x1570) == .spt);
    try expect(family(0x0D55) == .spt);
    try expect(family(0x10D3) == null); // (an 82574L: e1000's)
    try expect(family(0x15FC) == null); // (Tiger Lake: not claimed)
}

test "i219: PHY registers by page and address" {
    try expect(P.SMB_CTRL == (769 << 5) + 23);
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    // A register above 15 on a high page: the page to address 1, then the
    // register on address 1.
    try n.phyWrite(P.PLL_CLOCK_GATE, 0x0456);
    try expect(m.page == 772);
    try expect(m.pages[Model.pageIndex(772).?][28] == 0x0456);
    try expect((try n.phyRead(P.PLL_CLOCK_GATE)) == 0x0456);
    // The extended register pair: page 0, address 2.
    try n.phyWrite(P.EMI_ADDR, EMI_RX_CONFIG);
    try expect(m.page == 0);
    try expect(m.pages[0][0x10] == EMI_RX_CONFIG);
    // An IEEE register: no page written, address 2.
    try n.phyWrite(P.PM_CTRL, 0x0001);
    try expect((try n.phyRead(P.ID1)) == 0x0154);
    try expect(m.page == 770);
    try expect(m.wrong_address == 0);
}

test "i219: bring-up from a clean port" {
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(n.phy_ok and !n.me and !n.phy_reset_blocked);
    try expect(n.phy_id == 0x015410A0);
    try expect(m.mac_resets == 1);
    try expect(m.wrong_address == 0);
    // The address, valid in receive address 0.
    try expect(n.mac[0] == 0x18 and n.mac[5] == 0x56);
    try expect(m.regs[R.RAH0 / 4] & RAH_AV != 0);
    // Polled, both directions on, legacy descriptors.
    try expect(m.regs[R.IMC / 4] == 0xFFFF_FFFF);
    try expect(m.regs[R.RCTL / 4] == RCTL_EN | RCTL_BAM | RCTL_SECRC);
    try expect(m.regs[R.TCTL / 4] & TCTL_EN != 0);
    try expect(m.regs[R.RFCTL / 4] & RFCTL_EXTEN == 0);
    // The rings.
    try expect(m.regs[R.RDLEN / 4] == RING_BYTES and m.regs[R.TDLEN / 4] == RING_BYTES);
    try expect(m.regs[R.RDT / 4] == N - 1 and m.regs[R.TDT / 4] == 0);
    try expect(Bench.rx_ring[5].addr == @intFromPtr(&Bench.rx_buffers) + 5 * BUF);
    // The link follows the PHY; nothing forced.
    const ctrl = m.regs[R.CTRL / 4];
    try expect(ctrl & CTRL_SLU != 0 and ctrl & (CTRL_FRCSPD | CTRL_FRCDPX) == 0);
    try expect(m.regs[R.CTRL_EXT / 4] & CTRL_EXT_FORCE_SMBUS == 0);
    // The PHY: no host wake, no low power idle, the semaphore given back.
    try expect(m.pages[Model.pageIndex(769).?][17] & PORT_GEN_HOST_WAKE == 0);
    try expect(m.pages[Model.pageIndex(772).?][20] & LPI_CTRL_ENABLE_MASK == 0);
    try expect(m.regs[R.EXTCNF_CTRL / 4] & EXTCNF_SWFLAG == 0);
    // The Cannon Point part gets none of Sunrise Point's errata settings.
    try expect(m.regs[R.IOSFPC / 4] == 0);
}

test "i219: Sunrise Point's errata settings" {
    const m = Bench.fresh();
    var n = Bench.nic(.spt);
    try n.bringUp();
    try expect(m.regs[R.IOSFPC / 4] & IOSFPC_RDMTS_HEX != 0);
    try expect(m.regs[R.TARC0 / 4] & TARC0_REQUESTS_MASK == TARC0_REQUESTS_2);
}

test "i219: a PHY left in ULP on SMBus, no ME" {
    const m = Bench.fresh();
    m.ulp = true;
    m.phy_smbus = true;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(n.phy_ok);
    try expect(m.power_cycles >= 1);
    try expect(!m.ulp and !m.phy_smbus);
    try expect(m.regs[R.CTRL_EXT / 4] & CTRL_EXT_FORCE_SMBUS == 0);
    try expect(m.regs[R.RCTL / 4] & RCTL_EN != 0);
    try expect(m.wrong_address == 0);
}

test "i219: the ME takes the PHY out of ULP, and the PHY is found on SMBus" {
    const m = Bench.fresh();
    m.me = true;
    m.ulp = true;
    m.phy_smbus = true;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(n.me and n.phy_ok);
    try expect(!m.ulp);
    try expect(m.regs[R.H2ME / 4] & H2ME_ENFORCE == 0);
    // (found with the MAC forced to SMBus: no power cycle needed)
    try expect(m.power_cycles == 0);
    try expect(m.regs[R.CTRL_EXT / 4] & CTRL_EXT_FORCE_SMBUS == 0);
    try expect(m.regs[R.RCTL / 4] & RCTL_EN != 0);
}

test "i219: a silent PHY answers after its power is cycled" {
    const m = Bench.fresh();
    m.me = true;
    m.wedged = true;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(n.phy_ok);
    try expect(m.power_cycles == 1);
    try expect(m.regs[R.CTRL_EXT / 4] & CTRL_EXT_FORCE_SMBUS == 0);
}

test "i219: the ME refuses a PHY reset" {
    const m = Bench.fresh();
    m.me = true;
    m.reset_allowed = false;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(n.phy_reset_blocked and n.phy_ok);
    try expect(m.phy_reset_writes == 0 and m.phy_resets == 0);
    try expect(m.mac_resets == 1);
    try expect(m.regs[R.RCTL / 4] & RCTL_EN != 0);
}

test "i219: a PHY that never answers leaves a working MAC" {
    const m = Bench.fresh();
    m.dead = true;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(!n.phy_ok);
    try expect(m.regs[R.RCTL / 4] & RCTL_EN != 0 and m.regs[R.TCTL / 4] & TCTL_EN != 0);
    try expect(m.regs[R.CTRL / 4] & CTRL_SLU != 0);
    try expect(!n.poll().up);
}

test "i219: no address, no port" {
    const m = Bench.fresh();
    m.nvm_mac = .{ 0, 0, 0, 0, 0, 0 };
    m.start();
    var n = Bench.nic(.cnp);
    if (n.bringUp()) |_| return error.TestUnexpectedResult else |e| try expect(e == error.NoAddress);
    // (and the port is left quiet)
    try expect(m.regs[R.RCTL / 4] & RCTL_EN == 0);
}

test "i219: the link at 1000 Mb/s full duplex" {
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    try n.bringUp();
    try expect(!n.poll().up);
    m.link_mbps = 1000;
    const l = n.poll();
    try expect(l.up and l.mbps == 1000 and l.full_duplex);
    try expect(m.regs[R.TIPG / 4] == 0x0060_2008);
    try expect(m.pages[0][0x10] == EMI_RX_CONFIG and m.pages[0][0x11] == 1);
    try expect(m.pages[Model.pageIndex(772).?][28] & PLL_CLOCK_GATE_MASK == 0xFA);
    try expect(m.pages[Model.pageIndex(770).?][17] & PM_CTRL_K1_CLK_REQ != 0);
    try expect((m.pages[Model.pageIndex(776).?][20] & POINTER_GAP_MASK) >> 2 == 0x18);
    try expect(m.pages[Model.pageIndex(776).?][20] & 0x3 == 0x3); // (its other bits kept)
    try expect(m.regs[R.EXTCNF_CTRL / 4] & EXTCNF_SWFLAG == 0);
    // The cable pulled, and back.
    m.link_mbps = 0;
    try expect(!n.poll().up);
    m.link_mbps = 1000;
    try expect(n.poll().up);
    try expect(m.wrong_address == 0);
}

test "i219: the link at 100 Mb/s full and 10 Mb/s half duplex" {
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    try n.bringUp();
    m.link_mbps = 100;
    var l = n.poll();
    try expect(l.up and l.mbps == 100 and l.full_duplex);
    try expect(m.regs[R.TIPG / 4] & TIPG_IPGT_MASK == 0x0C);
    try expect(m.pages[0][0x11] == 1);
    try expect(m.pages[Model.pageIndex(772).?][28] & PLL_CLOCK_GATE_MASK == 0x3E8);
    try expect(m.pages[Model.pageIndex(776).?][20] == 0xC023);
    try expect(m.pages[Model.pageIndex(770).?][17] & PM_CTRL_K1_CLK_REQ == 0);
    m.link_mbps = 0;
    _ = n.poll();
    m.link_mbps = 10;
    m.link_full = false;
    l = n.poll();
    try expect(l.up and l.mbps == 10 and !l.full_duplex);
    try expect(m.regs[R.TIPG / 4] & TIPG_IPGT_MASK == 0xFF);
    try expect(m.pages[0][0x11] == 0);
}

test "i219: frames out, in order, around the ring" {
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    try n.bringUp();
    var frame: [60]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(i);
    var k: usize = 0;
    while (k < N + 3) : (k += 1) {
        frame[0] = @intCast(k);
        try expect(n.send(&frame));
    }
    try expect(m.sent_count == N + 3);
    try expect(m.sent_len[0] == 60 and m.sent[0][0] == 0 and m.sent[0][59] == 59);
    try expect(m.sent[3][0] == 3);
    try expect(n.tx_next == 3 and m.regs[R.TDH / 4] == 3);
    const last = Bench.tx_ring[2];
    try expect(last.cmd == TXD_CMD_EOP | TXD_CMD_IFCS | TXD_CMD_RS and last.len == 60);
    // Too long, or empty: refused.
    try expect(!n.send(Bench.tx_buffers[0 .. BUF + 1]));
    try expect(!n.send(frame[0..0]));
}

test "i219: a full transmit ring refuses, then goes on" {
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    try n.bringUp();
    m.tx_stalled = true;
    const frame = [_]u8{0xAB} ** 64;
    // (one slot stays free: the tail never catches the head)
    var k: usize = 0;
    while (k < N - 1) : (k += 1) try expect(n.send(&frame));
    try expect(!n.send(&frame));
    try expect(m.regs[R.TDT / 4] != m.regs[R.TDH / 4]);
    m.tx_stalled = false;
    m.transmit(m.regs[R.TDT / 4]);
    try expect(n.send(&frame));
    try expect(m.sent_count == N);
}

test "i219: frames in, in order, and their slots given back" {
    const m = Bench.fresh();
    var n = Bench.nic(.cnp);
    try n.bringUp();
    var out: [BUF]u8 = undefined;
    try expect(n.recv(&out) == null);
    var k: usize = 0;
    while (k < 2 * N) : (k += 1) {
        var frame = [_]u8{0} ** 80;
        frame[0] = @intCast(k);
        frame[79] = 0x5A;
        try expect(m.deliver(&frame));
        const got = n.recv(&out) orelse return error.TestUnexpectedResult;
        try expect(got == 80 and out[0] == @as(u8, @intCast(k)) and out[79] == 0x5A);
    }
    try expect(n.recv(&out) == null);
    // The ring fills when nothing is taken: N - 1 frames, as the tail says.
    const one = [_]u8{1} ** 64;
    k = 0;
    while (m.deliver(&one)) k += 1;
    try expect(k == N - 1);
    // A short buffer gets the frame's start.
    var small: [16]u8 = undefined;
    try expect(n.recv(&small).? == 16);
}

test "i219: writes wait for the ME's arbiter, and a lost tail is written again" {
    const m = Bench.fresh();
    m.me = true;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    m.arbiter_violations = 0;
    m.arbiter_busy = 3;
    const frame = [_]u8{0x11} ** 64;
    try expect(n.send(&frame));
    try expect(m.arbiter_violations == 0 and m.arbiter_busy == 0);
    try expect(m.sent_count == 1 and n.tail_rewrites == 0);
    // A tail write lost to the ME's own: seen on the read back, written again.
    m.lose_tail_writes = 1;
    try expect(n.send(&frame));
    try expect(n.tail_rewrites == 1);
    try expect(m.sent_count == 2 and m.regs[R.TDT / 4] == 2);
}

test "i219: a held semaphore does not stop the port" {
    const m = Bench.fresh();
    m.flag_taken = true;
    var n = Bench.nic(.cnp);
    try n.bringUp();
    // (no PHY access without the semaphore: the MAC still runs)
    try expect(!n.phy_ok);
    try expect(m.regs[R.RCTL / 4] & RCTL_EN != 0);
    m.link_mbps = 1000;
    try expect(n.poll().up);
}
