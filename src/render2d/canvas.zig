//! Stateful convenience API over an owned Scene. Save/restore snapshots immutable
//! clip-chain IDs and style IDs; it never needs to reconstruct discarded clips.
const std=@import("std");
const scenes=@import("scene.zig");
const paths=@import("path.zig");
const paints=@import("paint.zig");
const colors=@import("color.zig");
const geo=@import("geometry.zig");
const strokes=@import("stroke.zig");
const compositing=@import("composite.zig");
pub const Error=scenes.Error||error{RestoreUnderflow,LayerStateMismatch,InvalidTransform};
const Saved=struct{state:scenes.State,layer_depth:u32};
pub const Canvas=struct{
    scene:*scenes.Scene,
    state:scenes.State,
    stack:std.ArrayList(Saved)=.empty,
    current_path:paths.Path,
    pub fn init(scene:*scenes.Scene) Error!Canvas {
        const paint=try scene.addPaint(.{.solid=.black});const stroke=try scene.addStroke(.{});
        return .{.scene=scene,.state=.{.paint=paint,.stroke=stroke},.current_path=paths.Path.init(scene.allocator)};
    }
    pub fn deinit(self:*Canvas) void {self.current_path.deinit();self.stack.deinit(self.scene.allocator);self.*=undefined;}
    pub fn save(self:*Canvas) Error!void {try self.stack.append(self.scene.allocator,.{.state=self.state,.layer_depth=self.scene.layer_depth});}
    pub fn restore(self:*Canvas) Error!void {
        if(self.stack.items.len==0)return error.RestoreUnderflow;
        const saved=self.stack.items[self.stack.items.len-1];if(saved.layer_depth!=self.scene.layer_depth)return error.LayerStateMismatch;
        self.state=saved.state;self.stack.items.len-=1;
    }
    pub fn setPaint(self:*Canvas,paint:paints.Paint) Error!void {self.state.paint=try self.scene.addPaint(paint);}
    pub fn setStroke(self:*Canvas,style:scenes.StrokeStyle) Error!void {self.state.stroke=try self.scene.addStroke(style);}
    pub fn setAlpha(self:*Canvas,alpha:f64) Error!void {if(!std.math.isFinite(alpha) or alpha<0 or alpha>1)return error.InvalidState;self.state.alpha=alpha;}
    pub fn setComposite(self:*Canvas,mode:compositing.Mode) void {self.state.mode=mode;}
    pub fn setTransform(self:*Canvas,transform:geo.Affine) Error!void {if(!transform.finite())return error.InvalidTransform;self.state.transform=transform;}
    pub fn transform(self:*Canvas,matrix:geo.Affine) Error!void {try self.setTransform(geo.Affine.mul(self.state.transform,matrix));}
    pub fn translate(self:*Canvas,x:f64,y:f64) Error!void {try self.transform(geo.Affine.translation(x,y));}
    pub fn scale(self:*Canvas,x:f64,y:f64) Error!void {try self.transform(geo.Affine.scaling(x,y));}
    pub fn rotate(self:*Canvas,angle:f64) Error!void {try self.transform(geo.Affine.rotation(angle));}
    pub fn resetTransform(self:*Canvas) void {self.state.transform=.{};}
    pub fn beginPath(self:*Canvas) void {self.current_path.clear();}
    pub fn moveTo(self:*Canvas,point:geo.Point) Error!void {try self.current_path.moveTo(point);}
    pub fn lineTo(self:*Canvas,point:geo.Point) Error!void {try self.current_path.lineTo(point);}
    pub fn quadTo(self:*Canvas,control:geo.Point,end:geo.Point) Error!void {try self.current_path.quadTo(control,end);}
    pub fn cubicTo(self:*Canvas,a:geo.Point,b:geo.Point,end:geo.Point) Error!void {try self.current_path.cubicTo(a,b,end);}
    pub fn conicTo(self:*Canvas,control:geo.Point,end:geo.Point,weight:f64) Error!void {try self.current_path.conicTo(control,end,weight);}
    pub fn closePath(self:*Canvas) Error!void {if(self.current_path.current!=null)try self.current_path.close();}
    pub fn arc(self:*Canvas,center:geo.Point,radii:geo.Point,rotation:f64,start:f64,sweep:f64) Error!void {try self.current_path.arc(center,radii,rotation,start,sweep);}
    pub fn svgArcTo(self:*Canvas,radii:geo.Point,rotation:f64,large:bool,clockwise:bool,end:geo.Point) Error!void {try self.current_path.svgArcTo(radii,rotation,large,clockwise,end);}
    pub fn fill(self:*Canvas,rule:paths.FillRule) Error!void {try self.fillPath(&self.current_path,rule);}
    pub fn stroke(self:*Canvas) Error!void {try self.strokePath(&self.current_path);}
    pub fn fillPath(self:*Canvas,path:*const paths.Path,rule:paths.FillRule) Error!void {const id=try self.scene.addPath(path);try self.scene.fill(id,self.state,rule);}
    pub fn strokePath(self:*Canvas,path:*const paths.Path) Error!void {const id=try self.scene.addPath(path);try self.scene.stroke(id,self.state);}
    pub fn fillRect(self:*Canvas,rect:geo.Rect) Error!void {var path=paths.Path.init(self.scene.allocator);defer path.deinit();try path.addRect(rect);try self.fillPath(&path,.nonzero);}
    pub fn strokeRect(self:*Canvas,rect:geo.Rect) Error!void {var path=paths.Path.init(self.scene.allocator);defer path.deinit();try path.addRect(rect);try self.strokePath(&path);}
    pub fn fillRoundedRect(self:*Canvas,rect:geo.Rect,radii:geo.Point) Error!void {var path=paths.Path.init(self.scene.allocator);defer path.deinit();try path.roundedRect(rect,radii);try self.fillPath(&path,.nonzero);}
    pub fn fillEllipse(self:*Canvas,center:geo.Point,radii:geo.Point,rotation:f64) Error!void {var path=paths.Path.init(self.scene.allocator);defer path.deinit();try path.ellipse(center,radii,rotation);try self.fillPath(&path,.nonzero);}
    pub fn clearRect(self:*Canvas,rect:geo.Rect) Error!void {const saved=self.state;defer self.state=saved;self.state.mode=.clear;self.state.alpha=1;try self.fillRect(rect);}
    pub fn clip(self:*Canvas,rule:paths.FillRule,inverse:bool) Error!void {try self.clipPath(&self.current_path,rule,inverse);}
    pub fn clipPath(self:*Canvas,path:*const paths.Path,rule:paths.FillRule,inverse:bool) Error!void {
        const id=try self.scene.addPath(path);self.state.clip=try self.scene.addClip(.{.parent=self.state.clip,.geometry=.{.path=.{.path=id,.rule=rule}},.transform=self.state.transform,.inverse=inverse});
    }
    pub fn clipImage(self:*Canvas,pattern:paints.Pattern,inverse:bool) Error!void {self.state.clip=try self.scene.addClip(.{.parent=self.state.clip,.geometry=.{.image=pattern},.transform=self.state.transform,.inverse=inverse});}
    pub fn resetClip(self:*Canvas) void {self.state.clip=null;}
    pub fn beginLayer(self:*Canvas,layer:scenes.Layer) Error!void {var value=layer;value.transform=self.state.transform;if(value.clip==null)value.clip=self.state.clip;try self.scene.beginLayer(value);}
    pub fn endLayer(self:*Canvas) Error!void {try self.scene.endLayer();}
    pub fn drawImage(self:*Canvas,image:paints.ImageSource,source:?@import("image.zig").Region,destination:geo.Rect,sampling:@import("image.zig").Sampling) Error!void {
        if(!scenes.validRect(destination))return error.InvalidState;
        const size=paints.imageSize(image);const region=source orelse @import("image.zig").Region{.width=size[0],.height=size[1]};
        if(destination.width==0 or destination.height==0)return;
        const mapping=geo.Affine.mul(geo.Affine.translation(destination.x,destination.y),geo.Affine.scaling(destination.width/@as(f64,@floatFromInt(region.width)),destination.height/@as(f64,@floatFromInt(region.height))));
        const saved=self.state;defer self.state=saved;
        try self.setPaint(.{.image=.{.image=image,.region=region,.transform=mapping,.sampling=sampling}});try self.fillRect(destination);
    }
    pub fn drawMesh(self:*Canvas,vertices:[]const scenes.MeshVertex,indices:[]const u32) Error!void {const id=try self.scene.addMesh(vertices,indices);try self.scene.drawMesh(id,self.state);}
};
