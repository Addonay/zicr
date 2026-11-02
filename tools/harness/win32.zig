//! Small owned Win32 popup used only by native presentation smoke tests.
const gpu = @import("zicr").gpu;
const sdk = gpu.raw.native.d3d12;
const Library = gpu.raw.native.WindowsLibrary;
const Message = extern struct {
    hwnd: ?*anyopaque,
    message: u32,
    wparam: usize,
    lparam: isize,
    time: u32,
    x: i32,
    y: i32,
    private: u32,
};
pub const Window = struct {
    library: Library,
    handle: *anyopaque,
    instance: *anyopaque,
    destroy: *const fn (*anyopaque) callconv(sdk.call_conv) i32,
    peek: *const fn (*Message, ?*anyopaque, u32, u32, u32) callconv(sdk.call_conv) i32,
    translate: *const fn (*const Message) callconv(sdk.call_conv) i32,
    dispatch: *const fn (*const Message) callconv(sdk.call_conv) isize,
    pub fn create() !Window {
        const library = try Library.open("user32.dll");
        errdefer library.close();
        const Create = *const fn (u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(sdk.call_conv) ?*anyopaque;
        const create_window = library.lookup(Create, "CreateWindowExW") orelse return error.MissingWindowFunction;
        const destroy = library.lookup(*const fn (*anyopaque) callconv(sdk.call_conv) i32, "DestroyWindow") orelse return error.MissingWindowFunction;
        const kernel = try Library.open("kernel32.dll");
        defer kernel.close();
        const GetModule = *const fn (?[*:0]const u16) callconv(sdk.call_conv) ?*anyopaque;
        const get_module = kernel.lookup(GetModule, "GetModuleHandleW") orelse return error.MissingModuleFunction;
        const instance = get_module(null) orelse return error.MissingModule;
        const class = [_:0]u16{ 'S', 'T', 'A', 'T', 'I', 'C' };
        const title = [_:0]u16{ 'z', 'i', 'c', 'r' };
        const handle = create_window(0, &class, &title, 0x90000000, 0, 0, 64, 64, null, null, instance, null) orelse return error.WindowCreationFailed;
        errdefer _ = destroy(handle);
        const peek = library.lookup(@TypeOf(@as(Window, undefined).peek), "PeekMessageW") orelse return error.MissingWindowFunction;
        const translate = library.lookup(@TypeOf(@as(Window, undefined).translate), "TranslateMessage") orelse return error.MissingWindowFunction;
        const dispatch = library.lookup(@TypeOf(@as(Window, undefined).dispatch), "DispatchMessageW") orelse return error.MissingWindowFunction;
        var self: Window = .{ .library = library, .handle = handle, .instance = instance, .destroy = destroy, .peek = peek, .translate = translate, .dispatch = dispatch };
        self.pump();
        return self;
    }
    pub fn pump(self: *Window) void {
        var message: Message = undefined;
        while (self.peek(&message, self.handle, 0, 0, 1) != 0) {
            _ = self.translate(&message);
            _ = self.dispatch(&message);
        }
    }
    pub fn deinit(self: *Window) void {
        _ = self.destroy(self.handle);
        self.library.close();
    }
};
