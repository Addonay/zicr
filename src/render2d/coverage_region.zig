//! Analytic boolean regions: clips and aligned strokes share the winding
//! partition with geometry, avoiding multiplication of independently AA'd edges.
const std=@import("std");
const coverage=@import("coverage.zig");
const paths=@import("path.zig");
pub const Input=struct{path:*const paths.FlatPath,rule:paths.FillRule=.nonzero};
pub const Instruction=union(enum){input:u16,intersection,union_,subtract,exclusive_or,invert};
pub const Options=struct{coverage:coverage.Options=.{},bounds:?coverage.Clip=null,max_inputs:usize=256,max_edges:usize=1<<22,max_program:usize=4096};
pub const Error=coverage.Error||error{InvalidRegion};
const Edge=struct{value:coverage.Edge,group:usize};
const Crossing=struct{index:usize,x:f64,fn less(_:void,a:Crossing,b:Crossing) bool{return a.x<b.x;}};
pub fn rasterize(inputs:[]const Input,program:[]const Instruction,allocator:std.mem.Allocator,clip:coverage.Clip,options:Options) Error!coverage.Mask {
    if(inputs.len==0 or inputs.len>options.max_inputs or program.len==0 or program.len>options.max_program)return error.InvalidRegion;
    const stack_size=try validate(program,inputs.len);const stack=try allocator.alloc(bool,stack_size);defer allocator.free(stack);
    const bounds=intersect(clip,options.bounds orelse clip);const width:usize=@intCast(bounds.width);const height:usize=@intCast(bounds.height);
    if(width!=0 and height>options.coverage.max_pixels/width)return error.RasterLimit;
    const pixels=try allocator.alloc(f32,width*height);errdefer allocator.free(pixels);@memset(pixels,0);
    const mask:coverage.Mask=.{.allocator=allocator,.bounds=bounds,.pixels=pixels};if(pixels.len==0)return mask;
    var edges:std.ArrayList(Edge)=.empty;defer edges.deinit(allocator);
    for(inputs,0..)|input,group|for(input.path.contours.items)|contour|{
        const points=input.path.contourPoints(contour);if(points.len<2)continue;var previous=points[points.len-1];
        for(points)|point|{
            if(!previous.finite() or !point.finite())return error.InvalidGeometry;
            if(previous.y!=point.y){
                if(edges.items.len==options.max_edges)return error.RasterLimit;
                const a=if(previous.y<point.y)previous else point;const b=if(previous.y<point.y)point else previous;const slope=(b.x-a.x)/(b.y-a.y);
                if(!std.math.isFinite(slope))return error.InvalidGeometry;
                try edges.append(allocator,.{.group=group,.value=.{.x0=a.x,.y0=a.y,.y1=b.y,.slope=slope,.winding=if(point.y>previous.y)1 else -1}});
            }
            previous=point;
        }
    };
    const winding=try allocator.alloc(i64,inputs.len);defer allocator.free(winding);
    const area=try allocator.alloc(f64,width);defer allocator.free(area);
    var active:std.ArrayList(usize)=.empty;defer active.deinit(allocator);var cuts:std.ArrayList(f64)=.empty;defer cuts.deinit(allocator);var crossings:std.ArrayList(Crossing)=.empty;defer crossings.deinit(allocator);
    var pair_tests:usize=0;
    for(0..height)|row|{
        const top:f64=@floatFromInt(@as(i64,bounds.y)+@as(i64,@intCast(row)));const bottom=top+1;
        @memset(area,0);active.clearRetainingCapacity();cuts.clearRetainingCapacity();
        try cut(&cuts,allocator,top,options.coverage.max_cuts);try cut(&cuts,allocator,bottom,options.coverage.max_cuts);
        for(edges.items,0..)|item,index|{const edge=item.value;if(edge.y1<=top or edge.y0>=bottom)continue;try active.append(allocator,index);if(edge.y0>top and edge.y0<bottom)try cut(&cuts,allocator,edge.y0,options.coverage.max_cuts);if(edge.y1>top and edge.y1<bottom)try cut(&cuts,allocator,edge.y1,options.coverage.max_cuts);}
        for(active.items,0..)|ai,i|{const a=edges.items[ai].value;for(active.items[i+1..])|bi|{
            if(pair_tests==options.coverage.max_pair_tests)return error.RasterLimit;pair_tests+=1;const b=edges.items[bi].value;if(a.slope==b.slope)continue;
            const ax=a.xAt(top);const bx=b.xAt(top);if(!std.math.isFinite(ax) or !std.math.isFinite(bx))return error.InvalidGeometry;
            const numerator=bx-ax;const denominator=a.slope-b.slope;
            const offset:f64=if(std.math.isFinite(numerator) and std.math.isFinite(denominator))numerator/denominator else @floatCast((@as(f128,bx)-@as(f128,ax))/(@as(f128,a.slope)-@as(f128,b.slope)));
            const y=top+offset;if(std.math.isFinite(y) and y>@max(top,@max(a.y0,b.y0)) and y<@min(bottom,@min(a.y1,b.y1)))try cut(&cuts,allocator,y,options.coverage.max_cuts);
        }}
        std.sort.heap(f64,cuts.items,{},std.sort.asc(f64));
        for(cuts.items[1..],cuts.items[0..cuts.items.len-1])|end,start|{
            if(end<=start)continue;const middle=start*0.5+end*0.5;crossings.clearRetainingCapacity();@memset(winding,0);
            for(active.items)|index|{const edge=edges.items[index].value;if(middle<edge.y0 or middle>=edge.y1)continue;const x=edge.xAt(middle);if(!std.math.isFinite(x))return error.InvalidGeometry;try crossings.append(allocator,.{.index=index,.x=x});}
            std.sort.heap(Crossing,crossings.items,{},Crossing.less);
            var was_inside=evaluate(program,inputs,winding,stack);var left:coverage.Edge=.{.x0=@floatFromInt(bounds.x),.y0=top,.y1=bottom,.slope=0,.winding=0};
            for(crossings.items)|crossing|{
                const edge=edges.items[crossing.index];winding[edge.group]+=edge.value.winding;
                const now_inside=evaluate(program,inputs,winding,stack);
                if(!was_inside and now_inside)left=edge.value;
                if(was_inside and !now_inside)try coverage.accumulate(area,bounds.x,left,edge.value,start,end);
                was_inside=now_inside;
            }
            if(was_inside){const right:coverage.Edge=.{.x0=@floatFromInt(@as(i64,bounds.x)+bounds.width),.y0=top,.y1=bottom,.slope=0,.winding=0};try coverage.accumulate(area,bounds.x,left,right,start,end);}
        }
        for(area,pixels[row*width..][0..width])|value,*pixel|{if(!std.math.isFinite(value))return error.InvalidGeometry;pixel.*=@floatCast(std.math.clamp(value,0,1));}
    }
    return mask;
}
fn validate(program:[]const Instruction,inputs:usize) Error!usize {
    var depth:usize=0;var maximum:usize=0;
    for(program)|instruction|switch(instruction){.input=>|index|{if(index>=inputs)return error.InvalidRegion;depth+=1;maximum=@max(maximum,depth);},.invert=>{if(depth==0)return error.InvalidRegion;},else=>{if(depth<2)return error.InvalidRegion;depth-=1;}};
    if(depth!=1)return error.InvalidRegion;return maximum;
}
fn evaluate(program:[]const Instruction,inputs:[]const Input,winding:[]const i64,stack:[]bool) bool {
    var depth:usize=0;
    for(program)|instruction|switch(instruction){
        .input=>|index|{stack[depth]=if(inputs[index].rule==.nonzero)winding[index]!=0 else @mod(winding[index],2)!=0;depth+=1;},
        .invert=>stack[depth-1]=!stack[depth-1],
        else=>{const a=stack[depth-2];const b=stack[depth-1];depth-=1;stack[depth-1]=switch(instruction){.intersection=>a and b,.union_=>a or b,.subtract=>a and !b,.exclusive_or=>a!=b,else=>unreachable};},
    };
    return stack[0];
}
fn cut(cuts:*std.ArrayList(f64),allocator:std.mem.Allocator,y:f64,limit:usize) Error!void {if(cuts.items.len==limit)return error.RasterLimit;try cuts.append(allocator,y);}
fn intersect(a:coverage.Clip,b:coverage.Clip) coverage.Clip {
    const x=@max(@as(i64,a.x),@as(i64,b.x));const y=@max(@as(i64,a.y),@as(i64,b.y));
    const right=@min(@as(i64,a.x)+@max(a.width,0),@as(i64,b.x)+@max(b.width,0));const bottom=@min(@as(i64,a.y)+@max(a.height,0),@as(i64,b.y)+@max(b.height,0));
    if(right<=x or bottom<=y)return .{.width=0,.height=0};return .{.x=@intCast(x),.y=@intCast(y),.width=@intCast(right-x),.height=@intCast(bottom-y)};
}
