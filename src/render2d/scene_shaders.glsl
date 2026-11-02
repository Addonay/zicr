// Full retained renderer shader programs. All sampling is explicit and nearest
// at texel centers; filters are evaluated manually for portable float textures.
@vs scene_vs
layout(binding=0) uniform frame_params { vec4 frame_size; };
in vec2 position;
in vec2 texcoord0;
out vec2 canvas_position;
out vec2 uv;
void main() {
    gl_Position=vec4(position.x*2.0/frame_size.x-1.0,1.0-position.y*2.0/frame_size.y,0.0,1.0);
    canvas_position=position;uv=texcoord0;
}
@end

@block color_functions
float srgb_encode_channel(float v) { float x=abs(v);return sign(v)*(x<=0.0031308?12.92*x:1.055*pow(x,1.0/2.4)-0.055); }
float srgb_decode_channel(float v) { float x=abs(v);return sign(v)*(x<=0.04045?x/12.92:pow((x+0.055)/1.055,2.4)); }
vec3 srgb_encode(vec3 v) {return vec3(srgb_encode_channel(v.r),srgb_encode_channel(v.g),srgb_encode_channel(v.b));}
vec3 srgb_decode(vec3 v) {return vec3(srgb_decode_channel(v.r),srgb_decode_channel(v.g),srgb_decode_channel(v.b));}
vec3 from_oklab(vec3 v) {
    vec3 q=vec3(v.x+0.3963377774*v.y+0.2158037573*v.z,v.x-0.1055613458*v.y-0.0638541728*v.z,v.x-0.0894841775*v.y-1.2914855480*v.z);q=q*q*q;
    return vec3(4.0767416621*q.x-3.3077115913*q.y+0.2309699292*q.z,-1.2684380046*q.x+2.6097574011*q.y-0.3413193965*q.z,-0.0041960863*q.x-0.7034186147*q.y+1.7076147010*q.z);
}
vec3 convert_color_space(vec3 c,int from_space,int to_space){
    if(from_space==1||from_space==3)c=srgb_decode(c);
    bool from_p3=from_space>=2;bool to_p3=to_space>=2;
    if(from_p3&&!to_p3)c=vec3(1.22494017628056*c.r-0.22494017628056*c.g,-0.04205695470969*c.r+1.04205695470969*c.g,-0.01963755459033*c.r-0.07863604555063*c.g+1.09827360014097*c.b);
    if(!from_p3&&to_p3)c=vec3(0.82246196871436*c.r+0.17753803128564*c.g,0.03319419885096*c.r+0.96680580114904*c.g,0.01708263072112*c.r+0.07239744066396*c.g+0.91051992861492*c.b);
    if(to_space==1||to_space==3)c=srgb_encode(c);return c;
}
vec4 convert_interpolation(vec4 p,int interpolation,int working) {
    if(p.a==0.0)return vec4(0.0);vec3 c=p.rgb/p.a;
    if(interpolation==1)c=srgb_decode(c);if(interpolation==2)c=from_oklab(c);
    if(working==1)c=srgb_encode(c);return vec4(c*p.a,p.a);
}
@end

@block paint_declarations
layout(binding=1) uniform paint_params { vec4 paint_data[16]; };
layout(binding=0) uniform texture2D coverage_tex;
layout(binding=1) uniform texture2D stop_tex;
layout(binding=2) uniform texture2D pattern_tex;
layout(binding=3) uniform texture2D mesh_tex;
layout(binding=4) uniform texture2D mesh_index_tex;
layout(binding=0) uniform sampler nearest_sampler;
in vec2 canvas_position;
in vec2 uv;
@end

@block paint_functions
@include_block color_functions
vec4 table_read(texture2D table,int index) {
    ivec2 size=textureSize(sampler2D(table,nearest_sampler),0);ivec2 p=ivec2(index%size.x,index/size.x);
    return textureLod(sampler2D(table,nearest_sampler),(vec2(p)+0.5)/vec2(size),0.0);
}
float geometric_coverage() {
    vec4 bounds=paint_data[4];
    if(int(paint_data[0].w)==0) {
        vec2 low=max(bounds.xy,canvas_position-0.5);vec2 high=min(bounds.zw,canvas_position+0.5);vec2 extent=clamp(high-low,0.0,1.0);return extent.x*extent.y;
    }
    if(int(paint_data[0].w)==2){vec2 p=canvas_position/vec2(textureSize(sampler2D(coverage_tex,nearest_sampler),0));if(paint_data[15].z!=0.0)p.y=1.0-p.y;return textureLod(sampler2D(coverage_tex,nearest_sampler),p,0.0).r;}
    ivec2 pixel=ivec2(floor(canvas_position-bounds.xy+paint_data[5].xy));ivec2 size=textureSize(sampler2D(coverage_tex,nearest_sampler),0);
    if(any(lessThan(pixel,ivec2(0)))||any(greaterThanEqual(pixel,size)))return 0.0;
    return textureLod(sampler2D(coverage_tex,nearest_sampler),(vec2(pixel)+0.5)/vec2(size),0.0).r;
}
float extended_parameter(float value,float first,float last,int mode,out bool valid) {
    valid=true;if(last<=first)return value;float size=last-first;
    if(mode==0)return clamp(value,first,last);
    if(mode==1)return first+mod(value-first,size);
    if(mode==2){float v=mod(value-first,2.0*size);return first+(v<=size?v:2.0*size-v);}
    if(value<first||value>last)valid=false;return value;
}
vec4 gradient_color(float parameter) {
    int base=int(paint_data[6].x);int count=int(paint_data[6].y);if(count==0)return vec4(0.0);
    float first=table_read(stop_tex,base).x;float last=table_read(stop_tex,base+2*(count-1)).x;bool valid;
    float t=extended_parameter(parameter,first,last,int(paint_data[6].z),valid);if(!valid)return vec4(0.0);
    int low=0;int high=count;
    for(int iteration=0;iteration<32;++iteration){if(low>=high)break;int middle=low+(high-low)/2;float offset=table_read(stop_tex,base+2*middle).x;if(offset<=t)low=middle+1;else high=middle;}
    vec4 value;
    if(low==0)value=table_read(stop_tex,base+1);
    else if(low==count)value=table_read(stop_tex,base+2*(count-1)+1);
    else {float a=table_read(stop_tex,base+2*(low-1)).x;float b=table_read(stop_tex,base+2*low).x;vec4 ca=table_read(stop_tex,base+2*(low-1)+1);vec4 cb=table_read(stop_tex,base+2*low+1);value=mix(ca,cb,clamp((t-a)/(b-a),0.0,1.0));}
    return convert_interpolation(value,int(paint_data[3].w),int(paint_data[0].z));
}
int extend_index(int value,int size,int mode,out bool valid) {
    valid=true;if(mode==0)return clamp(value,0,size-1);
    if(mode==1)return int(mod(float(value),float(size)));
    if(mode==2){int p=int(mod(float(value),float(2*size)));return p<size?p:2*size-1-p;}
    if(value<0||value>=size)valid=false;return clamp(value,0,size-1);
}
vec4 image_texel(ivec2 coordinate,int level) {
    vec4 region=paint_data[9];vec2 scale=exp2(vec2(float(level)));ivec2 origin=ivec2(floor(region.xy/scale));ivec2 extent=max(ivec2(1),ivec2(floor(region.zw/scale)));bool valid_x;bool valid_y;
    ivec2 p=ivec2(extend_index(coordinate.x,extent.x,int(paint_data[10].y),valid_x),extend_index(coordinate.y,extent.y,int(paint_data[10].z),valid_y));if(!valid_x||!valid_y)return vec4(0.0);p+=origin;
    ivec2 size=textureSize(sampler2D(pattern_tex,nearest_sampler),level);if(paint_data[10].w!=0.0)p.y=size.y-1-p.y;
    vec4 value=textureLod(sampler2D(pattern_tex,nearest_sampler),(vec2(p)+0.5)/vec2(size),float(level));
    if(int(paint_data[11].w)==2)value.a=1.0;
    if(int(paint_data[11].w)==1&&value.a>0.0)value.rgb/=value.a;
    value.rgb=convert_color_space(value.rgb,int(paint_data[11].z),int(paint_data[0].z));
    return vec4(value.rgb*value.a,value.a);
}
float filter_kernel(float input_value,int kind) {
    float x=abs(input_value);if(kind==3){if(x>=3.0)return 0.0;if(x<0.000001)return 1.0;float p=3.141592653589793*x;return sin(p)*sin(p/3.0)/(p*p/3.0);}
    if(x>=2.0)return 0.0;if(x<1.0)return (7.0*x*x*x-12.0*x*x+16.0/3.0)/6.0;return (-7.0/3.0*x*x*x+12.0*x*x-20.0*x+32.0/3.0)/6.0;
}
vec4 image_level(vec2 position,int level) {
    vec2 p=position/exp2(float(level));int filter_kind=int(paint_data[10].x);
    if(filter_kind==0)return image_texel(ivec2(floor(p)),level);
    vec2 centered=p-0.5;ivec2 base=ivec2(floor(centered));vec2 fraction=fract(centered);
    if(filter_kind==1)return mix(mix(image_texel(base,level),image_texel(base+ivec2(1,0),level),fraction.x),mix(image_texel(base+ivec2(0,1),level),image_texel(base+ivec2(1,1),level),fraction.x),fraction.y);
    vec4 value=vec4(0.0);float total=0.0;int radius=filter_kind==2?2:3;
    for(int y=-2;y<=3;++y)for(int x=-2;x<=3;++x){if(x<1-radius||x>radius||y<1-radius||y>radius)continue;float weight=filter_kernel(centered.x-float(base.x+x),filter_kind)*filter_kernel(centered.y-float(base.y+y),filter_kind);value+=image_texel(base+ivec2(x,y),level)*weight;total+=weight;}
    if(total!=0.0)value/=total;if(value.a<=0.0)return vec4(0.0);if(value.a>1.0)value/=value.a;return value;
}
vec4 image_color(vec2 position) {
    float lod=clamp(paint_data[14].x,0.0,paint_data[14].z-1.0);int mode=int(paint_data[14].y);if(mode==0)return image_level(position,0);int low=int(mode==1?floor(lod+0.5):floor(lod));vec4 a=image_level(position,low);if(mode==1||float(low)>=paint_data[14].z-1.0)return a;return mix(a,image_level(position,low+1),fract(lod));
}
vec3 barycentric(vec2 p,vec2 a,vec2 b,vec2 c) {
    vec2 v=b-a;vec2 w=c-a;vec2 q=p-a;float determinant=v.x*w.y-v.y*w.x;
    if(determinant==0.0)return vec3(-1.0);float y=(q.x*w.y-q.y*w.x)/determinant;float z=(v.x*q.y-v.y*q.x)/determinant;return vec3(1.0-y-z,y,z);
}
void mesh_coordinates(inout vec2 image_position,out vec4 vertex_color) {
    vertex_color=vec4(1.0);int count=int(paint_data[12].y);if(count==0)return;
    int columns=int(paint_data[13].x);int rows=int(paint_data[13].y);int tile_size=int(paint_data[12].w);ivec2 tile=clamp(ivec2(floor(canvas_position/float(tile_size))),ivec2(0),ivec2(columns-1,rows-1));
    vec4 range=table_read(mesh_index_tex,int(paint_data[12].z)+tile.y*columns+tile.x);int first=int(range.x);int length=int(range.y);float best=1e30;vec3 selected=vec3(1.0,0.0,0.0);int chosen=-1;
    for(int i=0;i<length;++i){int triangle=int(table_read(mesh_index_tex,int(paint_data[13].z)+first+i).x);int base=int(paint_data[12].x)+triangle*6;vec4 positions=table_read(mesh_tex,base);vec4 tail=table_read(mesh_tex,base+1);vec3 weights=barycentric(canvas_position,positions.xy,positions.zw,tail.xy);float outside=max(0.0,-weights.x)+max(0.0,-weights.y)+max(0.0,-weights.z);if(outside<best){best=outside;chosen=base;selected=weights;}if(outside==0.0)break;}
    if(chosen<0)return;vec4 uv01=table_read(mesh_tex,chosen+2);vec4 uv2=table_read(mesh_tex,chosen+1);image_position=(selected.x*uv01.xy+selected.y*uv01.zw+selected.z*uv2.zw)*paint_data[9].zw;
    vertex_color=selected.x*table_read(mesh_tex,chosen+3)+selected.y*table_read(mesh_tex,chosen+4)+selected.z*table_read(mesh_tex,chosen+5);
}
vec4 evaluate_paint() {
    int kind=int(paint_data[0].x);vec2 p=vec2(dot(paint_data[1].xyz,vec3(canvas_position,1.0)),dot(paint_data[2].xyz,vec3(canvas_position,1.0)));vec4 tint;
    mesh_coordinates(p,tint);vec4 value=vec4(0.0);
    if(kind==0)value=paint_data[3];
    else if(kind==1)value=gradient_color(p.x);
    else if(kind==2){vec2 delta=paint_data[8].xy;float r0=paint_data[7].z;float dr=paint_data[7].w-r0;float a=dot(delta,delta)-dr*dr;float b=-2.0*(dot(p,delta)+r0*dr);float c=dot(p,p)-r0*r0;float t=0.0;bool valid=true;if(abs(a)<1e-20){if(abs(b)<1e-20)valid=c==0.0;else t=-c/b;}else{float discriminant=b*b-4.0*a*c;if(discriminant<0.0)valid=false;else{float root=sqrt(max(0.0,discriminant));float t0=(-b-root)/(2.0*a);float t1=(-b+root)/(2.0*a);bool v0=r0+t0*dr>=0.0;bool v1=r0+t1*dr>=0.0;valid=v0||v1;t=v0?(v1?max(t0,t1):t0):t1;}}if(valid&&r0+t*dr>=0.0)value=gradient_color(t);}
    else if(kind==3){float angle=atan(p.y,p.x)-paint_data[8].z;float phase=paint_data[8].w>0.0?mod(angle,6.283185307179586):-mod(-angle,6.283185307179586);value=gradient_color(phase/paint_data[8].w);}
    else value=image_color(p);
    return value*tint*paint_data[0].y;
}
@end
@fs paint_fs
@include_block paint_declarations
@include_block paint_functions
layout(location=0) out vec4 source_color;
layout(location=1) out vec4 source_coverage;
void main(){float coverage=geometric_coverage();source_color=evaluate_paint();source_coverage=vec4(coverage,0.0,0.0,1.0);}
@end
@fs paint_over_fs
@include_block paint_declarations
@include_block paint_functions
out vec4 frag_color;
void main(){frag_color=evaluate_paint()*geometric_coverage();}
@end
@program paint scene_vs paint_fs
@program paint_over scene_vs paint_over_fs

@block composite_functions
float blend_lum(vec3 c){return dot(c,vec3(0.3,0.59,0.11));}
float blend_sat(vec3 c){return max(c.r,max(c.g,c.b))-min(c.r,min(c.g,c.b));}
vec3 set_lum(vec3 c,float target){c+=vec3(target-blend_lum(c));float l=blend_lum(c);float n=min(c.r,min(c.g,c.b));float x=max(c.r,max(c.g,c.b));if(n<0.0&&l!=n)c=vec3(l)+(c-vec3(l))*l/(l-n);if(x>1.0&&x!=l)c=vec3(l)+(c-vec3(l))*(1.0-l)/(x-l);return c;}
vec3 set_sat(vec3 c,float target){float n=min(c.r,min(c.g,c.b));float x=max(c.r,max(c.g,c.b));return x>n?(c-vec3(n))*target/(x-n):vec3(0.0);}
float artistic_channel(int mode,float s,float d){
    if(mode==15)return s*d;if(mode==16)return s+d-s*d;
    if(mode==17)return d<=0.5?2.0*s*d:1.0-2.0*(1.0-s)*(1.0-d);
    if(mode==18)return min(s,d);if(mode==19)return max(s,d);
    if(mode==20)return d<=0.0?0.0:(s>=1.0?1.0:min(1.0,d/(1.0-s)));
    if(mode==21)return d>=1.0?1.0:(s<=0.0?0.0:1.0-min(1.0,(1.0-d)/s));
    if(mode==22)return max(0.0,s+d-1.0);if(mode==23)return clamp(d+2.0*s-1.0,0.0,1.0);
    if(mode==24)return s<=0.5?min(d,2.0*s):max(d,2.0*s-1.0);
    if(mode==25)return s<=0.5?2.0*s*d:1.0-2.0*(1.0-s)*(1.0-d);
    if(mode==26){float dd=d<=0.25?((16.0*d-12.0)*d+4.0)*d:sqrt(max(0.0,d));return s<=0.5?d-(1.0-2.0*s)*d*(1.0-d):d+(2.0*s-1.0)*(dd-d);}
    if(mode==27)return abs(d-s);return s+d-2.0*s*d;
}
vec4 compose(int mode,vec4 s,vec4 d){
    if(mode==0)return s+d*(1.0-s.a);if(mode==1)return s;if(mode==2)return s*d.a;if(mode==3)return s*(1.0-d.a);if(mode==4)return s*d.a+d*(1.0-s.a);
    if(mode==5)return d+s*(1.0-d.a);if(mode==6)return d;if(mode==7)return d*s.a;if(mode==8)return d*(1.0-s.a);if(mode==9)return d*s.a+s*(1.0-d.a);
    if(mode==10)return s*(1.0-d.a)+d*(1.0-s.a);if(mode==11)return vec4(0.0);if(mode==12)return min(vec4(1.0),s+d);
    if(mode==13)return vec4(max(vec3(0.0),d.rgb-s.rgb)+s.rgb*(1.0-d.a),s.a+d.a-s.a*d.a);if(mode==14)return s*d;
    vec3 cs=s.a==0.0?vec3(0.0):s.rgb/s.a;vec3 cd=d.a==0.0?vec3(0.0):d.rgb/d.a;vec3 blended;
    if(mode==29)blended=set_lum(set_sat(cs,blend_sat(cd)),blend_lum(cd));
    else if(mode==30)blended=set_lum(set_sat(cd,blend_sat(cs)),blend_lum(cd));
    else if(mode==31)blended=set_lum(cs,blend_lum(cd));else if(mode==32)blended=set_lum(cd,blend_lum(cs));
    else blended=vec3(artistic_channel(mode,cs.r,cd.r),artistic_channel(mode,cs.g,cd.g),artistic_channel(mode,cs.b,cd.b));
    return vec4(s.rgb*(1.0-d.a)+d.rgb*(1.0-s.a)+s.a*d.a*blended,s.a+d.a-s.a*d.a);
}
@end
@fs composite_fs
@include_block composite_functions
layout(binding=1) uniform composite_params {vec4 composite_data;};
layout(binding=0) uniform texture2D source_tex;
layout(binding=1) uniform texture2D destination_tex;
layout(binding=2) uniform texture2D mask_tex;
layout(binding=0) uniform sampler nearest_sampler;
in vec2 canvas_position;in vec2 uv;out vec4 frag_color;
void main(){vec2 size=vec2(textureSize(sampler2D(source_tex,nearest_sampler),0));vec2 p=canvas_position/size;if(composite_data.z!=0.0)p.y=1.0-p.y;vec4 s=textureLod(sampler2D(source_tex,nearest_sampler),p,0.0)*composite_data.y;vec4 d=textureLod(sampler2D(destination_tex,nearest_sampler),p,0.0);float coverage=textureLod(sampler2D(mask_tex,nearest_sampler),p,0.0).r;vec4 result=composite_data.w!=0.0?s:compose(int(composite_data.x),s,d);frag_color=mix(d,result,coverage);}
@end
@program composite scene_vs composite_fs

@fs copy_fs
@include_block color_functions
layout(binding=1) uniform copy_params {vec4 copy_data;};
layout(binding=0) uniform texture2D input_tex;
layout(binding=0) uniform sampler nearest_sampler;
in vec2 canvas_position;in vec2 uv;out vec4 frag_color;
void main(){vec2 p=uv;if(copy_data.x!=0.0)p.y=1.0-p.y;vec4 value=textureLod(sampler2D(input_tex,nearest_sampler),p,0.0);if(value.a>0.0&&copy_data.y!=copy_data.z){vec3 c=value.rgb/value.a;c=convert_color_space(c,int(copy_data.y),int(copy_data.z));value.rgb=c*value.a;}frag_color=value*copy_data.w;}
@end
@program copy scene_vs copy_fs

@fs mask_fs
@include_block paint_declarations
@include_block paint_functions
out vec4 frag_color;
void main(){float value=evaluate_paint().a;if(paint_data[15].w!=0.0)value=1.0-value;frag_color=vec4(geometric_coverage()*value,0.0,0.0,1.0);}
@end
@program mask scene_vs mask_fs

@fs effect_fs
@include_block color_functions
@include_block composite_functions
layout(binding=1) uniform effect_params {vec4 effect_data[16];};
layout(binding=0) uniform texture2D first_tex;
layout(binding=1) uniform texture2D second_tex;
layout(binding=2) uniform texture2D effect_table;
layout(binding=0) uniform sampler nearest_sampler;
in vec2 canvas_position;in vec2 uv;out vec4 frag_color;
vec4 effect_read_table(int index){ivec2 size=textureSize(sampler2D(effect_table,nearest_sampler),0);ivec2 p=ivec2(index%size.x,index/size.x);return textureLod(sampler2D(effect_table,nearest_sampler),(vec2(p)+0.5)/vec2(size),0.0);}
vec4 effect_convert(vec4 p,bool to_effect){if(p.a<=0.0)return vec4(0.0);int working=int(effect_data[0].z);int space=int(effect_data[0].w);if(working==space)return p;vec3 c=p.rgb/p.a;c=(to_effect?(working==1):(space==1))?srgb_decode(c):srgb_encode(c);return vec4(c*p.a,p.a);}
int effect_index(int v,int size,int mode,out bool valid){valid=true;if(mode==0)return clamp(v,0,size-1);if(mode==1)return int(mod(float(v),float(size)));if(mode==2){int p=int(mod(float(v),float(2*size)));return p<size?p:2*size-1-p;}if(v<0||v>=size)valid=false;return clamp(v,0,size-1);}
vec4 effect_texel(texture2D image,ivec2 coordinate,int extend){ivec2 size=textureSize(sampler2D(image,nearest_sampler),0);bool vx;bool vy;ivec2 p=ivec2(effect_index(coordinate.x,size.x,extend,vx),effect_index(coordinate.y,size.y,extend,vy));if(!vx||!vy)return vec4(0.0);if(effect_data[0].y!=0.0)p.y=size.y-1-p.y;return effect_convert(textureLod(sampler2D(image,nearest_sampler),(vec2(p)+0.5)/vec2(size),0.0),true);}
vec4 effect_sample(texture2D image,vec2 position,int extend){vec2 p=position-0.5;ivec2 base=ivec2(floor(p));vec2 fraction=fract(p);return mix(mix(effect_texel(image,base,extend),effect_texel(image,base+ivec2(1,0),extend),fraction.x),mix(effect_texel(image,base+ivec2(0,1),extend),effect_texel(image,base+ivec2(1,1),extend),fraction.x),fraction.y);}
float component_transfer(float v,int channel){vec4 descriptor=effect_data[4+channel];int kind=int(descriptor.x);if(kind==0)return v;if(kind==3)return descriptor.y*v+descriptor.z;if(kind==4)return descriptor.y*pow(max(0.0,v),descriptor.z)+descriptor.w;int base=int(descriptor.y);int count=int(descriptor.z);if(count==0)return v;if(kind==2)return effect_read_table(base+min(count-1,int(floor(clamp(v,0.0,1.0)*float(count))))).x;if(count==1)return effect_read_table(base).x;float index=clamp(v,0.0,1.0)*float(count-1);int low=int(floor(index));if(low==count-1)return effect_read_table(base+low).x;return mix(effect_read_table(base+low).x,effect_read_table(base+low+1).x,fract(index));}
vec4 effect_value(){
    int kind=int(effect_data[0].x);vec2 p=canvas_position;vec4 a=effect_sample(first_tex,p,3);vec4 b=effect_sample(second_tex,p,3);
    if(kind==0)return a;
    if(kind==1){float sigma=effect_data[1].x;int radius=int(effect_data[1].y);vec2 direction=effect_data[2].xy;vec4 value=vec4(0.0);float total=0.0;if(sigma==0.0)return a;for(int i=-radius;i<=radius;++i){float weight=exp(-0.5*float(i*i)/(sigma*sigma));value+=effect_sample(first_tex,p+direction*float(i),int(effect_data[1].z))*weight;total+=weight;}return value/total;}
    if(kind==2)return effect_sample(first_tex,p-effect_data[1].xy,3);
    if(kind==3)return effect_data[1];
    if(kind==4){vec4 straight=a.a==0.0?vec4(0.0):vec4(a.rgb/a.a,a.a);vec4 result=vec4(dot(effect_data[4],straight)+effect_data[8].x,dot(effect_data[5],straight)+effect_data[8].y,dot(effect_data[6],straight)+effect_data[8].z,dot(effect_data[7],straight)+effect_data[8].w);if(effect_data[1].x!=0.0)result=clamp(result,0.0,1.0);result.a=clamp(result.a,0.0,1.0);return vec4(result.rgb*result.a,result.a);}
    if(kind==5){vec4 straight=a.a==0.0?vec4(0.0):vec4(a.rgb/a.a,a.a);vec4 value=clamp(vec4(component_transfer(straight.r,0),component_transfer(straight.g,1),component_transfer(straight.b,2),component_transfer(straight.a,3)),0.0,1.0);return vec4(value.rgb*value.a,value.a);}
    if(kind==6)return compose(int(effect_data[1].x),a,b);
    if(kind==7){vec4 k=effect_data[1];vec4 value=clamp(k.x*a*b+k.y*a+k.z*b+vec4(k.w),0.0,1.0);value.rgb=min(value.rgb,vec3(value.a));return value;}
    if(kind==8){int rx=int(effect_data[1].x);int ry=int(effect_data[1].y);bool dilate=effect_data[1].z!=0.0;vec4 value=dilate?vec4(0.0):vec4(1.0);for(int y=-ry;y<=ry;++y)for(int x=-rx;x<=rx;++x){vec4 sample_value=effect_sample(first_tex,p+vec2(float(x),float(y)),3);value=dilate?max(value,sample_value):min(value,sample_value);}return value;}
    if(kind==9){int width=int(effect_data[1].x);int height=int(effect_data[1].y);int base=int(effect_data[1].z);bool preserve=effect_data[1].w!=0.0;vec2 target=effect_data[2].xy;float divisor=effect_data[2].z;float bias=effect_data[2].w;int extend=int(effect_data[3].x);vec4 value=vec4(0.0);for(int y=0;y<height;++y)for(int x=0;x<width;++x){vec4 sample_value=effect_sample(first_tex,p+vec2(float(x),float(y))-target,extend);if(preserve&&sample_value.a>0.0)sample_value=vec4(sample_value.rgb/sample_value.a,0.0);float weight=effect_read_table(base+(height-1-y)*width+width-1-x).x/divisor;value+=sample_value*weight;}if(preserve){vec3 rgb=clamp(value.rgb+vec3(bias),0.0,1.0);return vec4(rgb*a.a,a.a);}value=clamp(value+vec4(bias),0.0,1.0);value.rgb=min(value.rgb,vec3(value.a));return value;}
    if(kind==10){vec4 straight=b.a==0.0?vec4(0.0):vec4(b.rgb/b.a,b.a);int xc=int(effect_data[1].y);int yc=int(effect_data[1].z);return effect_sample(first_tex,p+effect_data[1].x*(vec2(straight[xc],straight[yc])-0.5),3);}
    if(kind==11){vec4 region=effect_data[1];vec2 local=mod(p-region.xy,region.zw)-0.5;ivec2 base=ivec2(floor(local));vec2 fraction=fract(local);vec4 taps[4];for(int i=0;i<4;++i){ivec2 q=base+ivec2(i%2,i/2);q=ivec2(int(mod(float(q.x),region.z)),int(mod(float(q.y),region.w)));taps[i]=effect_texel(first_tex,q+ivec2(region.xy),3);}return mix(mix(taps[0],taps[1],fraction.x),mix(taps[2],taps[3],fraction.x),fraction.y);}
    if(kind==12){vec4 shadow=effect_sample(first_tex,p-effect_data[1].xy,3);vec4 colored=effect_data[2]*shadow.a;return effect_data[1].z!=0.0?colored:compose(0,b,colored);}
    return vec4(0.0);
}
void main(){frag_color=effect_convert(effect_value(),false);}
@end
@program effect scene_vs effect_fs
