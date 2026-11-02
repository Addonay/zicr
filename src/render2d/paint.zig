//! Paint values are borrowed descriptors. Scene recording snapshots stops and
//! retains image references, so callers can release temporary descriptor arrays.
const std=@import("std");
const geo=@import("geometry.zig");
const colors=@import("color.zig");
const images=@import("image.zig");
const gpu=@import("gpu");
pub const Stop=struct{offset:f64,color:colors.Color};
pub const Extend=enum{pad,repeat,reflect,transparent};
pub const Interpolation=enum{linear_srgb,srgb,oklab};
pub const Gradient=struct{
    stops:[]const Stop,
    extend:Extend=.pad,
    interpolation:Interpolation=.linear_srgb,
    /// Paint-to-user transform; scene geometry transforms compose after it.
    transform:geo.Affine=.{},
    opacity:f64=1,
    pub fn validate(g:Gradient) Error!void {
        if(!g.transform.finite() or !std.math.isFinite(g.opacity) or g.opacity<0 or g.opacity>1)return error.InvalidPaint;
        var previous:f64=-std.math.inf(f64);
        for(g.stops)|stop|{if(!std.math.isFinite(stop.offset) or stop.offset<previous or !stop.color.valid())return error.InvalidStops;previous=stop.offset;}
    }
    pub fn at(g:Gradient,position:f64) colors.Pixel {
        if(g.stops.len==0 or !std.math.isFinite(position))return .{};
        if(g.stops.len==1)return g.stops[0].color.premultiplied().scaled(g.opacity);
        const first=g.stops[0].offset;const last=g.stops[g.stops.len-1].offset;
        var t=position;
        if(last>first)switch(g.extend){
            .pad=>t=std.math.clamp(t,first,last),
            .repeat=>t=first+@mod(t-first,last-first),
            .reflect=>{const period=2*(last-first);const v=@mod(t-first,period);t=first+if(v<=last-first)v else period-v;},
            .transparent=>if(t<first or t>last)return .{},
        };
        // upper_bound makes the last duplicate stop own its exact offset.
        var low:usize=0;var high=g.stops.len;
        while(low<high){const middle=low+(high-low)/2;if(g.stops[middle].offset<=t)low=middle+1 else high=middle;}
        if(low==0)return g.stops[0].color.premultiplied().scaled(g.opacity);
        if(low==g.stops.len)return g.stops[low-1].color.premultiplied().scaled(g.opacity);
        const a=g.stops[low-1];const b=g.stops[low];
        if(a.offset==b.offset)return b.color.premultiplied().scaled(g.opacity);
        const u=std.math.clamp((t-a.offset)/(b.offset-a.offset),0,1);
        return interpolate(a.color,b.color,u,g.interpolation).scaled(g.opacity);
    }
};
pub const Linear=struct{gradient:Gradient,start:geo.Point,end:geo.Point};
/// Two-circle radial gradient. Focal gradients use start_radius=0 and start
/// as the focal point; ordinary radial gradients use coincident centers.
pub const Radial=struct{gradient:Gradient,start:geo.Point=.{},end:geo.Point=.{},start_radius:f64=0,end_radius:f64=1};
pub const Conic=struct{gradient:Gradient,center:geo.Point=.{},start_angle:f64=0,sweep_angle:f64=2.0*std.math.pi};
pub const ImageSource=union(enum){
    pixels:*const images.Image,
    borrowed:struct{view:gpu.View,width:u32,height:u32,space:colors.Space=.linear_srgb,alpha:images.Alpha=.premultiplied,flip_y:bool=false},
};
pub const Pattern=struct{
    image:ImageSource,
    region:?images.Region=null,
    transform:geo.Affine=.{},
    sampling:images.Sampling=.{},
    opacity:f64=1,
};
pub const Paint=union(enum){
    solid:colors.Color,linear:Linear,radial:Radial,conic:Conic,image:Pattern,
    pub fn validate(p:Paint) Error!void {
        switch(p){
            .solid=>|c|if(!c.valid())return error.InvalidPaint,
            .linear=>|g|{try g.gradient.validate();if(!g.start.finite() or !g.end.finite())return error.InvalidPaint;},
            .radial=>|g|{try g.gradient.validate();if(!g.start.finite() or !g.end.finite() or !std.math.isFinite(g.start_radius) or !std.math.isFinite(g.end_radius) or g.start_radius<0 or g.end_radius<0)return error.InvalidPaint;},
            .conic=>|g|{try g.gradient.validate();if(!g.center.finite() or !std.math.isFinite(g.start_angle) or !std.math.isFinite(g.sweep_angle) or g.sweep_angle==0)return error.InvalidPaint;},
            .image=>|pattern|{
                if(!pattern.transform.finite() or !std.math.isFinite(pattern.opacity) or pattern.opacity<0 or pattern.opacity>1)return error.InvalidPaint;
                const size=imageSize(pattern.image);if(size[0]==0 or size[1]==0)return error.InvalidPaint;
                if(pattern.region)|r|if(r.width==0 or r.height==0 or r.x>size[0] or r.y>size[1] or r.width>size[0]-r.x or r.height>size[1]-r.y)return error.InvalidPaint;
            },
        }
    }
    pub fn stopSlice(p:Paint) []const Stop {return switch(p){.linear=>|g|g.gradient.stops,.radial=>|g|g.gradient.stops,.conic=>|g|g.gradient.stops,else=>&.{}};}
    pub fn withStops(p:Paint,stops:[]const Stop) Paint {var result=p;switch(result){.linear=>|*g|g.gradient.stops=stops,.radial=>|*g|g.gradient.stops=stops,.conic=>|*g|g.gradient.stops=stops,else=>{}}return result;}
    pub fn transform(p:Paint) geo.Affine {return switch(p){.solid=>.{},.linear=>|g|g.gradient.transform,.radial=>|g|g.gradient.transform,.conic=>|g|g.gradient.transform,.image=>|g|g.transform};}
    pub fn evaluated(p:Paint,point:geo.Point) Error!colors.Pixel {
        try p.validate();
        const local=if(p==.solid)point else (p.transform().inverse() catch return .{}).point(point);
        if(!local.finite())return error.InvalidPaint;
        return switch(p){
            .solid=>|c|c.premultiplied(),
            .linear=>|g|blk:{const dx=g.end.x-g.start.x;const dy=g.end.y-g.start.y;const length2=dx*dx+dy*dy;break :blk g.gradient.at(if(length2==0)1 else ((local.x-g.start.x)*dx+(local.y-g.start.y)*dy)/length2);},
            .radial=>|g|blk:{const t=radialParameter(g,local) orelse break :blk .{};break :blk g.gradient.at(t);},
            .conic=>|g|blk:{const angle=std.math.atan2(local.y-g.center.y,local.x-g.center.x)-g.start_angle;const phase=if(g.sweep_angle>0)@mod(angle,2.0*std.math.pi) else -@mod(-angle,2.0*std.math.pi);break :blk g.gradient.at(phase/g.sweep_angle);},
            .image=>|pattern|blk:{
                const image=if(pattern.image==.pixels)pattern.image.pixels else return error.MissingCpuImage;
                if(pattern.region)|r|{
                    // Region-local filtering cannot bleed into adjacent atlas cells.
                    break :blk sampleRegion(image,r,local,pattern.sampling).scaled(pattern.opacity);
                }
                break :blk (image.sample(local.x,local.y,pattern.sampling) catch return error.InvalidPaint).scaled(pattern.opacity);
            },
        };
    }
};
pub const Error=error{InvalidPaint,InvalidStops,MissingCpuImage};
pub fn imageSize(image:ImageSource) [2]u32{return switch(image){.pixels=>|p|.{p.width(),p.height()},.borrowed=>|p|.{p.width,p.height}};}
fn interpolate(a:colors.Color,b:colors.Color,t:f64,space:Interpolation) colors.Pixel {
    if(space==.linear_srgb)return colors.Pixel.lerp(a.premultiplied(),b.premultiplied(),t);
    const alpha=a.a*(1-t)+b.a*t;if(alpha==0)return .{};
    var av:[3]f64=undefined;var bv:[3]f64=undefined;
    if(space==.oklab){av=colors.toOklab(a);bv=colors.toOklab(b);}else{av=.{colors.encodeSrgb(a.r),colors.encodeSrgb(a.g),colors.encodeSrgb(a.b)};bv=.{colors.encodeSrgb(b.r),colors.encodeSrgb(b.g),colors.encodeSrgb(b.b)};}
    var v:[3]f64=undefined;for(&v,av,bv)|*out,x,y|out.*=(x*a.a*(1-t)+y*b.a*t)/alpha;
    return if(space==.oklab)colors.fromOklab(v,alpha).premultiplied() else (colors.Color{.r=colors.decodeSrgb(v[0]),.g=colors.decodeSrgb(v[1]),.b=colors.decodeSrgb(v[2]),.a=alpha}).premultiplied();
}
fn radialParameter(g:Radial,p:geo.Point) ?f64 {
    const dx=g.end.x-g.start.x;const dy=g.end.y-g.start.y;const dr=g.end_radius-g.start_radius;
    const px=p.x-g.start.x;const py=p.y-g.start.y;
    const a=dx*dx+dy*dy-dr*dr;const b=-2*(px*dx+py*dy+g.start_radius*dr);const c=px*px+py*py-g.start_radius*g.start_radius;
    if(a==0){if(b==0)return if(c==0)0 else null;const t=-c/b;return if(g.start_radius+t*dr>=0)t else null;}
    const discriminant=b*b-4*a*c;if(discriminant<0)return null;
    const root=@sqrt(discriminant);const q=-0.5*(b+std.math.copysign(root,b));
    const t0=if(q==0)-b/(2*a) else q/a;const t1=if(q==0)t0 else c/q;
    const v0=g.start_radius+t0*dr>=0;const v1=g.start_radius+t1*dr>=0;
    if(!v0 and !v1)return null;if(!v0)return t1;if(!v1)return t0;return @max(t0,t1);
}
fn sampleRegion(image:*const images.Image,region:images.Region,p:geo.Point,sampling:images.Sampling) colors.Pixel {
    // Reference path samples an isolated logical view without copying pixels.
    const rx=regionCoordinate(p.x,region.width,sampling.extend_x);const ry=regionCoordinate(p.y,region.height,sampling.extend_y);
    if(rx==null or ry==null)return .{};
    const x=rx.?;const y=ry.?;
    if(sampling.filter==.nearest)return regionTexel(image,region,@intFromFloat(@floor(x)),@intFromFloat(@floor(y)),sampling);
    const xx=x-0.5;const yy=y-0.5;const ix:i64=@intFromFloat(@floor(xx));const iy:i64=@intFromFloat(@floor(yy));
    if(sampling.filter==.linear){const u=xx-@floor(xx);const v=yy-@floor(yy);return colors.Pixel.lerp(colors.Pixel.lerp(regionTexel(image,region,ix,iy,sampling),regionTexel(image,region,ix+1,iy,sampling),u),colors.Pixel.lerp(regionTexel(image,region,ix,iy+1,sampling),regionTexel(image,region,ix+1,iy+1,sampling),u),v);}
    const radius:i64=if(sampling.filter==.mitchell)2 else 3;var sum:colors.Pixel=.{};var weight:f64=0;var dy:i64=1-radius;
    while(dy<=radius):(dy+=1){var dx:i64=1-radius;while(dx<=radius):(dx+=1){const w=filterWeight(xx-@as(f64,@floatFromInt(ix+dx)),sampling.filter)*filterWeight(yy-@as(f64,@floatFromInt(iy+dy)),sampling.filter);sum=colors.Pixel.add(sum,regionTexel(image,region,ix+dx,iy+dy,sampling).scaled(w));weight+=w;}}
    return if(weight!=0)sum.scaled(1/weight) else .{};
}
fn regionCoordinate(v:f64,n:u32,extend:images.Extend) ?f64 {const size:f64=@floatFromInt(n);return switch(extend){.pad=>std.math.clamp(v,-4,size+4),.transparent=>if(v < -4 or v > size+4)null else v,.repeat=>@mod(v,size),.reflect=>@mod(v,2*size)};}
fn regionIndex(v:i64,n:u32,extend:images.Extend) ?u32 {const size:i64=n;return switch(extend){.pad=>@intCast(std.math.clamp(v,0,size-1)),.transparent=>if(v<0 or v>=size)null else @intCast(v),.repeat=>@intCast(@mod(v,size)),.reflect=>blk:{const q=@mod(v,2*size);break :blk @intCast(if(q<size)q else 2*size-1-q);}};}
fn regionTexel(image:*const images.Image,region:images.Region,x:i64,y:i64,sampling:images.Sampling) colors.Pixel {const xx=regionIndex(x,region.width,sampling.extend_x) orelse return .{};const yy=regionIndex(y,region.height,sampling.extend_y) orelse return .{};return image.levels[0].pixels[@as(usize,region.y+yy)*image.width()+region.x+xx];}
fn filterWeight(v:f64,filter:images.Filter) f64 {const x=@abs(v);if(filter==.lanczos3){if(x>=3)return 0;if(x<1e-12)return 1;const p=std.math.pi*x;return @sin(p)*@sin(p/3)/(p*p/3);}if(x>=2)return 0;return if(x<1)(7*x*x*x-12*x*x+16.0/3.0)/6 else (-7.0/3.0*x*x*x+12*x*x-20*x+32.0/3.0)/6;}
