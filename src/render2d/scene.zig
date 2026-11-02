//! Retained ordered recordings. Paths, stops, mesh arrays, dash arrays and
//! uniforms are copied; image/font/shader objects are explicitly borrowed.
const std=@import("std");
const geo=@import("geometry.zig");
const paths=@import("path.zig");
const strokes=@import("stroke.zig");
const paints=@import("paint.zig");
const colors=@import("color.zig");
const compositing=@import("composite.zig");
const images=@import("image.zig");
const gpu=@import("gpu");
const filters=@import("filter.zig");
pub const FilterId=enum(u64){_};
pub const PathId=enum(u64){_};pub const PaintId=enum(u64){_};pub const ClipId=enum(u64){_};pub const StrokeId=enum(u64){_};pub const MeshId=enum(u64){_};
pub const State=struct{transform:geo.Affine=.{},paint:PaintId,stroke:StrokeId,clip:?ClipId=null,alpha:f64=1,mode:compositing.Mode=.source_over};
pub const Clip=struct{parent:?ClipId=null,geometry:union(enum){path:struct{path:PathId,rule:paths.FillRule=.nonzero},image:paints.Pattern},transform:geo.Affine=.{},inverse:bool=false};
pub const MeshVertex=struct{position:geo.Point,uv:geo.Point=.{},color:colors.Color=.white};
pub const Mesh=struct{vertices:[]MeshVertex,indices:[]u32};
pub const StrokeStyle=struct{geometry:strokes.Options=.{},alignment:f64=0.5,fill_rule:paths.FillRule=.nonzero};
pub const Layer=struct{transform:geo.Affine=.{},bounds:?geo.Rect=null,opacity:f64=1,mode:compositing.Mode=.source_over,clip:?ClipId=null,filter:?FilterId=null,isolated:bool=true};
pub const Uniform=struct{slot:u3,bytes:[]const u8};
pub const Custom=struct{shader:gpu.Shader,uniforms:[]Uniform,views:[]gpu.View,samplers:[]gpu.Sampler,bounds:geo.Rect};
pub const Draw=struct{path:PathId,paint:PaintId,state:State,rule:paths.FillRule=.nonzero};
pub const Command=union(enum){fill:Draw,stroke:Draw,mesh:struct{mesh:MeshId,paint:PaintId,state:State},begin_layer:Layer,end_layer,custom:struct{index:u32,state:State}};
const OwnedPaint=struct{value:paints.Paint,stops:[]paints.Stop};
const OwnedStroke=struct{value:StrokeStyle,dashes:[]f64};
pub const Error=std.mem.Allocator.Error||paths.Error||paints.Error||error{InvalidState,InvalidHandle,InvalidMesh,UnbalancedLayers,ResourceLimit};
pub const Scene=struct{
    allocator:std.mem.Allocator,
    identity:u32,
    commands:std.ArrayList(Command)=.empty,
    paths:std.ArrayList(paths.Path)=.empty,
    paints:std.ArrayList(OwnedPaint)=.empty,
    strokes:std.ArrayList(OwnedStroke)=.empty,
    clips:std.ArrayList(Clip)=.empty,
    meshes:std.ArrayList(Mesh)=.empty,
    custom:std.ArrayList(Custom)=.empty,
    filters:std.ArrayList(filters.Graph)=.empty,
    revision:u64=1,
    layer_depth:u32=0,
    pub fn init(allocator:std.mem.Allocator) error{ResourceLimit}!Scene{return .{.allocator=allocator,.identity=try nextIdentity()};}
    pub fn deinit(self:*Scene) void {
        self.releaseResources();self.commands.deinit(self.allocator);self.paths.deinit(self.allocator);self.paints.deinit(self.allocator);self.strokes.deinit(self.allocator);self.clips.deinit(self.allocator);self.meshes.deinit(self.allocator);self.custom.deinit(self.allocator);self.filters.deinit(self.allocator);self.*=undefined;
    }
    pub fn reset(self:*Scene) error{ResourceLimit}!void {const identity=try nextIdentity();self.releaseResources();self.identity=identity;}
    fn releaseResources(self:*Scene) void {
        for(self.paths.items)|*path|path.deinit();
        for(self.paints.items)|paint|self.allocator.free(paint.stops);
        for(self.strokes.items)|stroke|self.allocator.free(stroke.dashes);
        for(self.meshes.items)|mesh|{self.allocator.free(mesh.vertices);self.allocator.free(mesh.indices);}
        for(self.filters.items)|*graph|graph.deinit();
        for(self.custom.items)|item|{for(item.uniforms)|uniform|self.allocator.free(uniform.bytes);self.allocator.free(item.uniforms);self.allocator.free(item.views);self.allocator.free(item.samplers);}
        self.commands.clearRetainingCapacity();self.paths.clearRetainingCapacity();self.paints.clearRetainingCapacity();self.strokes.clearRetainingCapacity();self.clips.clearRetainingCapacity();self.meshes.clearRetainingCapacity();self.custom.clearRetainingCapacity();self.filters.clearRetainingCapacity();self.layer_depth=0;self.revision+%=1;
    }
    pub fn addPaint(self:*Scene,paint:paints.Paint) Error!PaintId {
        try paint.validate();if(self.paints.items.len>=std.math.maxInt(u32))return error.ResourceLimit;
        const stops=try self.allocator.dupe(paints.Stop,paint.stopSlice());errdefer self.allocator.free(stops);
        try self.paints.append(self.allocator,.{.value=paint.withStops(stops),.stops=stops});self.revision+%=1;return self.handle(PaintId,self.paints.items.len-1);
    }
    pub fn addStroke(self:*Scene,style:StrokeStyle) Error!StrokeId {
        if(!std.math.isFinite(style.geometry.width) or style.geometry.width<0 or !style.geometry.transform.finite() or !std.math.isFinite(style.alignment) or style.alignment<0 or style.alignment>1)return error.InvalidState;
        if(self.strokes.items.len>=std.math.maxInt(u32))return error.ResourceLimit;
        const dashes=try self.allocator.dupe(f64,style.geometry.dashes);errdefer self.allocator.free(dashes);var value=style;value.geometry.dashes=dashes;
        try self.strokes.append(self.allocator,.{.value=value,.dashes=dashes});self.revision+%=1;return self.handle(StrokeId,self.strokes.items.len-1);
    }
    pub fn addPath(self:*Scene,path:*const paths.Path) Error!PathId {
        if(self.paths.items.len>=std.math.maxInt(u32))return error.ResourceLimit;
        var copy=try path.transformed(self.allocator,.{});errdefer copy.deinit();
        try self.paths.append(self.allocator,copy);self.revision+%=1;return self.handle(PathId,self.paths.items.len-1);
    }
    pub fn addClip(self:*Scene,clip:Clip) Error!ClipId {
        if(!clip.transform.finite())return error.InvalidState;
        if(clip.parent)|id|if(!self.validHandle(id,self.clips.items.len))return error.InvalidHandle;
        switch(clip.geometry){.path=>|p|if(!self.validHandle(p.path,self.paths.items.len))return error.InvalidHandle,.image=>|p|try (paints.Paint{.image=p}).validate()}
        if(self.clips.items.len>=std.math.maxInt(u32))return error.ResourceLimit;
        try self.clips.append(self.allocator,clip);self.revision+%=1;return self.handle(ClipId,self.clips.items.len-1);
    }
    pub fn addMesh(self:*Scene,vertices:[]const MeshVertex,indices:[]const u32) Error!MeshId {
        if(indices.len%3!=0)return error.InvalidMesh;
        for(vertices)|vertex|if(!vertex.position.finite() or !vertex.uv.finite() or !vertex.color.valid())return error.InvalidMesh;
        for(indices)|index|if(index>=vertices.len)return error.InvalidMesh;
        if(self.meshes.items.len>=std.math.maxInt(u32))return error.ResourceLimit;
        const copied_vertices=try self.allocator.dupe(MeshVertex,vertices);errdefer self.allocator.free(copied_vertices);
        const copied_indices=try self.allocator.dupe(u32,indices);errdefer self.allocator.free(copied_indices);
        try self.meshes.append(self.allocator,.{.vertices=copied_vertices,.indices=copied_indices});self.revision+%=1;return self.handle(MeshId,self.meshes.items.len-1);
    }
    pub fn fill(self:*Scene,path:PathId,state:State,rule:paths.FillRule) Error!void {try self.checkState(state);if(!self.validHandle(path,self.paths.items.len))return error.InvalidHandle;try self.commands.append(self.allocator,.{.fill=.{.path=path,.paint=state.paint,.state=state,.rule=rule}});self.revision+%=1;}
    pub fn stroke(self:*Scene,path:PathId,state:State) Error!void {try self.checkState(state);if(!self.validHandle(path,self.paths.items.len))return error.InvalidHandle;try self.commands.append(self.allocator,.{.stroke=.{.path=path,.paint=state.paint,.state=state}});self.revision+%=1;}
    pub fn drawMesh(self:*Scene,mesh:MeshId,state:State) Error!void {try self.checkState(state);if(!self.validHandle(mesh,self.meshes.items.len))return error.InvalidHandle;try self.commands.append(self.allocator,.{.mesh=.{.mesh=mesh,.paint=state.paint,.state=state}});self.revision+%=1;}
    pub fn addFilter(self:*Scene,graph:*const filters.Graph) (Error||filters.Error)!FilterId {
        if(self.filters.items.len>=std.math.maxInt(u32))return error.ResourceLimit;
        var copy=try graph.clone(self.allocator);errdefer copy.deinit();try self.filters.append(self.allocator,copy);self.revision+%=1;return self.handle(FilterId,self.filters.items.len-1);
    }
    pub fn drawCustom(self:*Scene,descriptor:Custom,state:State) Error!void {
        try self.checkState(state);if(!validRect(descriptor.bounds) or descriptor.shader==.invalid)return error.InvalidState;
        const uniforms=try self.allocator.alloc(Uniform,descriptor.uniforms.len);var built:usize=0;
        errdefer {for(uniforms[0..built])|uniform|self.allocator.free(uniform.bytes);self.allocator.free(uniforms);}
        for(descriptor.uniforms,uniforms)|input,*output|{output.*=.{.slot=input.slot,.bytes=try self.allocator.dupe(u8,input.bytes)};built+=1;}
        const views=try self.allocator.dupe(gpu.View,descriptor.views);errdefer self.allocator.free(views);
        const samplers=try self.allocator.dupe(gpu.Sampler,descriptor.samplers);errdefer self.allocator.free(samplers);
        try self.custom.ensureUnusedCapacity(self.allocator,1);try self.commands.ensureUnusedCapacity(self.allocator,1);
        const index:u32=@intCast(self.custom.items.len);self.custom.appendAssumeCapacity(.{.shader=descriptor.shader,.uniforms=uniforms,.views=views,.samplers=samplers,.bounds=descriptor.bounds});
        self.commands.appendAssumeCapacity(.{.custom=.{.index=index,.state=state}});self.revision+%=1;
    }
    pub fn beginLayer(self:*Scene,layer:Layer) Error!void {
        if(!std.math.isFinite(layer.opacity) or layer.opacity<0 or layer.opacity>1)return error.InvalidState;
        if(layer.clip)|id|if(!self.validHandle(id,self.clips.items.len))return error.InvalidHandle;
        if(layer.bounds)|bounds|if(!validRect(bounds))return error.InvalidState;
        if(layer.filter)|id|if(!self.validHandle(id,self.filters.items.len))return error.InvalidHandle;
        if(self.layer_depth==std.math.maxInt(u32))return error.ResourceLimit;
        try self.commands.append(self.allocator,.{.begin_layer=layer});self.layer_depth+=1;self.revision+%=1;
    }
    pub fn endLayer(self:*Scene) Error!void {if(self.layer_depth==0)return error.UnbalancedLayers;try self.commands.append(self.allocator,.end_layer);self.layer_depth-=1;self.revision+%=1;}
    pub fn validate(self:*const Scene) Error!void {if(self.layer_depth!=0)return error.UnbalancedLayers;}
    fn checkState(self:*const Scene,state:State) Error!void {
        if(!state.transform.finite() or !std.math.isFinite(state.alpha) or state.alpha<0 or state.alpha>1)return error.InvalidState;
        if(!self.validHandle(state.paint,self.paints.items.len) or !self.validHandle(state.stroke,self.strokes.items.len))return error.InvalidHandle;
        if(state.clip)|id|if(!self.validHandle(id,self.clips.items.len))return error.InvalidHandle;
    }
    fn handle(self:*const Scene,comptime T:type,index:usize) T {return @fromBackingInt((@as(u64,self.identity)<<32)|@as(u64,@intCast(index)));}
    fn validHandle(self:*const Scene,id:anytype,count:usize) bool {return @intFromEnum(id)>>32==self.identity and handleIndex(id)<count;}
    pub fn paintValue(self:*const Scene,id:PaintId) paints.Paint{return self.paints.items[handleIndex(id)].value;}
    pub fn pathValue(self:*const Scene,id:PathId) *const paths.Path{return &self.paths.items[handleIndex(id)];}
    pub fn strokeStyle(self:*const Scene,id:StrokeId) StrokeStyle{return self.strokes.items[handleIndex(id)].value;}
};
pub fn validRect(rect:geo.Rect) bool{return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and rect.width>=0 and rect.height>=0;}


var next_scene_identity:std.atomic.Value(u32)=.init(1);
fn nextIdentity() error{ResourceLimit}!u32 {
    var current=next_scene_identity.load(.monotonic);
    while(current!=std.math.maxInt(u32)){
        if(next_scene_identity.cmpxchgWeak(current,current+1,.monotonic,.monotonic))|actual|current=actual else return current;
    }
    return error.ResourceLimit;
}
pub fn handleIndex(id:anytype) usize {return @intCast(@as(u32,@truncate(@intFromEnum(id))));}
