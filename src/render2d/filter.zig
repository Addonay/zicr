//! Owned effect DAG and CPU reference equations. GPU execution consumes these
//! nodes as render passes; reference evaluation is never the GPU renderer path.
const std=@import("std");
const images=@import("image.zig");
const colors=@import("color.zig");
const composite=@import("composite.zig");
const paints=@import("paint.zig");
const Image=images.Image;const Pixel=colors.Pixel;
pub const Input=union(enum){source,source_alpha,node:u32};
pub const Gaussian=struct{sigma_x:f64,sigma_y:f64,edge:images.Extend=.transparent};
pub const Shadow=struct{sigma_x:f64,sigma_y:f64,dx:f64=0,dy:f64=0,color:colors.Color=.black,only:bool=false};
pub const Transfer=union(enum){identity,table:[]const f64,discrete:[]const f64,linear:struct{slope:f64=1,intercept:f64=0},gamma:struct{amplitude:f64=1,exponent:f64=1,offset:f64=0}};
pub const ColorMatrix=struct{values:[4][5]f64=identity_matrix,clamp:bool=true};
pub const identity_matrix=[4][5]f64{.{1,0,0,0,0},.{0,1,0,0,0},.{0,0,1,0,0},.{0,0,0,1,0}};
pub const Convolution=struct{width:u32,height:u32,kernel:[]const f64,divisor:?f64=null,bias:f64=0,target_x:?u32=null,target_y:?u32=null,edge:images.Extend=.pad,preserve_alpha:bool=false};
pub const Kind=union(enum){
    gaussian:Gaussian,drop_shadow:Shadow,offset:struct{x:f64,y:f64},flood:colors.Color,
    color_matrix:ColorMatrix,transfer:[4]Transfer,
    composite:struct{mode:composite.Mode=.source_over},
    arithmetic:struct{k1:f64=0,k2:f64=0,k3:f64=0,k4:f64=0},
    morphology:struct{radius_x:u32,radius_y:u32,operator:enum{dilate,erode}=.dilate},
    convolution:Convolution,
    displacement:struct{scale:f64,x_channel:u2=0,y_channel:u2=1},
    tile:struct{region:images.Region},
};
pub const Node=struct{kind:Kind,first:Input=.source,second:Input=.source,space:enum{linear_srgb,srgb}=.linear_srgb};
pub const Options=struct{max_nodes:usize=1024,max_kernel_radius:u32=1024,max_pixels:usize=16*1024*1024};
pub const Error=images.Error||std.mem.Allocator.Error||error{InvalidFilter,InvalidInput,FilterLimit};
pub const Graph=struct{
    allocator:std.mem.Allocator,nodes:std.ArrayList(Node)=.empty,output:?u32=null,
    pub fn init(allocator:std.mem.Allocator) Graph{return .{.allocator=allocator};}
    pub fn deinit(self:*Graph) void {for(self.nodes.items)|node|freeKind(self.allocator,node.kind);self.nodes.deinit(self.allocator);self.*=undefined;}
    pub fn add(self:*Graph,node:Node) Error!u32 {
        if(self.nodes.items.len>=std.math.maxInt(u32))return error.FilterLimit;
        try validInput(node.first,self.nodes.items.len);try validInput(node.second,self.nodes.items.len);try validateKind(node.kind);
        const owned=try copyKind(self.allocator,node.kind);errdefer freeKind(self.allocator,owned);
        try self.nodes.append(self.allocator,.{.kind=owned,.first=node.first,.second=node.second,.space=node.space});self.output=@intCast(self.nodes.items.len-1);return self.output.?;
    }
    pub fn setOutput(self:*Graph,output:?u32) Error!void {if(output)|index|if(index>=self.nodes.items.len)return error.InvalidInput;self.output=output;}
    pub fn clone(self:*const Graph,allocator:std.mem.Allocator) Error!Graph {
        var result=Graph.init(allocator);errdefer result.deinit();for(self.nodes.items)|node|_ =try result.add(node);result.output=self.output;return result;
    }
    /// Returns a new image over the supplied filter region. The caller supplies
    /// an expanded source canvas when effects should extend beyond source bounds.
    pub fn reference(self:*const Graph,source:*const Image,allocator:std.mem.Allocator,options:Options) Error!Image {
        if(self.nodes.items.len>options.max_nodes or @as(u64,source.width())*source.height()>options.max_pixels)return error.FilterLimit;
        if(self.output==null)return source.clone(allocator);
        var alpha=try source.clone(allocator);defer alpha.deinit();for(alpha.levels[0].pixels)|*pixel|pixel.*=.{.a=pixel.a};
        var results:std.ArrayList(Image)=.empty;defer {for(results.items)|*image|image.deinit();results.deinit(allocator);}
        try results.ensureTotalCapacity(allocator,self.nodes.items.len);
        for(self.nodes.items)|node|{
            const first=resolve(node.first,source,&alpha,results.items);const second=resolve(node.second,source,&alpha,results.items);
            var result:Image=undefined;
            if(node.space==.srgb){
                var a=try converted(first,allocator,.linear_srgb,.srgb);defer a.deinit();var b=try converted(second,allocator,.linear_srgb,.srgb);defer b.deinit();
                var kind=node.kind;switch(kind){.flood=>|*c|c.*=c.converted(.linear_srgb,.srgb),.drop_shadow=>|*s|s.color=s.color.converted(.linear_srgb,.srgb),else=>{}}
                var encoded=try evaluate(kind,&a,&b,allocator,options);defer encoded.deinit();result=try converted(&encoded,allocator,.srgb,.linear_srgb);
            }else result=try evaluate(node.kind,first,second,allocator,options);
            errdefer result.deinit();results.appendAssumeCapacity(result);
        }
        const index=self.output.?;const result=results.items[index];_ =results.orderedRemove(index);return result;
    }
};
fn resolve(input:Input,source:*const Image,alpha:*const Image,results:[]const Image) *const Image{return switch(input){.source=>source,.source_alpha=>alpha,.node=>|index|&results[index]};}
fn validInput(input:Input,count:usize) Error!void {if(input==.node and input.node>=count)return error.InvalidInput;}
fn validateKind(kind:Kind) Error!void {
    switch(kind){
        .gaussian=>|g|if(!positive(g.sigma_x) or !positive(g.sigma_y))return error.InvalidFilter,
        .drop_shadow=>|g|if(!positive(g.sigma_x) or !positive(g.sigma_y) or !std.math.isFinite(g.dx) or !std.math.isFinite(g.dy) or !g.color.valid())return error.InvalidFilter,
        .offset=>|o|if(!std.math.isFinite(o.x) or !std.math.isFinite(o.y))return error.InvalidFilter,
        .flood=>|c|if(!c.valid())return error.InvalidFilter,
        .color_matrix=>|matrix|for(matrix.values)|row|for(row)|value|if(!std.math.isFinite(value))return error.InvalidFilter,
        .transfer=>|channels|for(channels)|channel|switch(channel){.table,.discrete=>|table|{for(table)|v|if(!std.math.isFinite(v))return error.InvalidFilter;},.linear=>|l|{if(!std.math.isFinite(l.slope) or !std.math.isFinite(l.intercept))return error.InvalidFilter;},.gamma=>|g|{if(!std.math.isFinite(g.amplitude) or !std.math.isFinite(g.exponent) or !std.math.isFinite(g.offset) or g.exponent<0)return error.InvalidFilter;},.identity=>{}},
        .convolution=>|c|{if(c.width==0 or c.height==0 or @as(u64,c.width)*c.height!=c.kernel.len or !std.math.isFinite(c.bias))return error.InvalidFilter;for(c.kernel)|value|if(!std.math.isFinite(value))return error.InvalidFilter;if(c.divisor)|d|if(!std.math.isFinite(d) or d==0)return error.InvalidFilter;if(c.target_x)|x|if(x>=c.width)return error.InvalidFilter;if(c.target_y)|y|if(y>=c.height)return error.InvalidFilter;},
        .arithmetic=>|a|if(!std.math.isFinite(a.k1) or !std.math.isFinite(a.k2) or !std.math.isFinite(a.k3) or !std.math.isFinite(a.k4))return error.InvalidFilter,
        .displacement=>|d|if(!std.math.isFinite(d.scale))return error.InvalidFilter,
        else=>{},
    }
}
fn positive(v:f64) bool{return std.math.isFinite(v) and v>=0;}
fn copyKind(allocator:std.mem.Allocator,input:Kind) Error!Kind {
    var result=input;
    switch(input){
        .convolution=>|c|{result.convolution.kernel=try allocator.dupe(f64,c.kernel);},
        .transfer=>|channels|{
            var built:usize=0;errdefer for(result.transfer[0..built])|t|switch(t){.table,.discrete=>|v|allocator.free(v),else=>{}};
            for(channels,0..)|channel,i|{result.transfer[i]=switch(channel){.table=>|v|.{.table=try allocator.dupe(f64,v)},.discrete=>|v|.{.discrete=try allocator.dupe(f64,v)},else=>channel};built+=1;}
        },else=>{},
    }
    return result;
}
fn freeKind(allocator:std.mem.Allocator,kind:Kind) void {switch(kind){.convolution=>|c|allocator.free(c.kernel),.transfer=>|channels|for(channels)|c|switch(c){.table,.discrete=>|v|allocator.free(v),else=>{}},else=>{}};}
fn evaluate(kind:Kind,first:*const Image,second:*const Image,allocator:std.mem.Allocator,options:Options) Error!Image {
    if(kind==.gaussian)return blur(first,allocator,kind.gaussian,options);
    if(kind==.drop_shadow){
        const style=kind.drop_shadow;var alpha=try first.clone(allocator);defer alpha.deinit();for(alpha.levels[0].pixels)|*p|p.*=style.color.premultiplied().scaled(p.a);
        var blurred=try blur(&alpha,allocator,.{.sigma_x=style.sigma_x,.sigma_y=style.sigma_y},options);defer blurred.deinit();
        var result=try Image.init(allocator,first.width(),first.height());errdefer result.deinit();
        for(0..first.height())|y|for(0..first.width())|x|{const shadow=try blurred.sample(@as(f64,@floatFromInt(x))+0.5-style.dx,@as(f64,@floatFromInt(y))+0.5-style.dy,.{.extend_x=.transparent,.extend_y=.transparent});const i=y*first.width()+x;result.levels[0].pixels[i]=if(style.only)shadow else composite.operation(.source_over,first.levels[0].pixels[i],shadow);};return result;
    }
    var result=try Image.init(allocator,first.width(),first.height());errdefer result.deinit();
    for(0..first.height())|y|for(0..first.width())|x|{
        const i=y*first.width()+x;const a=first.levels[0].pixels[i];const b=if(x<second.width() and y<second.height())second.levels[0].pixels[y*second.width()+x] else Pixel{};
        result.levels[0].pixels[i]=switch(kind){
            .offset=>|o|try first.sample(@as(f64,@floatFromInt(x))+0.5-o.x,@as(f64,@floatFromInt(y))+0.5-o.y,.{.extend_x=.transparent,.extend_y=.transparent}),
            .flood=>|c|c.premultiplied(),
            .color_matrix=>|m|applyMatrix(a,m),
            .transfer=>|channels|blk:{const c=a.straight();const alpha=std.math.clamp(transfer(c.a,channels[3]),0,1);break :blk (colors.Color{.r=std.math.clamp(transfer(c.r,channels[0]),0,1),.g=std.math.clamp(transfer(c.g,channels[1]),0,1),.b=std.math.clamp(transfer(c.b,channels[2]),0,1),.a=alpha}).premultiplied();},
            .composite=>|c|composite.operation(c.mode,a,b),
            .arithmetic=>|k|blk:{var value:Pixel=undefined;inline for(@typeInfo(Pixel).@"struct".field_names)|name|{@field(value,name)=std.math.clamp(k.k1*@field(a,name)*@field(b,name)+k.k2*@field(a,name)+k.k3*@field(b,name)+k.k4,0,1);}value.r=@min(value.r,value.a);value.g=@min(value.g,value.a);value.b=@min(value.b,value.a);break :blk value;},
            .morphology=>|m|try morphology(first,x,y,m.radius_x,m.radius_y,m.operator==.dilate,options),
            .convolution=>|c|try convolve(first,x,y,c,options),
            .displacement=>|d|blk:{const straight=b.straight();const v=[4]f64{straight.r,straight.g,straight.b,straight.a};break :blk try first.sample(@as(f64,@floatFromInt(x))+0.5+d.scale*(v[d.x_channel]-0.5),@as(f64,@floatFromInt(y))+0.5+d.scale*(v[d.y_channel]-0.5),.{.extend_x=.transparent,.extend_y=.transparent});},
            .tile=>|tile|blk:{const p:paints.Paint=.{.image=.{.image=.{.pixels=first},.region=tile.region,.sampling=.{.filter=.linear,.extend_x=.repeat,.extend_y=.repeat}}};break :blk p.evaluated(.{.x=@as(f64,@floatFromInt(x))+0.5-@as(f64,@floatFromInt(tile.region.x)),.y=@as(f64,@floatFromInt(y))+0.5-@as(f64,@floatFromInt(tile.region.y))}) catch return error.InvalidFilter;},
            else=>unreachable,
        };
    };
    return result;
}
fn blur(source:*const Image,allocator:std.mem.Allocator,g:Gaussian,options:Options) Error!Image {
    if(g.sigma_x==0 and g.sigma_y==0)return source.clone(allocator);
    var horizontal=try blurAxis(source,allocator,g.sigma_x,true,g.edge,options);defer horizontal.deinit();return blurAxis(&horizontal,allocator,g.sigma_y,false,g.edge,options);
}
fn blurAxis(source:*const Image,allocator:std.mem.Allocator,sigma:f64,horizontal:bool,edge:images.Extend,options:Options) Error!Image {
    if(sigma==0)return source.clone(allocator);
    const radius_f=@ceil(3*sigma);if(radius_f>options.max_kernel_radius)return error.FilterLimit;const radius:i64=@intFromFloat(radius_f);
    const weights=try allocator.alloc(f64,@intCast(2*radius+1));defer allocator.free(weights);var total:f64=0;
    for(weights,0..)|*weight,i|{const offset=@as(f64,@floatFromInt(@as(i64,@intCast(i))-radius));weight.*=@exp(-0.5*offset*offset/(sigma*sigma));total+=weight.*;}for(weights)|*weight|weight.*/=total;
    var output=try Image.init(allocator,source.width(),source.height());errdefer output.deinit();
    for(0..source.height())|y|for(0..source.width())|x|{var sum:Pixel=.{};for(weights,0..)|weight,i|{const delta=@as(i64,@intCast(i))-radius;const xx=@as(f64,@floatFromInt(@as(i64,@intCast(x))+if(horizontal)delta else 0))+0.5;const yy=@as(f64,@floatFromInt(@as(i64,@intCast(y))+if(horizontal)0 else delta))+0.5;sum=Pixel.add(sum,(try source.sample(xx,yy,.{.filter=.nearest,.extend_x=edge,.extend_y=edge})).scaled(weight));}output.levels[0].pixels[y*source.width()+x]=sum;};return output;
}
pub fn applyMatrix(pixel:Pixel,m:ColorMatrix) Pixel {
    const color=pixel.straight();const input=[5]f64{color.r,color.g,color.b,color.a,1};var output:[4]f64=.{0,0,0,0};for(&output,m.values)|*v,row|for(row,input)|coefficient,value|v.*+=coefficient*value;
    if(m.clamp)for(&output)|*v|v.*=std.math.clamp(v.*,0,1);output[3]=std.math.clamp(output[3],0,1);return (colors.Color{.r=output[0],.g=output[1],.b=output[2],.a=output[3]}).premultiplied();
}
fn transfer(v:f64,function:Transfer) f64 {return switch(function){.identity=>v,.linear=>|l|l.slope*v+l.intercept,.gamma=>|g|g.amplitude*std.math.pow(f64,@max(0,v),g.exponent)+g.offset,.table=>|table|blk:{if(table.len==0)break :blk v;if(table.len==1)break :blk table[0];const index=std.math.clamp(v,0,1)*@as(f64,@floatFromInt(table.len-1));const i:usize=@intFromFloat(@floor(index));if(i==table.len-1)break :blk table[i];break :blk table[i]+(table[i+1]-table[i])*(index-@as(f64,@floatFromInt(i)));},.discrete=>|table|if(table.len==0)v else table[@min(table.len-1,@as(usize,@intFromFloat(@floor(std.math.clamp(v,0,1)*@as(f64,@floatFromInt(table.len))))))]};}
fn morphology(source:*const Image,x:usize,y:usize,rx:u32,ry:u32,dilate:bool,options:Options) Error!Pixel {
    if(rx>options.max_kernel_radius or ry>options.max_kernel_radius)return error.FilterLimit;
    var result:Pixel=if(dilate).{} else .{.r=1,.g=1,.b=1,.a=1};var dy:i64=-@as(i64,ry);
    while(dy<=ry):(dy+=1){var dx:i64=-@as(i64,rx);while(dx<=rx):(dx+=1){const p=try source.sample(@as(f64,@floatFromInt(@as(i64,@intCast(x))+dx))+0.5,@as(f64,@floatFromInt(@as(i64,@intCast(y))+dy))+0.5,.{.filter=.nearest,.extend_x=.transparent,.extend_y=.transparent});inline for(@typeInfo(Pixel).@"struct".field_names)|name|@field(result,name)=if(dilate)@max(@field(result,name),@field(p,name)) else @min(@field(result,name),@field(p,name));}}return result;
}
fn convolve(source:*const Image,x:usize,y:usize,c:Convolution,options:Options) Error!Pixel {
    if(c.width>2*options.max_kernel_radius+1 or c.height>2*options.max_kernel_radius+1)return error.FilterLimit;
    var divisor=c.divisor orelse 0;if(c.divisor==null){for(c.kernel)|value|divisor+=value;if(divisor==0)divisor=1;}
    const tx=c.target_x orelse c.width/2;const ty=c.target_y orelse c.height/2;var result:Pixel=.{};
    for(0..c.height)|ky|for(0..c.width)|kx|{const p=try source.sample(@as(f64,@floatFromInt(@as(i64,@intCast(x))+@as(i64,@intCast(kx))-tx))+0.5,@as(f64,@floatFromInt(@as(i64,@intCast(y))+@as(i64,@intCast(ky))-ty))+0.5,.{.filter=.nearest,.extend_x=c.edge,.extend_y=c.edge});const index=(c.height-1-ky)*c.width+(c.width-1-kx);if(c.preserve_alpha){const s=p.straight();result=Pixel.add(result,(Pixel{.r=s.r,.g=s.g,.b=s.b,.a=0}).scaled(c.kernel[index]/divisor));}else result=Pixel.add(result,p.scaled(c.kernel[index]/divisor));};
    if(c.preserve_alpha){const alpha=source.levels[0].pixels[y*source.width()+x].a;return (colors.Color{.r=std.math.clamp(result.r+c.bias,0,1),.g=std.math.clamp(result.g+c.bias,0,1),.b=std.math.clamp(result.b+c.bias,0,1),.a=alpha}).premultiplied();}
    result.a=std.math.clamp(result.a+c.bias,0,1);result.r=std.math.clamp(result.r+c.bias,0,result.a);result.g=std.math.clamp(result.g+c.bias,0,result.a);result.b=std.math.clamp(result.b+c.bias,0,result.a);return result;
}

fn converted(source:*const Image,allocator:std.mem.Allocator,from:colors.Space,to:colors.Space) Error!Image {
    var result=try source.clone(allocator);for(result.levels[0].pixels)|*pixel|pixel.*=pixel.straight().converted(from,to).premultiplied();return result;
}
