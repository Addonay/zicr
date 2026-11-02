//! GPU resources for the full renderer. All native work goes through gpu.Device.
const std=@import("std");
const gpu=@import("gpu");
const atlas=@import("atlas.zig");
const images=@import("image.zig");
const paints=@import("paint.zig");
const colors=@import("color.zig");
pub const Error=gpu.CreateError||std.mem.Allocator.Error||error{InvalidGpuResource,UnsupportedFormat,ResourceLimit,NumericRange};
pub const Programs=struct{
    paint:gpu.ShaderDesc,paint_over:gpu.ShaderDesc,mask:gpu.ShaderDesc,composite:gpu.ShaderDesc,effect:gpu.ShaderDesc,copy:gpu.ShaderDesc,
    pub fn fromModule(comptime module:type,backend:gpu.Backend) ?Programs {
        return .{.paint=module.paint.desc(backend) orelse return null,.paint_over=module.paint_over.desc(backend) orelse return null,.mask=module.mask.desc(backend) orelse return null,.composite=module.composite.desc(backend) orelse return null,.effect=module.effect.desc(backend) orelse return null,.copy=module.copy.desc(backend) orelse return null};
    }
};
pub const Shaders=struct{
    paint:gpu.Shader=.invalid,paint_over:gpu.Shader=.invalid,mask:gpu.Shader=.invalid,composite:gpu.Shader=.invalid,effect:gpu.Shader=.invalid,copy:gpu.Shader=.invalid,
    pub fn init(device:*gpu.Device,programs:Programs) Error!Shaders {var result:Shaders=.{};errdefer result.deinit(device);inline for(@typeInfo(Shaders).@"struct".field_names)|name|@field(result,name)=try createShader(device,@field(programs,name));return result;}
    pub fn deinit(self:*Shaders,device:*gpu.Device) void {inline for(@typeInfo(Shaders).@"struct".field_names)|name|{const shader=@field(self.*,name);if(shader!=.invalid)device.destroy(shader);}self.*=undefined;}
};
fn createShader(device:*gpu.Device,descriptor:gpu.ShaderDesc) Error!gpu.Shader {
    // Programs use point sampling/manual filters for every texture, including
    // float tables. Correct binding metadata is required by browser WebGPU.
    var views:[gpu.max_views]gpu.ShaderView=undefined;var samplers:[gpu.max_samplers]gpu.ShaderSampler=undefined;
    if(descriptor.views.len>views.len or descriptor.samplers.len>samplers.len)return error.InvalidGpuResource;
    @memcpy(views[0..descriptor.views.len],descriptor.views);@memcpy(samplers[0..descriptor.samplers.len],descriptor.samplers);
    for(views[0..descriptor.views.len])|*view|switch(view.kind){.texture=>|*texture|if(texture.sample_type==.float)texture.sample_type=.unfilterable_float,else=>{}};
    for(samplers[0..descriptor.samplers.len])|*sampler|if(sampler.type==.filtering)sampler.type=.nonfiltering;
    var normalized=descriptor;normalized.views=views[0..descriptor.views.len];normalized.samplers=samplers[0..descriptor.samplers.len];return device.createShader(normalized);
}
pub const Target=struct{
    image:gpu.Image,view:gpu.View,attachment:gpu.View,width:u32,height:u32,format:gpu.PixelFormat,
    pub fn init(device:*gpu.Device,width:u32,height:u32,format:gpu.PixelFormat) Error!Target {
        const info=device.formatInfo(format);if(!info.render or !info.sample)return error.UnsupportedFormat;
        const image=try device.createImage(.{.width=width,.height=height,.format=format,.usage=.{.color_attachment=true,.copy_src=true},.label="zicr retained renderer intermediate"});errdefer device.destroy(image);
        const view=try device.createView(.{.texture=.{.image=image}});errdefer device.destroy(view);
        return .{.image=image,.view=view,.attachment=try device.createView(.{.color_attachment=.{.image=image}}),.width=width,.height=height,.format=format};
    }
    pub fn deinit(self:*Target,device:*gpu.Device) void {device.destroy(self.attachment);device.destroy(self.view);device.destroy(self.image);self.*=undefined;}
    pub fn begin(self:*const Target,device:*gpu.Device,load:gpu.ColorAction) gpu.Pass {return device.beginPass(.{.target=.{.attachments=.{.colors=&.{self.attachment}}},.colors=&.{load}});}
};
pub const ImageBinding=struct{view:gpu.View,width:u32,height:u32,mips:u32=1,space:colors.Space=.linear_srgb,alpha:images.Alpha=.premultiplied,flip_y:bool=false};
const Resident=struct{source:*const images.Image,revision:u64,texture:atlas.Texture,mips:u32,bytes:usize,last_used:u64};
pub const Images=struct{
    allocator:std.mem.Allocator,entries:std.ArrayList(Resident)=.empty,budget:usize,used:usize=0,clock:u64=0,
    pub fn init(allocator:std.mem.Allocator,budget:usize) Images{return .{.allocator=allocator,.budget=budget};}
    pub fn deinit(self:*Images,device:*gpu.Device) void {for(self.entries.items)|*entry|entry.texture.deinit(device);self.entries.deinit(self.allocator);self.*=undefined;}
    pub fn beginFrame(self:*Images) void {self.clock+%=1;}
    pub fn resolve(self:*Images,device:*gpu.Device,source:paints.ImageSource) Error!ImageBinding {
        if(source==.borrowed){const value=source.borrowed;const view=device.viewInfo(value.view) orelse return error.InvalidGpuResource;const image=device.imageInfo(view.image) orelse return error.InvalidGpuResource;if(view.type!=.texture or view.state!=.valid or image.sample_count!=1 or image.type!=.@"2d" or image.width!=value.width or image.height!=value.height or !device.formatInfo(image.format).sample or device.formatInfo(image.format).depth)return error.InvalidGpuResource;return .{.view=value.view,.width=value.width,.height=value.height,.mips=image.mip_levels,.space=value.space,.alpha=value.alpha,.flip_y=value.flip_y};}
        const image=source.pixels;
        for(self.entries.items)|*entry|if(entry.source==image and entry.revision==image.revision){entry.last_used=self.clock;return .{.view=entry.texture.view,.width=entry.texture.width,.height=entry.texture.height,.mips=entry.mips};};
        const uploaded=try uploadImage(device,image,self.allocator);errdefer {var texture=uploaded.texture;texture.deinit(device);}
        if(uploaded.bytes>self.budget)return error.ResourceLimit;
        try self.evict(device,uploaded.bytes);
        // Drop stale revisions only after the replacement exists. Destroying a
        // GPU handle is deferred by the device while earlier work still uses it.
        var i:usize=0;while(i<self.entries.items.len){if(self.entries.items[i].source==image){var previous=self.entries.swapRemove(i);self.used-=previous.bytes;previous.texture.deinit(device);}else i+=1;}
        try self.entries.append(self.allocator,.{.source=image,.revision=image.revision,.texture=uploaded.texture,.mips=@intCast(image.levels.len),.bytes=uploaded.bytes,.last_used=self.clock});self.used+=uploaded.bytes;
        return .{.view=uploaded.texture.view,.width=image.width(),.height=image.height(),.mips=@intCast(image.levels.len)};
    }
    fn evict(self:*Images,device:*gpu.Device,needed:usize) Error!void {
        while(self.used>self.budget-needed){var oldest:?usize=null;for(self.entries.items,0..)|entry,index|if(entry.last_used!=self.clock and (oldest==null or entry.last_used<self.entries.items[oldest.?].last_used))oldest=index;
            const index=oldest orelse return error.ResourceLimit;var removed=self.entries.swapRemove(index);self.used-=removed.bytes;removed.texture.deinit(device);
        }
    }
};
const Uploaded=struct{texture:atlas.Texture,bytes:usize};
fn uploadImage(device:*gpu.Device,image:*const images.Image,allocator:std.mem.Allocator) Error!Uploaded {
    const limit=device.limits().max_image_size_2d;if(image.width()>limit or image.height()>limit or image.levels.len>gpu.max_mip_levels)return error.ResourceLimit;
    var half=true;for(image.levels)|level|for(level.pixels)|pixel|{if(!pixel.valid())return error.InvalidGpuResource;if(@max(@abs(pixel.r),@max(@abs(pixel.g),@abs(pixel.b)))>65504)half=false;};
    var format:gpu.PixelFormat=if(half).rgba16f else .rgba32f;if(!device.formatInfo(format).sample)format=.rgba32f;if(!device.formatInfo(format).sample)return error.UnsupportedFormat;
    const data=try allocator.alloc([]u8,image.levels.len);var built:usize=0;defer {for(data[0..built])|level|allocator.free(level);allocator.free(data);}
    var byte_count:usize=0;
    for(image.levels,data)|level,*bytes|{
        const bpp:usize=if(format==.rgba16f)8 else 16;bytes.*=try allocator.alloc(u8,level.pixels.len*bpp);built+=1;byte_count+=bytes.len;
        for(level.pixels,0..)|pixel,index|{const channels=[4]f64{pixel.r,pixel.g,pixel.b,pixel.a};for(channels,0..)|value,channel|{if(@abs(value)>std.math.floatMax(f32))return error.NumericRange;if(format==.rgba16f)std.mem.writeInt(u16,bytes.*[index*bpp+channel*2..][0..2],@bitCast(@as(f16,@floatCast(value))),.little) else std.mem.writeInt(u32,bytes.*[index*bpp+channel*4..][0..4],@bitCast(@as(f32,@floatCast(value))),.little);}}
    }
    const slices=try allocator.alloc([]const u8,data.len);defer allocator.free(slices);for(data,slices)|source,*destination|destination.*=source;
    const handle=try device.createImage(.{.width=image.width(),.height=image.height(),.mip_levels=@intCast(image.levels.len),.format=format,.data=slices,.label="zicr owned image upload"});errdefer device.destroy(handle);
    return .{.texture=.{.image=handle,.view=try device.createView(.{.texture=.{.image=handle}}),.width=image.width(),.height=image.height()},.bytes=byte_count};
}
pub const Vertex=extern struct{position:[2]f32,uv:[2]f32};
pub fn pipeline(device:*gpu.Device,shader:gpu.Shader,formats:[]const gpu.PixelFormat,blend:bool,depth:gpu.PixelFormat,samples:u32) Error!gpu.Pipeline {
    if(formats.len>gpu.max_color_attachments)return error.InvalidGpuResource;
    var targets:[gpu.max_color_attachments]gpu.ColorTarget=undefined;for(formats,0..)|format,index|targets[index]=.{.format=format,.blend=if(blend)gpu.Blend{.src_rgb=.one,.dst_rgb=.one_minus_src_alpha,.src_alpha=.one,.dst_alpha=.one_minus_src_alpha} else null};
    return device.createPipeline(.{.shader=shader,.vertex_buffers=&.{.{.stride=@sizeOf(Vertex)}},.vertex_attrs=&.{.{.format=.float2,.offset=@offsetOf(Vertex,"position")},.{.format=.float2,.offset=@offsetOf(Vertex,"uv")}},.colors=targets[0..formats.len],.depth=.{.format=depth},.sample_count=samples,.label="zicr retained renderer pipeline"});
}
