//! CPU packing of paint/mesh metadata. Shader parameters are rebased in f64
//! before narrowing, retaining precision for large translated world coordinates.
const std=@import("std");const gpu=@import("gpu");
const paints=@import("paint.zig");const colors=@import("color.zig");const geo=@import("geometry.zig");const scenes=@import("scene.zig");const prepared=@import("prepared.zig");const resources=@import("gpu_resources.zig");const atlas=@import("atlas.zig");
pub const Working=enum{linear_srgb,srgb};
pub const Parameters=extern struct{data:[16][4]f32=@splat(.{0,0,0,0})};
pub const Material=struct{parameters:Parameters,image:resources.ImageBinding};
pub const Error=resources.Error||paints.Error||std.mem.Allocator.Error||error{InvalidMaterial};
pub const Tables=struct{
    stops:atlas.Table,meshes:atlas.Table,indices:atlas.Table,
    pub fn init(allocator:std.mem.Allocator) Tables{return .{.stops=atlas.Table.init(allocator),.meshes=atlas.Table.init(allocator),.indices=atlas.Table.init(allocator)};}
    pub fn deinit(self:*Tables) void {self.stops.deinit();self.meshes.deinit();self.indices.deinit();self.*=undefined;}
};
pub fn make(device:*gpu.Device,images:*resources.Images,tables:*Tables,paint:paints.Paint,transform:geo.Affine,mask:prepared.Mask,alpha:f64,working:Working,white:resources.ImageBinding) Error!Material {
    try paint.validate();var result:Material=.{.parameters=.{},.image=white};const data=&result.parameters.data;
    data[0][2]=if(working==.srgb)1 else 0;data[0][1]=try number(alpha);
    switch(mask){.empty=>{},.rectangle=>|r|{data[0][3]=0;data[4]=.{try number(r.x),try number(r.y),try number(r.x+r.width),try number(r.y+r.height)};},.atlas=>|m|{data[0][3]=1;data[4]=.{@floatFromInt(m.bounds.x),@floatFromInt(m.bounds.y),@floatFromInt(@as(i64,m.bounds.x)+m.bounds.width),@floatFromInt(@as(i64,m.bounds.y)+m.bounds.height)};data[5][0]=@floatFromInt(m.region.x);data[5][1]=@floatFromInt(m.region.y);}}
    const space:colors.Space=if(working==.srgb).srgb else .linear_srgb;
    switch(paint){
        .solid=>|color|{const p=color.converted(.linear_srgb,space).premultiplied();data[0][0]=0;data[3]=.{try number(p.r),try number(p.g),try number(p.b),try number(p.a)};},
        .linear=>|g|{
            data[0][0]=1;try gradient(tables,&result.parameters,g.gradient);
            const inverse=geo.Affine.mul(transform,g.gradient.transform).inverse() catch {data[0][0]=0;data[3]=.{0,0,0,0};return result;};
            const dx=g.end.x-g.start.x;const dy=g.end.y-g.start.y;const length2=dx*dx+dy*dy;
            if(length2==0){data[1]=.{0,0,1,0};data[2]=.{0,0,0,0};}else{
                data[1]=.{try number((inverse.a*dx+inverse.b*dy)/length2),try number((inverse.c*dx+inverse.d*dy)/length2),try number(((inverse.tx-g.start.x)*dx+(inverse.ty-g.start.y)*dy)/length2),0};
            }
            data[0][1]*=try number(g.gradient.opacity);
        },
        .radial=>|g|{
            data[0][0]=2;try gradient(tables,&result.parameters,g.gradient);const inverse=geo.Affine.mul(transform,g.gradient.transform).inverse() catch {data[0][0]=0;data[3]=.{0,0,0,0};return result;};
            const scale=@max(@max(g.start_radius,g.end_radius),std.math.hypot(g.end.x-g.start.x,g.end.y-g.start.y));
            const divisor=if(scale==0)1 else scale;try affine(data,inverse,g.start,divisor);
            data[7][2]=try number(g.start_radius/divisor);data[7][3]=try number(g.end_radius/divisor);data[8][0]=try number((g.end.x-g.start.x)/divisor);data[8][1]=try number((g.end.y-g.start.y)/divisor);data[0][1]*=try number(g.gradient.opacity);
        },
        .conic=>|g|{
            data[0][0]=3;try gradient(tables,&result.parameters,g.gradient);const inverse=geo.Affine.mul(transform,g.gradient.transform).inverse() catch {data[0][0]=0;data[3]=.{0,0,0,0};return result;};try affine(data,inverse,g.center,1);
            data[8][2]=try number(@mod(g.start_angle,2.0*std.math.pi));data[8][3]=try number(g.sweep_angle);data[0][1]*=try number(g.gradient.opacity);
        },
        .image=>|pattern|{
            data[0][0]=4;result.image=try images.resolve(device,pattern.image);
            const inverse=geo.Affine.mul(transform,pattern.transform).inverse() catch {data[0][0]=0;data[3]=.{0,0,0,0};return result;};try affine(data,inverse,.{},1);
            const region=pattern.region orelse @import("image.zig").Region{.width=result.image.width,.height=result.image.height};
            data[9]=.{@floatFromInt(region.x),@floatFromInt(region.y),@floatFromInt(region.width),@floatFromInt(region.height)};
            data[10]=.{@floatFromInt(@intFromEnum(pattern.sampling.filter)),@floatFromInt(@intFromEnum(pattern.sampling.extend_x)),@floatFromInt(@intFromEnum(pattern.sampling.extend_y)),if(result.image.flip_y)1 else 0};
            data[11]=.{@floatFromInt(result.image.width),@floatFromInt(result.image.height),@floatFromInt(@intFromEnum(result.image.space)),@floatFromInt(@intFromEnum(result.image.alpha))};
            data[14]=.{try number(pattern.sampling.lod),@floatFromInt(@intFromEnum(pattern.sampling.mip_filter)),@floatFromInt(result.image.mips),0};data[0][1]*=try number(pattern.opacity);
        },
    }
    return result;
}
fn gradient(tables:*Tables,parameters:*Parameters,g:paints.Gradient) Error!void {
    const first=tables.stops.texels.items.len;
    for(g.stops)|stop|{
        var color=stop.color;var channels:[3]f64=undefined;
        switch(g.interpolation){.linear_srgb=>channels=.{color.r,color.g,color.b},.srgb=>channels=.{colors.encodeSrgb(color.r),colors.encodeSrgb(color.g),colors.encodeSrgb(color.b)},.oklab=>channels=colors.toOklab(color)}
        _ =try tables.stops.append(&.{.{try number(stop.offset),0,0,0},.{try number(channels[0]*color.a),try number(channels[1]*color.a),try number(channels[2]*color.a),try number(color.a)}});
    }
    parameters.data[6][0]=@floatFromInt(first);parameters.data[6][1]=@floatFromInt(g.stops.len);parameters.data[6][2]=@floatFromInt(@intFromEnum(g.extend));parameters.data[3][3]=@floatFromInt(@intFromEnum(g.interpolation));
}
fn affine(data:*[16][4]f32,inverse:geo.Affine,origin:geo.Point,scale:f64) Error!void {data[1]=.{try number(inverse.a/scale),try number(inverse.c/scale),try number((inverse.tx-origin.x)/scale),0};data[2]=.{try number(inverse.b/scale),try number(inverse.d/scale),try number((inverse.ty-origin.y)/scale),0};}
pub fn number(value:f64) error{NumericRange}!f32 {if(!std.math.isFinite(value) or @abs(value)>std.math.floatMax(f32))return error.NumericRange;return @floatCast(value);}
pub fn setMesh(tables:*Tables,material:*Material,mesh:scenes.Mesh,transform:geo.Affine,width:u32,height:u32,allocator:std.mem.Allocator) Error!void {
    const count=mesh.indices.len/3;if(count==0)return;if(count>(1<<20))return error.ResourceLimit;
    const first=tables.meshes.texels.items.len;const tile_size:u32=16;const columns=(width+tile_size-1)/tile_size;const rows=(height+tile_size-1)/tile_size;
    const bins=try allocator.alloc(std.ArrayList(u32),@as(usize,columns)*rows);defer {for(bins)|*bin|bin.deinit(allocator);allocator.free(bins);}@memset(bins,.empty);
    for(0..count)|triangle|{
        var positions:[3]geo.Point=undefined;var uv:[3]geo.Point=undefined;var colors_:[3][4]f32=undefined;
        for(0..3)|i|{const vertex=mesh.vertices[mesh.indices[triangle*3+i]];positions[i]=transform.point(vertex.position);uv[i]=vertex.uv;const color=vertex.color.premultiplied();colors_[i]=.{try number(color.r),try number(color.g),try number(color.b),try number(color.a)};}
        _ =try tables.meshes.append(&.{.{try number(positions[0].x),try number(positions[0].y),try number(positions[1].x),try number(positions[1].y)},.{try number(positions[2].x),try number(positions[2].y),try number(uv[2].x),try number(uv[2].y)},.{try number(uv[0].x),try number(uv[0].y),try number(uv[1].x),try number(uv[1].y)},colors_[0],colors_[1],colors_[2]});
        const min_x=@min(positions[0].x,@min(positions[1].x,positions[2].x))-1;const max_x=@max(positions[0].x,@max(positions[1].x,positions[2].x))+1;const min_y=@min(positions[0].y,@min(positions[1].y,positions[2].y))-1;const max_y=@max(positions[0].y,@max(positions[1].y,positions[2].y))+1;
        if(max_x<0 or max_y<0 or min_x>=width or min_y>=height)continue;
        const x0:usize=@intFromFloat(std.math.clamp(@floor(min_x/tile_size),0,@as(f64,@floatFromInt(columns-1))));const x1:usize=@intFromFloat(std.math.clamp(@floor(max_x/tile_size),0,@as(f64,@floatFromInt(columns-1))));const y0:usize=@intFromFloat(std.math.clamp(@floor(min_y/tile_size),0,@as(f64,@floatFromInt(rows-1))));const y1:usize=@intFromFloat(std.math.clamp(@floor(max_y/tile_size),0,@as(f64,@floatFromInt(rows-1))));
        for(y0..y1+1)|y|for(x0..x1+1)|x|try bins[y*columns+x].append(allocator,@intCast(triangle));
    }
    const ranges=tables.indices.texels.items.len;try tables.indices.texels.ensureUnusedCapacity(tables.indices.allocator,bins.len);const range_start=tables.indices.texels.items.len;for(bins)|_|tables.indices.texels.appendAssumeCapacity(.{0,0,0,0});const entries=tables.indices.texels.items.len;var offset:usize=0;
    for(bins,0..)|bin,index|{tables.indices.texels.items[range_start+index]=.{@floatFromInt(offset),@floatFromInt(bin.items.len),0,0};for(bin.items)|triangle|_ =try tables.indices.append(&.{.{@floatFromInt(triangle),0,0,0}});offset+=bin.items.len;}
    material.parameters.data[12]=.{@floatFromInt(first),@floatFromInt(count),@floatFromInt(ranges),@floatFromInt(tile_size)};material.parameters.data[13]=.{@floatFromInt(columns),@floatFromInt(rows),@floatFromInt(entries),0};
}
