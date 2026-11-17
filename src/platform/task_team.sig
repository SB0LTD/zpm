//! Bounded joined task dispatch over caller-owned native worker handles.
const std = @import("std");
const workers = @import("worker_thread");

pub const available = workers.available;
pub const stack_bytes_per_helper = workers.stack_bytes;

/// Task supplies context and run(context). Keep the team at a stable address
/// from start through stop. A task must return normally and must not stop the
/// team, wait for another call to it, or retain any borrowed task data.
pub fn Team(comptime Task: type, comptime max_helpers: usize) type {
    return struct {
        const Self = @This();
        const parked = 0;
        const runnable = 1;
        const stopping = 2;
        const Error = workers.Error || error{InvalidWorkerCount};

        const Helper = struct {
            thread: workers.Thread = .{},
            state: std.atomic.Value(u32) = .init(parked),
            task: Task = undefined,

            fn work(raw: ?*anyopaque) void {
                const self: *Helper = @ptrCast(@alignCast(raw.?));
                while (true) {
                    switch (self.state.load(.acquire)) {
                        parked => workers.waitForChange(&self.state, parked, 1000),
                        runnable => {
                            const task = self.task;
                            task.run(task.context);
                            self.state.store(parked, .release);
                            workers.wakeAll(&self.state);
                        },
                        stopping => return,
                        else => unreachable,
                    }
                }
            }
        };

        mutex: workers.Mutex = .{},
        helpers: [max_helpers]Helper = @splat(.{}),
        count: usize = 0,
        open: bool = false,

        /// Start an exact helper count. The caller also participates and
        /// should account for the native stack reservations before startup.
        pub fn start(self: *Self, count: usize) Error!void {
            if (!available) return error.UnsupportedPlatform;
            if (count == 0 or count > max_helpers) return error.InvalidWorkerCount;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count != 0) return error.AlreadyStarted;
            errdefer self.stopLocked() catch @panic("failed task team startup could not join workers");
            for (self.helpers[0..count]) |*helper| {
                helper.state.store(parked, .monotonic);
                try helper.thread.start(&Helper.work, helper);
                self.count += 1;
            }
            self.open = true;
        }

        /// Execute and join one batch, including a task on the caller.
        /// False means no task ran. The caller may then run the whole batch
        /// inline without contending with a different worker team's batch.
        pub fn tryDispatch(self: *Self, tasks: []const Task) bool {
            if (!available or tasks.len < 2 or !self.mutex.tryLock()) return false;
            defer self.mutex.unlock();
            const count = tasks.len - 1;
            if (!self.open or count > self.count) return false;
            const helpers = self.helpers[0..count];
            for (helpers, tasks[0..count]) |*helper, task| {
                helper.task = task;
                helper.state.store(runnable, .release);
                workers.wakeAll(&helper.state);
            }
            const local = tasks[count];
            local.run(local.context);
            for (helpers) |*helper| {
                while (helper.state.load(.acquire) == runnable) {
                    workers.waitForChange(&helper.state, runnable, 1000);
                }
                helper.task = undefined;
            }
            return true;
        }

        /// Reject new batches and join the helpers. Retry on a native join
        /// failure before moving or releasing the team's backing.
        pub fn stop(self: *Self) Error!void {
            if (!available) return;
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.stopLocked();
        }

        fn stopLocked(self: *Self) workers.Error!void {
            self.open = false;
            for (self.helpers[0..self.count]) |*helper| {
                helper.state.store(stopping, .release);
                workers.wakeAll(&helper.state);
            }
            for (self.helpers[0..self.count]) |*helper| try helper.thread.join();
            self.count = 0;
        }
    };
}
