//! Shelf-packed CPU atlas pages and explicit public-GPU upload ownership.
//! Upload only after all entries are written, so a page is never overwritten
//! between draws using the same Device frame.
const std=@import("std");
const gpu=@import("gpu");
const coverage=@import("coverage.zig");
const colors=@import("color.zig");
pub const Options=struct{page_size:u32=2048,max_dimension:u32=16384,max_pages:u32=64,max_bytes:usize=256*1024*1024};
pub const Region=struct{page:u32,x:u32,y:u32,width:u32,height:u32};
pub const Error=std.mem.Allocator.Error||gpu.CreateError||error{AtlasLimit,InvalidAtlasData};
pub const Page=struct{width:u32,height:u32,pixels:[]u8,cursor_x:u32=0,cursor_y:u32=0,row_height:u32=0,used_height:u32=0};
pub const Texture=struct{
    image:gpu.Image,view:gpu.View,width:u32,height:u32,
    pub fn deinit(self:*Texture,device:*gpu.Device) void {device.destroy(self.view);device.destroy(self.image);self.*=undefined;}
};
pub const MaskAtlas=struct{
    allocator:std.mem.Allocator,options:Options,pages:std.ArrayList(Page)=.empty,allocated_bytes:usize=0,
    pub fn init(allocator:std.mem.Allocator,options:Options) MaskAtlas{return .{.allocator=allocator,.options=options};}
    pub fn deinit(self:*MaskAtlas) void {for(self.pages.items)|page|self.allocator.free(page.pixels);self.pages.deinit(self.allocator);self.*=undefined;}
    pub fn add(self:*MaskAtlas,mask:*const coverage.Mask) Error!Region {
        if(mask.bounds.width<=0 or mask.bounds.height<=0)return .{.page=0,.x=0,.y=0,.width=0,.height=0};
        const width:u32=@intCast(mask.bounds.width);const height:u32=@intCast(mask.bounds.height);
        var entry:?Region=null;
        for(self.pages.items,0..)|*page,index|if(place(page,width,height))|position|{entry=.{.page=@intCast(index),.x=position[0],.y=position[1],.width=width,.height=height};break;};
        if(entry==null){
            if(self.pages.items.len>=self.options.max_pages or width>self.options.max_dimension or height>self.options.max_dimension or self.options.page_size==0)return error.AtlasLimit;
            const w=@max(width,@min(self.options.page_size,self.options.max_dimension));const h=@max(height,@min(self.options.page_size,self.options.max_dimension));
            const bytes=std.math.mul(usize,w,h) catch return error.AtlasLimit;
            if(bytes>self.options.max_bytes-self.allocated_bytes)return error.AtlasLimit;
            const pixels=try self.allocator.alloc(u8,bytes);errdefer self.allocator.free(pixels);@memset(pixels,0);
            try self.pages.append(self.allocator,.{.width=w,.height=h,.pixels=pixels});self.allocated_bytes+=bytes;
            const index=self.pages.items.len-1;const position=place(&self.pages.items[index],width,height).?;
            entry=.{.page=@intCast(index),.x=position[0],.y=position[1],.width=width,.height=height};
        }
        const region=entry.?;const page=&self.pages.items[region.page];
        for(0..height)|y|for(0..width)|x|{const value=mask.pixels[y*width+x];if(!std.math.isFinite(value))return error.InvalidAtlasData;page.pixels[(@as(usize,region.y)+y)*page.width+region.x+x]=colors.unorm(value);};
        return region;
    }
    pub fn upload(self:*const MaskAtlas,device:*gpu.Device,allocator:std.mem.Allocator) Error![]Texture {
        if(!device.formatInfo(.r8).sample)return error.InvalidAtlasData;
        const result=try allocator.alloc(Texture,self.pages.items.len);var initialized:usize=0;
        errdefer {for(result[0..initialized])|*texture|texture.deinit(device);allocator.free(result);}
        for(self.pages.items,result)|page,*texture|{
            const height=@max(1,page.used_height);const image=try device.createImage(.{.width=page.width,.height=height,.format=.r8,.data=&.{page.pixels[0..@as(usize,page.width)*height]},.label="zicr vector coverage atlas"});
            errdefer device.destroy(image);const view=try device.createView(.{.texture=.{.image=image}});texture.*=.{.image=image,.view=view,.width=page.width,.height=height};initialized+=1;
        }
        return result;
    }
};
fn place(page:*Page,width:u32,height:u32) ?[2]u32 {
    if(width>page.width or height>page.height)return null;
    var x=page.cursor_x;var y=page.cursor_y;var row=page.row_height;
    if(width>page.width-x){x=0;y+=row;row=0;}
    if(y>page.height or height>page.height-y)return null;
    page.cursor_x=x+width;page.cursor_y=y;page.row_height=@max(row,height);page.used_height=@max(page.used_height,y+height);return .{x,y};
}
/// Float data tables are unfiltered texel-addressed textures. A table may contain
/// any number of stops/mesh records within the device texture and byte budget.
pub const Table=struct{
    allocator:std.mem.Allocator,texels:std.ArrayList([4]f32)=.empty,
    pub fn init(allocator:std.mem.Allocator) Table{return .{.allocator=allocator};}
    pub fn deinit(self:*Table) void {self.texels.deinit(self.allocator);self.*=undefined;}
    pub fn append(self:*Table,texels:[]const[4]f32) Error!u32 {
        if(self.texels.items.len>(1<<24) or texels.len>(1<<24)-self.texels.items.len)return error.AtlasLimit;
        const first:u32=@intCast(self.texels.items.len);try self.texels.appendSlice(self.allocator,texels);return first;
    }
    pub fn upload(self:*const Table,device:*gpu.Device,allocator:std.mem.Allocator) Error!Texture {
        const count=@max(1,self.texels.items.len);const limit=device.limits().max_image_size_2d;
        if(limit==0 or count>@as(u64,limit)*limit or !device.formatInfo(.rgba32f).sample)return error.AtlasLimit;
        const width:u32=@intCast(@min(count,limit));const height:u32=@intCast((count+width-1)/width);
        const pixels=try allocator.alloc([4]f32,@as(usize,width)*height);defer allocator.free(pixels);@memset(pixels,.{0,0,0,0});@memcpy(pixels[0..self.texels.items.len],self.texels.items);
        const image=try device.createImage(.{.width=width,.height=height,.format=.rgba32f,.data=&.{std.mem.sliceAsBytes(pixels)},.label="zicr unfiltered paint/geometry table"});errdefer device.destroy(image);
        return .{.image=image,.view=try device.createView(.{.texture=.{.image=image}}),.width=width,.height=height};
    }
};
