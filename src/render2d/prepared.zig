//! Scene-to-GPU preparation. Geometry/clip coverage is computed before any GPU
//! pass, then packed into a shared atlas. Paint evaluation remains on the GPU.
const std=@import("std");
const scenes=@import("scene.zig");const paths=@import("path.zig");const geo=@import("geometry.zig");
const coverage=@import("coverage.zig");const regions=@import("coverage_region.zig");const strokes=@import("stroke.zig");const atlas=@import("atlas.zig");const paints=@import("paint.zig");
pub const Frame=struct{width:u32,height:u32,view:geo.Affine=.{},tolerance:f64=1.0/256.0,max_clip_depth:usize=128,max_points:usize=1<<20,max_mask_pixels:usize=64*1024*1024,max_pair_tests:usize=16*1024*1024};
pub const Mask=union(enum){empty,rectangle:geo.Rect,atlas:struct{region:atlas.Region,bounds:coverage.Clip}};
pub const ImageClip=struct{pattern:paints.Pattern,transform:geo.Affine,inverse:bool};
pub const Draw=struct{mask:Mask,image_clips:[]ImageClip,state:scenes.State,paint:scenes.PaintId,mesh:?scenes.MeshId=null};
pub const Layer=struct{descriptor:scenes.Layer,mask:Mask,image_clips:[]ImageClip};
pub const Custom=struct{index:u32,mask:Mask,image_clips:[]ImageClip,state:scenes.State};
pub const Command=union(enum){draw:Draw,begin_layer:Layer,end_layer,custom:Custom};
pub const Error=scenes.Error||paths.FlattenError||strokes.Error||regions.Error||atlas.Error||error{InvalidFrame,ClipLimit};
pub const Prepared=struct{
    allocator:std.mem.Allocator,scene:*const scenes.Scene,frame:Frame,masks:atlas.MaskAtlas,commands:std.ArrayList(Command)=.empty,
    pub fn deinit(self:*Prepared) void {for(self.commands.items)|command|switch(command){.draw=>|d|self.allocator.free(d.image_clips),.begin_layer=>|l|self.allocator.free(l.image_clips),.custom=>|c|self.allocator.free(c.image_clips),else=>{}};self.commands.deinit(self.allocator);self.masks.deinit();self.*=undefined;}
};
const Geometry=struct{
    allocator:std.mem.Allocator,flats:std.ArrayList(paths.FlatPath)=.empty,rules:std.ArrayList(paths.FillRule)=.empty,program:std.ArrayList(regions.Instruction)=.empty,image_clips:std.ArrayList(ImageClip)=.empty,bounds:?geo.Bounds=null,
    fn init(allocator:std.mem.Allocator) Geometry{return .{.allocator=allocator};}
    fn deinit(self:*Geometry) void {for(self.flats.items)|*flat|flat.deinit();self.flats.deinit(self.allocator);self.rules.deinit(self.allocator);self.program.deinit(self.allocator);self.image_clips.deinit(self.allocator);}
    fn add(self:*Geometry,path:*const paths.Path,transform:geo.Affine,rule:paths.FillRule,frame:Frame,include_bounds:bool) Error!u16 {
        if(self.flats.items.len>=std.math.maxInt(u16))return error.ClipLimit;
        var flat=try paths.flatten(path,self.allocator,.{.transform=transform,.tolerance=frame.tolerance,.max_points=frame.max_points});errdefer flat.deinit();
        if(include_bounds)if(flat.bounds())|bounds|{if(self.bounds)|*current|{current.include(bounds.min);current.include(bounds.max);}else self.bounds=bounds;};
        try self.flats.ensureUnusedCapacity(self.allocator,1);try self.rules.ensureUnusedCapacity(self.allocator,1);
        const index:u16=@intCast(self.flats.items.len);self.flats.appendAssumeCapacity(flat);self.rules.appendAssumeCapacity(rule);return index;
    }
    fn instruction(self:*Geometry,instruction:regions.Instruction) !void {try self.program.append(self.allocator,instruction);}
};
pub fn compile(scene:*const scenes.Scene,allocator:std.mem.Allocator,frame:Frame,atlas_options:atlas.Options) Error!Prepared {
    try scene.validate();if(frame.width==0 or frame.height==0 or frame.width>std.math.maxInt(i32) or frame.height>std.math.maxInt(i32) or !frame.view.finite() or !std.math.isFinite(frame.tolerance) or frame.tolerance<=0)return error.InvalidFrame;
    var result:Prepared=.{.allocator=allocator,.scene=scene,.frame=frame,.masks=atlas.MaskAtlas.init(allocator,atlas_options)};errdefer result.deinit();
    var layers:std.ArrayList(?scenes.ClipId)=.empty;defer layers.deinit(allocator);
    for(scene.commands.items)|command|{
        const excluded=if(layers.items.len==0)null else layers.items[layers.items.len-1];
        switch(command){
            .fill=>|draw|{
                var geometry=Geometry.init(allocator);defer geometry.deinit();
                const shape=try geometry.add(scene.pathValue(draw.path),geo.Affine.mul(frame.view,draw.state.transform),draw.rule,frame,true);try geometry.instruction(.{.input=shape});
                try addClips(&geometry,scene,draw.state.clip,excluded,frame);
                const mask=try pack(&result,&geometry);const clips=try allocator.dupe(ImageClip,geometry.image_clips.items);errdefer allocator.free(clips);
                try result.commands.append(allocator,.{.draw=.{.mask=mask,.image_clips=clips,.state=draw.state,.paint=draw.paint}});
            },
            .stroke=>|draw|{
                var geometry=Geometry.init(allocator);defer geometry.deinit();const style=scene.strokeStyle(draw.state.stroke);
                try addStroke(&geometry,scene.pathValue(draw.path),style,geo.Affine.mul(frame.view,draw.state.transform),frame);
                try addClips(&geometry,scene,draw.state.clip,excluded,frame);const mask=try pack(&result,&geometry);
                const clips=try allocator.dupe(ImageClip,geometry.image_clips.items);errdefer allocator.free(clips);
                try result.commands.append(allocator,.{.draw=.{.mask=mask,.image_clips=clips,.state=draw.state,.paint=draw.paint}});
            },
            .mesh=>|draw|{
                const mesh=scene.meshes.items[scenes.handleIndex(draw.mesh)];var path=paths.Path.init(allocator);defer path.deinit();
                for(0..mesh.indices.len/3)|triangle|{var points=[3]geo.Point{mesh.vertices[mesh.indices[triangle*3]].position,mesh.vertices[mesh.indices[triangle*3+1]].position,mesh.vertices[mesh.indices[triangle*3+2]].position};const area=(points[1].x-points[0].x)*(points[2].y-points[0].y)-(points[1].y-points[0].y)*(points[2].x-points[0].x);if(area<0)std.mem.reverse(geo.Point,&points);if(area!=0)try path.addPolygon(&points,true);}
                var geometry=Geometry.init(allocator);defer geometry.deinit();const shape=try geometry.add(&path,geo.Affine.mul(frame.view,draw.state.transform),.nonzero,frame,true);try geometry.instruction(.{.input=shape});try addClips(&geometry,scene,draw.state.clip,excluded,frame);
                const mask=try pack(&result,&geometry);const clips=try allocator.dupe(ImageClip,geometry.image_clips.items);errdefer allocator.free(clips);
                try result.commands.append(allocator,.{.draw=.{.mask=mask,.image_clips=clips,.state=draw.state,.paint=draw.paint,.mesh=draw.mesh}});
            },
            .begin_layer=>|layer|{
                var geometry=Geometry.init(allocator);defer geometry.deinit();var path=paths.Path.init(allocator);defer path.deinit();
                if(layer.bounds)|bounds|{try path.addRect(bounds);_ =try geometry.add(&path,geo.Affine.mul(frame.view,layer.transform),.nonzero,frame,true);}else{try path.addRect(.{.width=@floatFromInt(frame.width),.height=@floatFromInt(frame.height)});_ =try geometry.add(&path,.{},.nonzero,frame,true);}
                try geometry.instruction(.{.input=0});try addClips(&geometry,scene,layer.clip,excluded,frame);const mask=try pack(&result,&geometry);const clips=try allocator.dupe(ImageClip,geometry.image_clips.items);errdefer allocator.free(clips);
                try layers.ensureUnusedCapacity(allocator,1);try result.commands.append(allocator,.{.begin_layer=.{.descriptor=layer,.mask=mask,.image_clips=clips}});layers.appendAssumeCapacity(layer.clip);
            },
            .end_layer=>{if(layers.items.len==0)return error.UnbalancedLayers;layers.items.len-=1;try result.commands.append(allocator,.end_layer);},
            .custom=>|custom|{
                var path=paths.Path.init(allocator);defer path.deinit();try path.addRect(scene.custom.items[custom.index].bounds);
                var geometry=Geometry.init(allocator);defer geometry.deinit();const index=try geometry.add(&path,geo.Affine.mul(frame.view,custom.state.transform),.nonzero,frame,true);try geometry.instruction(.{.input=index});try addClips(&geometry,scene,custom.state.clip,excluded,frame);
                const mask=try pack(&result,&geometry);const clips=try allocator.dupe(ImageClip,geometry.image_clips.items);errdefer allocator.free(clips);
                try result.commands.append(allocator,.{.custom=.{.index=custom.index,.mask=mask,.image_clips=clips,.state=custom.state}});
            },
        }
    }
    if(layers.items.len!=0)return error.UnbalancedLayers;return result;
}
fn addClips(geometry:*Geometry,scene:*const scenes.Scene,first:?scenes.ClipId,excluded:?scenes.ClipId,frame:Frame) Error!void {
    var current=first;var count:usize=0;
    while(current)|id|{
        if(excluded!=null and id==excluded.?)break;if(count==frame.max_clip_depth)return error.ClipLimit;count+=1;
        const clip=scene.clips.items[scenes.handleIndex(id)];const transform=geo.Affine.mul(frame.view,clip.transform);
        switch(clip.geometry){
            .path=>|p|{const index=try geometry.add(scene.pathValue(p.path),transform,p.rule,frame,false);try geometry.instruction(.{.input=index});if(clip.inverse)try geometry.instruction(.invert);try geometry.instruction(.intersection);},
            .image=>|pattern|try geometry.image_clips.append(geometry.allocator,.{.pattern=pattern,.transform=transform,.inverse=clip.inverse}),
        }
        current=clip.parent;
    }
}
fn addStroke(geometry:*Geometry,path:*const paths.Path,style:scenes.StrokeStyle,transform:geo.Affine,frame:Frame) Error!void {
    var options=style.geometry;options.transform=geo.Affine.mul(transform,options.transform);options.tolerance=frame.tolerance;options.max_points=frame.max_points;
    if(style.alignment==0.5){var outline=try strokes.outline(path,geometry.allocator,options);defer outline.deinit();const index=try geometry.add(&outline,.{},.nonzero,frame,true);try geometry.instruction(.{.input=index});return;}
    var closed=try path.selected(geometry.allocator,true);defer closed.deinit();var open=try path.selected(geometry.allocator,false);defer open.deinit();
    const closed_fill=try geometry.add(&closed,options.transform,style.fill_rule,frame,false);
    var inner_options=options;inner_options.width=2*options.width*style.alignment;var inner=try strokes.outline(&closed,geometry.allocator,inner_options);defer inner.deinit();const inside=try geometry.add(&inner,.{},.nonzero,frame,true);
    var outer_options=options;outer_options.width=2*options.width*(1-style.alignment);var outer=try strokes.outline(&closed,geometry.allocator,outer_options);defer outer.deinit();const outside=try geometry.add(&outer,.{},.nonzero,frame,true);
    var middle=try strokes.outline(&open,geometry.allocator,options);defer middle.deinit();const open_index=try geometry.add(&middle,.{},.nonzero,frame,true);
    for([_]regions.Instruction{.{.input=inside},.{.input=closed_fill},.intersection,.{.input=outside},.{.input=closed_fill},.subtract,.union_,.{.input=open_index},.union_})|instruction|try geometry.instruction(instruction);
}
fn pack(result:*Prepared,geometry:*Geometry) Error!Mask {
    if(geometry.bounds==null)return .empty;
    // Axis-aligned rectangles and rectangle-only intersections are analytic in
    // the paint shader, avoiding full-frame mask allocation for common UI fills.
    if(tryRectangle(geometry))|rectangle|return .{.rectangle=clampRect(rectangle,result.frame)};
    const bounds=boundsClip(geometry.bounds.?,result.frame);if(bounds.width<=0 or bounds.height<=0)return .empty;
    const inputs=try result.allocator.alloc(regions.Input,geometry.flats.items.len);defer result.allocator.free(inputs);
    for(inputs,geometry.flats.items,geometry.rules.items)|*input,*flat,rule|input.*=.{.path=flat,.rule=rule};
    var mask=try regions.rasterize(inputs,geometry.program.items,result.allocator,.{.width=@intCast(result.frame.width),.height=@intCast(result.frame.height)},.{.bounds=bounds,.coverage=.{.max_pixels=result.frame.max_mask_pixels,.max_pair_tests=result.frame.max_pair_tests}});defer mask.deinit();
    var nonzero=false;var full=true;for(mask.pixels)|value|{if(value!=0)nonzero=true;if(value!=1)full=false;}
    if(!nonzero)return .empty;if(full)return .{.rectangle=.{.x=@floatFromInt(bounds.x),.y=@floatFromInt(bounds.y),.width=@floatFromInt(bounds.width),.height=@floatFromInt(bounds.height)}};
    return .{.atlas=.{.region=try result.masks.add(&mask),.bounds=mask.bounds}};
}
fn tryRectangle(geometry:*const Geometry) ?geo.Rect {
    // Accept only the generated input / input intersection chain, not arbitrary
    // boolean expressions where box intersection would change the shape.
    var stack:[256]geo.Rect=undefined;var depth:usize=0;
    for(geometry.program.items)|instruction|switch(instruction){
        .input=>|index|{if(depth==stack.len)return null;stack[depth]=flatRectangle(&geometry.flats.items[index]) orelse return null;depth+=1;},
        .intersection=>{if(depth<2)return null;const b=stack[depth-1];const a=stack[depth-2];depth-=1;const x=@max(a.x,b.x);const y=@max(a.y,b.y);stack[depth-1]=.{.x=x,.y=y,.width=@max(0,@min(a.x+a.width,b.x+b.width)-x),.height=@max(0,@min(a.y+a.height,b.y+b.height)-y)};},
        else=>return null,
    };
    return if(depth==1)stack[0] else null;
}
fn flatRectangle(flat:*const paths.FlatPath) ?geo.Rect {
    if(flat.contours.items.len!=1)return null;var points=flat.contourPoints(flat.contours.items[0]);if(points.len==5 and points[0].eql(points[4]))points=points[0..4];if(points.len!=4)return null;
    for(0..4)|i|{const a=points[i];const b=points[(i+1)%4];if(a.x!=b.x and a.y!=b.y)return null;}
    const bounds=flat.bounds().?;const width=bounds.max.x-bounds.min.x;const height=bounds.max.y-bounds.min.y;if(width<=0 or height<=0)return null;
    // Reject collinear/backtracking four-point contours with a box-shaped bbox.
    var area:f64=0;for(0..4)|i|{const a=points[i];const b=points[(i+1)%4];area+=(a.x-bounds.min.x)*(b.y-bounds.min.y)-(b.x-bounds.min.x)*(a.y-bounds.min.y);}
    if(@abs(area)!=2*width*height)return null;return .{.x=bounds.min.x,.y=bounds.min.y,.width=width,.height=height};
}
fn clampRect(rect:geo.Rect,frame:Frame) geo.Rect {const x=std.math.clamp(rect.x,0,@as(f64,@floatFromInt(frame.width)));const y=std.math.clamp(rect.y,0,@as(f64,@floatFromInt(frame.height)));const right=std.math.clamp(rect.x+rect.width,0,@as(f64,@floatFromInt(frame.width)));const bottom=std.math.clamp(rect.y+rect.height,0,@as(f64,@floatFromInt(frame.height)));return .{.x=x,.y=y,.width=@max(0,right-x),.height=@max(0,bottom-y)};}
fn boundsClip(bounds:geo.Bounds,frame:Frame) coverage.Clip {const rect=clampRect(.{.x=@floor(bounds.min.x),.y=@floor(bounds.min.y),.width=@ceil(bounds.max.x)-@floor(bounds.min.x),.height=@ceil(bounds.max.y)-@floor(bounds.min.y)},frame);return .{.x=@intFromFloat(rect.x),.y=@intFromFloat(rect.y),.width=@intFromFloat(rect.width),.height=@intFromFloat(rect.height)};}
