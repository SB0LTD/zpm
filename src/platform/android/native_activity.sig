//! Android NDK NativeActivity ABI; no Java/Kotlin application code or allocator.
pub const Window = opaque {};
pub const Queue = opaque {};
pub const Event = opaque {};
pub const Looper = opaque {};
pub const Activity = extern struct {
    callbacks: *Callbacks, vm: ?*anyopaque, env: ?*anyopaque, clazz: ?*anyopaque,
    internal_data_path: [*:0]const u8, external_data_path: ?[*:0]const u8,
    sdk_version: i32, instance: ?*anyopaque, asset_manager: ?*anyopaque, obb_path: ?[*:0]const u8,
};
const Life = *const fn (*Activity) callconv(.c) void;
const WindowFn = *const fn (*Activity, *Window) callconv(.c) void;
const QueueFn = *const fn (*Activity, *Queue) callconv(.c) void;
pub const Callbacks = extern struct {
    on_start: ?Life = null, on_resume: ?Life = null,
    on_save_instance_state: ?*const fn (*Activity, *usize) callconv(.c) ?*anyopaque = null,
    on_pause: ?Life = null, on_stop: ?Life = null, on_destroy: ?Life = null,
    on_window_focus_changed: ?*const fn (*Activity, c_int) callconv(.c) void = null,
    on_native_window_created: ?WindowFn = null, on_native_window_resized: ?WindowFn = null,
    on_native_window_redraw_needed: ?WindowFn = null, on_native_window_destroyed: ?WindowFn = null,
    on_input_queue_created: ?QueueFn = null, on_input_queue_destroyed: ?QueueFn = null,
    on_content_rect_changed: ?*const fn (*Activity, *const anyopaque) callconv(.c) void = null,
    on_configuration_changed: ?Life = null, on_low_memory: ?Life = null,
};
pub extern "android" fn ANativeWindow_acquire(*Window) void;
pub extern "android" fn ANativeActivity_setWindowFlags(*Activity, u32, u32) void;
pub extern "android" fn ANativeWindow_release(*Window) void;
pub extern "android" fn ANativeWindow_setBuffersGeometry(*Window, i32, i32, i32) c_int;
pub extern "android" fn ALooper_prepare(c_int) ?*Looper;
pub extern "android" fn ALooper_pollOnce(c_int, ?*c_int, ?*c_int, ?*?*anyopaque) c_int;
pub extern "android" fn AInputQueue_attachLooper(*Queue, *Looper, c_int, ?*const fn(c_int,c_int,?*anyopaque) callconv(.c) c_int, ?*anyopaque) void;
pub extern "android" fn AInputQueue_detachLooper(*Queue) void;
pub extern "android" fn AInputQueue_getEvent(*Queue, *?*Event) c_int;
pub extern "android" fn AInputQueue_preDispatchEvent(*Queue, *Event) c_int;
pub extern "android" fn AInputQueue_finishEvent(*Queue, *Event, c_int) void;
pub extern "android" fn AInputEvent_getType(*const Event) c_int;
pub extern "android" fn AMotionEvent_getAction(*const Event) c_int;
pub extern "android" fn AMotionEvent_getX(*const Event, usize) f32;
pub extern "android" fn AMotionEvent_getY(*const Event, usize) f32;
pub extern "c" fn pthread_create(*usize, ?*const anyopaque, *const fn(?*anyopaque) callconv(.c) ?*anyopaque, ?*anyopaque) c_int;
pub extern "c" fn pthread_join(usize, ?*?*anyopaque) c_int;
pub extern "c" fn usleep(c_uint) c_int;
