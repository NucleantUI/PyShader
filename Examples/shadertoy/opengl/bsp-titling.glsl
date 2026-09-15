// https://www.shadertoy.com/view/cdsXDr


// Random BSP Tiling 
// by Tom'2017
//
// Something I wrote back in 2017 but didn't care to release ;P
//
// Based on https://www.shadertoy.com/view/llG3zy (Faster Voronoi Borders)
// and https://www.shadertoy.com/view/4lBXRV (my older 15th Pentagonal Tiling)
//
// The idea is super simple:
// Start with one cell and recursively split chosing random normal/center.
//
// I didn't bother to add too much code comments, sorry ;P

// Do you like colors? 
//  Put 0 if not ;)
//  Put 1 for 12 colors
//  Put 2 for 6 colors
#define USE_COLORS 2

// Curved or straight lines?
#define CURVED 1

#define ANIM_SPEED 8.

const int iterations = 64;
const float dist_eps = .001;
const float ray_max = 200.0;
const float fog_density = .04;
const float fog_start = 16.;

const float cam_dist = 13.5;

//---------------------------------------------
// Tiling code

vec2 dTile( vec2 p )
{
   // Do N splits resulting 2^N areas.
   const int N = 14;
    
   // Lacunarity
   const float lac = .78;
   
   float p_scale = pow(lac,float(N))*4.;
   p *= p_scale;
   
   // Start at the center with normal vector up.
   vec2 split_c = vec2(0), split_n = vec2(0,1);
   float split_d = 4.;
   
   float min_d = 99.;
   
   vec4 cell = vec4(0);

   for(int i=0; i<N; ++i)
   {
      vec2 dp = p - split_c;
      vec2 perp_n = vec2(-split_n.y,split_n.x);
      
      // Parametrization:
      float u = dot(dp, perp_n);
      float v = dot(dp, split_n);

      // Sign distance to edge:
      float s = pow(1./lac,float(i));
#if CURVED == 1
      float d = v + sin(u*2.*s+sin(u*s)*(1.5+sin(iTime*ANIM_SPEED)))*.1/s;
#else
      float d = v;
#endif

      cell.xyz = vec3(u,v,d);
      
      // Find min. abs distance:
      min_d = min(min_d, abs(d));
      
      // Calculate next split center.
      float side = sign(d);
      cell.w += (side+1.)*split_d;
      split_c += side*split_n*split_d;
      split_n = normalize(perp_n + vec2(.1,.3));
      split_d *= lac;
   }

    return vec2( cell.w*1.5, min_d/p_scale*.8 );
}

//---------------------------------------------

const float bump = .15;
const float ground = .2;

float dField(in vec3 p)
{
   float d = p.y + ground;
   
   vec2 tile = dTile(p.xz);
   float d3;
   //d3 = min(.05,smoothstep(0.,1.,tile.y*20.)*.05)*.5;
   d3 = min(.05,tile.y)*.5;
   d3 += tile.y*.45;
   d3 = min(d3,bump);
   //d3 = smoothstep(0.,1.,d3/cut)*cut;
   d -= d3;
   return d;
}

vec3 dNormal(in vec3 p, in float eps)
{
   vec2 e = vec2(eps,0.);
#if 0
   // less pleasent, but faster
   e.x *= 2.;
   float v = dField(p);
   return normalize(vec3(
      dField(p + e.xyy) - v,
      dField(p + e.yxy) - v,
      dField(p + e.yyx) - v ));
#else
   return normalize(vec3(
      dField(p + e.xyy) - dField(p - e.xyy),
      dField(p + e.yxy) - dField(p - e.yxy),
      dField(p + e.yyx) - dField(p - e.yyx) ));
#endif
}

vec4 trace(in vec3 ray_start, in vec3 ray_dir)
{
   float ray_len = 0.0;
   vec3 p = ray_start;
   
   // Intersect with ground plane first
   
   if (ray_dir.y >= 0.) return vec4(0.);
   
   float dist;
   dist = (ray_start.y + ground - bump)/-ray_dir.y;
   p += dist*ray_dir;
   ray_len += dist;
   if (ray_len > ray_max) return vec4(0.);
   //return vec4(p, ray_len);
   
   for(int i=0; i<iterations; ++i) {
   	  dist = dField(p);
      if (dist < dist_eps*ray_len) break;
      if (ray_len > ray_max) return vec4(0.0);
      p += dist*ray_dir;
      ray_len += dist;
   }
   return vec4(p, ray_len);
}

vec3 shade(in vec3 ray_start, in vec3 ray_dir,
   in vec3 light_dir, in vec3 fog_color, in vec4 hit)
{   
   vec3 dir = hit.xyz - ray_start;
   vec3 norm = dNormal(hit.xyz, .015);//*hit.w);
   float diffuse = max(0.0, dot(norm, light_dir));
   float spec = max(0.0,dot(reflect(light_dir,norm),normalize(dir)));
   spec = pow(spec, 32.0)*.7;

   vec2 tile = dTile(hit.xz);
   float sh = tile.x;
#if USE_COLORS == 2
   sh = (abs(mod(sh+6.,12.)-6.)+2.5)*(1./9.);
#else
   sh = mod(sh,12.)*(1./12.);
#endif
   float sd = min(tile.y,.05)*20.;
#if USE_COLORS == 0
   vec3 base_color = vec3(.5);
#else
   // Ken Silverman's EvalDraw colors ;)
   vec3 base_color =
    vec3(exp(pow(sh-.75,2.)*-10.),
         exp(pow(sh-.50,2.)*-20.),
         exp(pow(sh-.25,2.)*-10.));
#endif
   vec3 color = mix(vec3(0.),vec3(1.),diffuse)*base_color +
      spec*vec3(1.,1.,.9);
   color *= sd;
   
   float fog_dist = max(0.,length(dir) - fog_start);
   float fog = 1.0 - 1.0/exp(fog_dist*fog_density);
   color = mix(color, fog_color, fog);

   return color;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
   vec2 uv = (fragCoord.xy - iResolution.xy*0.5) / iResolution.y;
    
   vec3 light_dir = normalize(vec3(.5, 1.0, .25));
   
   // Simple model-view matrix:
   float ms = 2.5/iResolution.y;
   float ang, si, co;
   ang = (iMouse.z > 0.0) ? (iMouse.x - iResolution.x*.5) * -ms : -iTime*.25;
   si = sin(ang); co = cos(ang);
   mat3 cam_mat = mat3(
      co, 0., si,
      0., 1., 0.,
     -si, 0., co);
   ang = (iMouse.z > 0.0) ? (iMouse.y - iResolution.y) * -ms - .1 :
      cos(-iTime*.5)*.4 + .8;
   ang = max(0.,ang);
   si = sin(ang); co = cos(ang);
   cam_mat = cam_mat * mat3(
      1., 0., 0.,
      0., co, si,
      0.,-si, co);

   vec3 pos = cam_mat*vec3(0., 0., -cam_dist);
   vec3 dir = normalize(cam_mat*vec3(uv, 1.));

   vec3 color;
   vec3 fog_color = vec3(min(1.,.4+max(-.1,dir.y*.8)));
   vec4 hit = trace(pos, dir);
   if (hit.w == 0.) {
      color = fog_color;
   } else {
      color = shade(pos, dir, light_dir, fog_color, hit);
   }
   
   // gamma correction:
   color = pow(color,vec3(.7));
   
   fragColor = vec4(color, 1.);
}
