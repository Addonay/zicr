//! Reusable intermediate targets and typed pass emission for the retained renderer.
//! All source/coverage resources are prepared before these GPU-only operations.
const std=@import("std");const gpu=@import("gpu");const resources=@import("gpu_resources.zig");
pub const Id=enum(u32){_};
pub const Error=resources.Error||error{InvalidTarget};
const Entry=struct{target:resources.Target,used:bool};
pub const Pool=struct{
    allocator:std.mem.Allocator,device:*gpu.Device,entries:std.ArrayList(Entry)=.empty,width:u32=0,height:u32=0,max_targets:usize,
    pub fn init(allocator:std.mem.Allocator,device:*gpu.Device,max_targets:usize) Pool{return .{.allocator=allocator,.device=device,.max_targets=max_targets};}
    pub fn deinit(self:*Pool) void {for(self.entries.items)|*entry|entry.target.deinit(self.device);self.entries.deinit(self.allocator);self.*=undefined;}
    pub fn begin(self:*Pool,width:u32,height:u32) void {
        if(self.width!=width or self.height!=height){for(self.entries.items)|*entry|entry.target.deinit(self.device);self.entries.clearRetainingCapacity();self.width=width;self.height=height;}
        for(self.entries.items)|*entry|entry.used=false;
    }
    pub fn acquire(self:*Pool,format:gpu.PixelFormat) Error!Id {
        for(self.entries.items,0..)|*entry,index|if(!entry.used and entry.target.format==format){entry.used=true;return @fromBackingInt(@intCast(index));};
        if(self.entries.items.len==self.max_targets)return error.ResourceLimit;
        var target=try resources.Target.init(self.device,self.width,self.height,format);errdefer target.deinit(self.device);
        try self.entries.append(self.allocator,.{.target=target,.used=true});return @fromBackingInt(@intCast(self.entries.items.len-1));
    }
    pub fn get(self:*Pool,id:Id) *resources.Target{return &self.entries.items[@intFromEnum(id)].target;}
    pub fn release(self:*Pool,id:Id) void {self.entries.items[@intFromEnum(id)].used=false;}
};
pub const Pipelines=struct{
    paint:gpu.Pipeline=.invalid,over:gpu.Pipeline=.invalid,mask:gpu.Pipeline=.invalid,composite:gpu.Pipeline=.invalid,effect:gpu.Pipeline=.invalid,copy:gpu.Pipeline=.invalid,
    pub fn init(device:*gpu.Device,shaders:resources.Shaders,color:gpu.PixelFormat,mask:gpu.PixelFormat) Error!Pipelines {
        var result:Pipelines=.{};errdefer result.deinit(device);
        result.paint=try resources.pipeline(device,shaders.paint,&.{color,mask},false,.none,1);
        if(device.formatInfo(color).blend)result.over=try resources.pipeline(device,shaders.paint_over,&.{color},true,.none,1);
        result.mask=try resources.pipeline(device,shaders.mask,&.{mask},false,.none,1);
        result.composite=try resources.pipeline(device,shaders.composite,&.{color},false,.none,1);
        result.effect=try resources.pipeline(device,shaders.effect,&.{color},false,.none,1);
        result.copy=try resources.pipeline(device,shaders.copy,&.{color},false,.none,1);return result;
    }
    pub fn deinit(self:*Pipelines,device:*gpu.Device) void {inline for(@typeInfo(Pipelines).@"struct".field_names)|name|{const pipeline=@field(self.*,name);if(pipeline!=.invalid)device.destroy(pipeline);}self.*=undefined;}
};
pub const clear:gpu.ColorAction=.{.load=.{.clear=.{0,0,0,0}}};
pub const load:gpu.ColorAction=.{.load=.load};
pub fn beginMrt(device:*gpu.Device,color:*const resources.Target,mask:*const resources.Target) gpu.Pass {
    return device.beginPass(.{.target=.{.attachments=.{.colors=&.{color.attachment,mask.attachment}}},.colors=&.{clear,clear}});
}
pub fn emit(pass:*gpu.Pass,pipeline:gpu.Pipeline,buffer:gpu.Buffer,views:[]const gpu.View,sampler:gpu.Sampler,width:u32,height:u32,first:u32,uniforms:anytype) void {
    pass.setPipeline(pipeline);pass.setViewport(.{.width=@intCast(width),.height=@intCast(height)},.top_left);pass.setScissor(.{.width=@intCast(width),.height=@intCast(height)},.top_left);
    pass.setBindings(.{.vertex_buffers=&.{.{.buffer=buffer}},.views=views,.samplers=&.{sampler}});
    const frame=[4]f32{@floatFromInt(width),@floatFromInt(height),0,0};pass.setUniforms(0,&frame);pass.setUniforms(1,uniforms);pass.draw(.{.first=first,.count=6});
}
pub const Output=struct{color:gpu.PixelFormat,depth:gpu.PixelFormat,samples:u32};
pub fn output(device:*gpu.Device,target:gpu.PassDesc,width:u32,height:u32,fallback:gpu.PixelFormat) Error!Output {
    switch(target.target){
        .swapchain=>|s|{if(s.invalid or s.width!=width or s.height!=height)return error.InvalidTarget;return .{.color=s.color_format orelse fallback,.depth=s.depth_format orelse .none,.samples=s.sample_count orelse 1};},
        .attachments=>|a|{
            if(a.colors.len!=1)return error.InvalidTarget;const view=device.viewInfo(a.colors[0]) orelse return error.InvalidTarget;const image=device.imageInfo(view.image) orelse return error.InvalidTarget;
            if(view.type!=.colorattachment or view.state!=.valid or image.width!=width or image.height!=height)return error.InvalidTarget;
            var depth:gpu.PixelFormat=.none;if(a.depth_stencil!=.invalid){const v=device.viewInfo(a.depth_stencil) orelse return error.InvalidTarget;const d=device.imageInfo(v.image) orelse return error.InvalidTarget;if(v.type!=.depthstencilattachment or d.width!=width or d.height!=height or d.sample_count!=image.sample_count)return error.InvalidTarget;depth=d.format;}
            return .{.color=image.format,.depth=depth,.samples=image.sample_count};
        },
    }
}
