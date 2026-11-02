//! Owned linear-premultiplied images and sampling shared by reference rendering,
//! image ingestion, mip generation and GPU upload preparation.
const std = @import("std");
const colors = @import("color.zig");
const Pixel = colors.Pixel;
pub const Format = enum { rgba8, bgra8, a8, r8, rgba16_float, rgba32_float };
pub const Alpha = enum { straight, premultiplied, opaque };
pub const Extend = enum { pad, repeat, reflect, transparent };
pub const Filter = enum { nearest, linear, mitchell, lanczos3 };
pub const MipFilter = enum { none, nearest, linear };
pub const Layout = struct { format: Format = .rgba8, alpha: Alpha = .straight, space: colors.Space = .srgb, bytes_per_row: ?usize = null };
pub const Sampling = struct { filter: Filter = .linear, extend_x: Extend = .pad, extend_y: Extend = .pad, mip_filter: MipFilter = .none, lod: f64 = 0 };
pub const Error = std.mem.Allocator.Error || error{ InvalidDimensions, InvalidData, InvalidRegion, InvalidSampling };
pub const Level = struct { width: u32, height: u32, pixels: []Pixel };
pub const Region = struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };
pub const Image = struct {
    allocator: std.mem.Allocator,
    levels: []Level,
    revision: u64 = 1,
    pub fn init(allocator: std.mem.Allocator, width_: u32, height_: u32) Error!Image {
        if (width_ == 0 or height_ == 0 or @as(u64,width_)*height_ > std.math.maxInt(usize)/@sizeOf(Pixel)) return error.InvalidDimensions;
        const levels=try allocator.alloc(Level,1); errdefer allocator.free(levels);
        const pixels=try allocator.alloc(Pixel,@as(usize,width_)*height_); @memset(pixels,.{});
        levels[0]=.{.width=width_,.height=height_,.pixels=pixels};
        return .{.allocator=allocator,.levels=levels};
    }
    pub fn deinit(self:*Image) void { for(self.levels)|level|self.allocator.free(level.pixels);self.allocator.free(self.levels);self.*=undefined; }
    pub fn width(self:*const Image) u32 {return self.levels[0].width;}
    pub fn height(self:*const Image) u32 {return self.levels[0].height;}
    pub fn fromBytes(allocator:std.mem.Allocator,width_:u32,height_:u32,data:[]const u8,layout:Layout) Error!Image {
        var result=try init(allocator,width_,height_);errdefer result.deinit();
        try result.update(.{.width=width_,.height=height_},data,layout);return result;
    }
    /// Updates are transactional: decoded/validated pixels are prepared before
    /// mutating the base level. Old mip levels are invalidated after success.
    pub fn update(self:*Image,region:Region,data:[]const u8,layout:Layout) Error!void {
        if(region.width==0 or region.height==0 or region.x>self.width() or region.y>self.height() or region.width>self.width()-region.x or region.height>self.height()-region.y)return error.InvalidRegion;
        const bpp:usize=switch(layout.format){.rgba8,.bgra8=>4,.a8,.r8=>1,.rgba16_float=>8,.rgba32_float=>16};
        const row_size=std.math.mul(usize,region.width,bpp) catch return error.InvalidData;
        const stride=layout.bytes_per_row orelse row_size;
        if(stride<row_size or @as(u64,stride)*(region.height-1)+row_size>data.len)return error.InvalidData;
        const decoded=try self.allocator.alloc(Pixel,@as(usize,region.width)*region.height);defer self.allocator.free(decoded);
        for(0..region.height)|y|for(0..region.width)|x|{
            const bytes=data[y*stride+x*bpp..][0..bpp];
            var c:colors.Color=switch(layout.format){
                .rgba8=>.{.r=@as(f64,@floatFromInt(bytes[0]))/255,.g=@as(f64,@floatFromInt(bytes[1]))/255,.b=@as(f64,@floatFromInt(bytes[2]))/255,.a=@as(f64,@floatFromInt(bytes[3]))/255},
                .bgra8=>.{.r=@as(f64,@floatFromInt(bytes[2]))/255,.g=@as(f64,@floatFromInt(bytes[1]))/255,.b=@as(f64,@floatFromInt(bytes[0]))/255,.a=@as(f64,@floatFromInt(bytes[3]))/255},
                .a8=>.{.r=1,.g=1,.b=1,.a=@as(f64,@floatFromInt(bytes[0]))/255},
                .r8=>.{.r=@as(f64,@floatFromInt(bytes[0]))/255,.g=@as(f64,@floatFromInt(bytes[0]))/255,.b=@as(f64,@floatFromInt(bytes[0]))/255,.a=1},
                .rgba16_float=>.{.r=half(bytes[0..2]),.g=half(bytes[2..4]),.b=half(bytes[4..6]),.a=half(bytes[6..8])},
                .rgba32_float=>.{.r=single(bytes[0..4]),.g=single(bytes[4..8]),.b=single(bytes[8..12]),.a=single(bytes[12..16])},
            };
            if(layout.alpha==.opaque)c.a=1;
            if(!c.valid())return error.InvalidData;
            if(layout.alpha==.premultiplied){if(c.a==0)c=.transparent else {c.r/=c.a;c.g/=c.a;c.b/=c.a;}}
            decoded[y*region.width+x]=c.converted(layout.space,.linear_srgb).premultiplied();
        };
        // Allocate replacement level metadata first, preserving state on OOM.
        const replacement=if(self.levels.len>1)try self.allocator.alloc(Level,1) else self.levels;
        if(self.levels.len>1){replacement[0]=self.levels[0];for(self.levels[1..])|level|self.allocator.free(level.pixels);self.allocator.free(self.levels);self.levels=replacement;}
        for(0..region.height)|y|{@memcpy(self.levels[0].pixels[(@as(usize,region.y)+y)*self.width()+region.x..][0..region.width],decoded[y*region.width..][0..region.width]);}
        self.revision+%=1;
    }
    pub fn clone(self:*const Image,allocator:std.mem.Allocator) Error!Image {
        var result=try init(allocator,self.width(),self.height());@memcpy(result.levels[0].pixels,self.levels[0].pixels);return result;
    }
    pub fn subimage(self:*const Image,allocator:std.mem.Allocator,region:Region) Error!Image {
        if(region.x>self.width() or region.y>self.height() or region.width>self.width()-region.x or region.height>self.height()-region.y)return error.InvalidRegion;
        var result=try init(allocator,region.width,region.height);
        for(0..region.height)|y|@memcpy(result.levels[0].pixels[y*region.width..][0..region.width],self.levels[0].pixels[(@as(usize,region.y)+y)*self.width()+region.x..][0..region.width]);
        return result;
    }
    pub fn generateMipmaps(self:*Image) Error!void {
        var count:usize=1;var w=self.width();var h=self.height();while(w>1 or h>1){w=@max(1,w/2);h=@max(1,h/2);count+=1;}
        const levels=try self.allocator.alloc(Level,count);var built:usize=1;
        errdefer {for(levels[1..built])|level|self.allocator.free(level.pixels);self.allocator.free(levels);}
        levels[0]=self.levels[0];
        while(built<count):(built+=1){
            const previous=levels[built-1];w=@max(1,previous.width/2);h=@max(1,previous.height/2);
            const pixels=try self.allocator.alloc(Pixel,@as(usize,w)*h);
            levels[built]=.{.width=w,.height=h,.pixels=pixels};
            for(0..h)|y|for(0..w)|x|{
                // Area box integrates all source texels, including odd edges.
                const x0=@as(f64,@floatFromInt(x))*@as(f64,@floatFromInt(previous.width))/@as(f64,@floatFromInt(w));
                const x1=@as(f64,@floatFromInt(x+1))*@as(f64,@floatFromInt(previous.width))/@as(f64,@floatFromInt(w));
                const y0=@as(f64,@floatFromInt(y))*@as(f64,@floatFromInt(previous.height))/@as(f64,@floatFromInt(h));
                const y1=@as(f64,@floatFromInt(y+1))*@as(f64,@floatFromInt(previous.height))/@as(f64,@floatFromInt(h));
                var sum:Pixel=.{};
                const sx0:usize=@intFromFloat(@floor(x0));const sx1:usize=@intFromFloat(@ceil(x1));const sy0:usize=@intFromFloat(@floor(y0));const sy1:usize=@intFromFloat(@ceil(y1));
                for(sy0..sy1)|sy|for(sx0..sx1)|sx|{const weight=(@min(x1,@as(f64,@floatFromInt(sx+1)))-@max(x0,@as(f64,@floatFromInt(sx))))*(@min(y1,@as(f64,@floatFromInt(sy+1)))-@max(y0,@as(f64,@floatFromInt(sy))));sum=Pixel.add(sum,previous.pixels[sy*previous.width+sx].scaled(weight));};
                pixels[y*w+x]=sum.scaled(1/((x1-x0)*(y1-y0)));
            };
        }
        for(self.levels[1..])|level|self.allocator.free(level.pixels);self.allocator.free(self.levels);self.levels=levels;self.revision+%=1;
    }
    pub fn sample(self:*const Image,x:f64,y:f64,sampling:Sampling) error{InvalidSampling}!Pixel {
        if(!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(sampling.lod))return error.InvalidSampling;
        const lod=std.math.clamp(sampling.lod,0,@as(f64,@floatFromInt(self.levels.len-1)));
        if(sampling.mip_filter==.none)return sampleLevel(self.levels[0],x,y,sampling);
        const lo:usize=@intFromFloat(if(sampling.mip_filter==.nearest)@round(lod) else @floor(lod));
        const a=sampleLevel(self.levels[lo],x*@as(f64,@floatFromInt(self.levels[lo].width))/@as(f64,@floatFromInt(self.width())),y*@as(f64,@floatFromInt(self.levels[lo].height))/@as(f64,@floatFromInt(self.height())),sampling);
        if(sampling.mip_filter==.nearest or lo==self.levels.len-1)return a;
        const hi=lo+1;const b=sampleLevel(self.levels[hi],x*@as(f64,@floatFromInt(self.levels[hi].width))/@as(f64,@floatFromInt(self.width())),y*@as(f64,@floatFromInt(self.levels[hi].height))/@as(f64,@floatFromInt(self.height())),sampling);
        return Pixel.lerp(a,b,lod-@as(f64,@floatFromInt(lo)));
    }
    pub fn toBytes(self:*const Image,allocator:std.mem.Allocator,space:colors.Space,alpha:Alpha) ![]u8 {
        const result=try allocator.alloc(u8,self.levels[0].pixels.len*4);
        for(self.levels[0].pixels,0..)|pixel,i|{var value=pixel;if(alpha==.opaque){const c=pixel.straight();value=(colors.Color{.r=c.r,.g=c.g,.b=c.b,.a=1}).premultiplied();}const packed=value.rgba8(space,if(alpha==.premultiplied).premultiplied else .straight);@memcpy(result[i*4..][0..4],&packed);}
        return result;
    }
};
fn half(data:*const[2]u8) f64 {return @floatCast(@as(f16,@bitCast(std.mem.readInt(u16,data,.little))));}
fn single(data:*const[4]u8) f64 {return @floatCast(@as(f32,@bitCast(std.mem.readInt(u32,data,.little))));}
fn index(coordinate:i64,size:u32,extend:Extend) ?usize {
    const n:i64=size;return switch(extend){.pad=>@intCast(std.math.clamp(coordinate,0,n-1)),.transparent=>if(coordinate<0 or coordinate>=n)null else @intCast(coordinate),.repeat=>@intCast(@mod(coordinate,n)),.reflect=>blk:{const p=@mod(coordinate,2*n);break :blk @intCast(if(p<n)p else 2*n-1-p);}};
}
fn texel(level:Level,x:i64,y:i64,sampling:Sampling) Pixel {const ix=index(x,level.width,sampling.extend_x) orelse return .{};const iy=index(y,level.height,sampling.extend_y) orelse return .{};return level.pixels[iy*level.width+ix];}
fn sampleLevel(level:Level,input_x:f64,input_y:f64,sampling:Sampling) Pixel {
    // Reduce periodic coordinates before integer conversion, including huge inputs.
    const x=reduce(input_x,level.width,sampling.extend_x);const y=reduce(input_y,level.height,sampling.extend_y);
    if(x < -8 or x > @as(f64,@floatFromInt(level.width))+8 or y < -8 or y > @as(f64,@floatFromInt(level.height))+8)return .{};
    if(sampling.filter==.nearest)return texel(level,@intFromFloat(@floor(x)),@intFromFloat(@floor(y)),sampling);
    const xx=x-0.5;const yy=y-0.5;const ix:i64=@intFromFloat(@floor(xx));const iy:i64=@intFromFloat(@floor(yy));
    if(sampling.filter==.linear){const tx=xx-@floor(xx);const ty=yy-@floor(yy);return Pixel.lerp(Pixel.lerp(texel(level,ix,iy,sampling),texel(level,ix+1,iy,sampling),tx),Pixel.lerp(texel(level,ix,iy+1,sampling),texel(level,ix+1,iy+1,sampling),tx),ty);}
    const radius:i64=if(sampling.filter==.mitchell)2 else 3;var value:Pixel=.{};var weight_sum:f64=0;
    var dy:i64=1-radius;while(dy<=radius):(dy+=1){var dx:i64=1-radius;while(dx<=radius):(dx+=1){const weight=kernel(xx-@as(f64,@floatFromInt(ix+dx)),sampling.filter)*kernel(yy-@as(f64,@floatFromInt(iy+dy)),sampling.filter);value=Pixel.add(value,texel(level,ix+dx,iy+dy,sampling).scaled(weight));weight_sum+=weight;}}
    if(weight_sum!=0)value=value.scaled(1/weight_sum);
    if(value.a<=0)return .{};if(value.a>1)value=value.scaled(1/value.a);return value;
}
fn reduce(value:f64,size:u32,extend:Extend) f64 {const n:f64=@floatFromInt(size);return switch(extend){.pad=>std.math.clamp(value,-1,n+1),.transparent=>value,.repeat=>@mod(value,n),.reflect=>@mod(value,2*n)};}
fn kernel(input:f64,filter:Filter) f64 {
    const x=@abs(input);
    if(filter==.lanczos3){if(x>=3)return 0;if(x<1e-12)return 1;const p=std.math.pi*x;return @sin(p)*@sin(p/3)/(p*p/3);}
    // Mitchell-Netravali B=C=1/3.
    if(x>=2)return 0;if(x<1)return (7*x*x*x-12*x*x+16.0/3.0)/6;
    return (-7.0/3.0*x*x*x+12*x*x-20*x+32.0/3.0)/6;
}
