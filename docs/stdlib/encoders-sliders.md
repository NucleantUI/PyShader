# Knobs, encoders & sliders

The controls of a synth, a mixer or a hi-fi, drawn with the standard library:
`sdf` for their parts, `material` for what each part is made of, `light` for
the rings and tubes that show their values. Nothing here is a library
function of its own; each control is a few of the library's, put together.

```py
from pyshader.stdlib.fragment import sdf, light, material
from pyshader.stdlib.fragment.surface import shade, shade_ambient
```

A knob turns 270°, 135° each way from the top. The examples measure its angle
in radians clockwise from the top, so a value `v` from 0 to 1 points at
`(2v - 1) · 0.75π`, in the direction `float2(sin(a), cos(a))`.

## Value rings: `sd_ring` and `neon`

`sd_ring(p, n, r, th)` is a piece of a ring of radius `r`, `th` thick, with
flat ends, centered on the top; `n` is the cosine and sine of half its angle.
Turned with `rotate2d`, it runs between any two angles, which is the whole of
a value ring:

```py
def ring_piece(p: float2, start: float, end: float, r: float, th: float) -> float:
    half = max(0.5 * (end - start), 0.0005)
    return sdf.sd_ring(rotate2d(0.5 * (start + end)) * p, float2(cos(half), sin(half)), r, th)
```

With `th` 0 the piece is its own center line, and `neon` on that distance is a
tube of light along the arc. With a thickness, the piece is a bar with square
ends: `glow` lights it from inside, `neon` traces its outline. Left to right:
a tube from the start of the travel to the value; a bipolar tube for pan or
balance, from the top, warm to the left and cool to the right; fifteen
segments lit green to red; a tube whose color follows the angle, an `led`
riding its head.

```pyshader aspect="4:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light
from pyshader.stdlib.fragment.matrix import rotate2d
from pyshader.stdlib.fragment.color import hsb_to_rgb

SWEEP = 0.75 * PI    # 270° of travel: 135° each way from the top
RING = 0.36          # the radius the value ring runs on


def ring_piece(p: float2, start: float, end: float, r: float, th: float) -> float:
    """sd_ring from `start` to `end`, radians clockwise from the top."""
    half = max(0.5 * (end - start), 0.0005)
    return sdf.sd_ring(rotate2d(0.5 * (start + end)) * p, float2(cos(half), sin(half)), r, th)


def turn(v: float) -> float:
    """Where value v (0..1) points on the travel."""
    return (2.0 * v - 1.0) * SWEEP


def cap(p: float2, a: float) -> float3:
    """A plain black knob, its pointer at angle a."""
    n = light.bevel_normal(sdf.sd_circle(p, 0.25), normalize(p + float2(0.0001)), 0.05)
    l = normalize(float3(-0.4, 0.6, 1.0))
    c = float3(0.035) * (0.3 + 0.7 * light.lambert(n, l)) + float3(0.12) * light.blinn_phong(n, l, 20.0)
    tip = float2(sin(a), cos(a))
    return mix(c, float3(0.8), sdf.fill_smooth(sdf.sd_segment(p, tip * 0.1, tip * 0.19) - 0.01, 0.003))


def value_ring(i: float, p: float2, v: float) -> float3:
    a = turn(v)
    groove = float3(0.03) * sdf.fill_smooth(ring_piece(p, -SWEEP, SWEEP, RING, 0.0) - 0.012, 0.002)
    if i < 0.5:
        return groove + light.neon(ring_piece(p, -SWEEP, a, RING, 0.0), float3(0.1, 0.75, 1.0), 0.014, 0.025)
    if i < 1.5:
        tint = float3(1.0, 0.45, 0.1) if a < 0.0 else float3(0.2, 1.0, 0.6)
        return groove + light.neon(ring_piece(p, min(a, 0.0), max(a, 0.0), RING, 0.0), tint, 0.014, 0.025)
    if i < 2.5:
        # The segment nearest p and its two neighbours, so their glows overlap.
        count = 15.0
        pitch = 2.0 * SWEEP / count
        k0 = clamp(floor((atan2(p.x, p.y) + SWEEP) / pitch), 0.0, count - 1.0)
        c = float3(0.0)
        for j in range(3):
            k = clamp(k0 + float(j) - 1.0, 0.0, count - 1.0)
            start = -SWEEP + k * pitch
            d = ring_piece(p, start + 0.03, start + pitch - 0.03, RING, 0.05)
            tint = hsb_to_rgb(float3(0.33 * (1.0 - k / (count - 1.0)), 0.9, 1.0))
            lit = step(k + 0.5, v * count)
            c = max(c, tint * (0.06 + 0.94 * lit) * light.glow(d, 0.004 + 0.008 * lit))
        return c
    t = clamp((atan2(p.x, p.y) + SWEEP) / (2.0 * SWEEP), 0.0, 1.0)
    tint = hsb_to_rgb(float3(0.55 + 0.4 * t, 0.85, 1.0))
    c = groove + light.neon(ring_piece(p, -SWEEP, a, RING, 0.0), tint, 0.01, 0.02)
    return c + light.led(p - RING * float2(sin(a), cos(a)), float3(1.0, 0.5, 0.9), 0.018, 0.03)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 4.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    v = 0.5 + 0.48 * sin(0.8 * time + 1.9 * i)
    c = float3(0.025, 0.027, 0.033) + value_ring(i, p, v)
    c *= 1.0 - 0.7 * light.drop_shadow(sdf.sd_circle(p - float2(0.02, -0.03), 0.25), 0.03)
    c = mix(c, cap(p, turn(v)), sdf.fill_smooth(sdf.sd_circle(p, 0.25), 0.003))
    return float4(light.tonemap_exposure(c, 1.4), 1.0)
```

Four more. A glass tube around the whole travel, outlined in `neon` and
filled up to the value, brighter along the inside of its walls
(`glow_inner`); a modulation ring inside the value ring, how far an LFO
swings the value, an LED where it is now; a selector of eight pieces, the
knob snapping from one to the next as a detent does, the piece it rests on
outlined; a range, its two ends LEDs, the tube between them.

```pyshader aspect="4:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light
from pyshader.stdlib.fragment.matrix import rotate2d

SWEEP = 0.75 * PI
RING = 0.36
STEPS = 8.0


def ring_piece(p: float2, start: float, end: float, r: float, th: float) -> float:
    half = max(0.5 * (end - start), 0.0005)
    return sdf.sd_ring(rotate2d(0.5 * (start + end)) * p, float2(cos(half), sin(half)), r, th)


def turn(v: float) -> float:
    return (2.0 * v - 1.0) * SWEEP


def on_ring(a: float, r: float) -> float2:
    return r * float2(sin(a), cos(a))


def cap(p: float2, a: float) -> float3:
    n = light.bevel_normal(sdf.sd_circle(p, 0.25), normalize(p + float2(0.0001)), 0.05)
    l = normalize(float3(-0.4, 0.6, 1.0))
    c = float3(0.035) * (0.3 + 0.7 * light.lambert(n, l)) + float3(0.12) * light.blinn_phong(n, l, 20.0)
    tip = float2(sin(a), cos(a))
    return mix(c, float3(0.8), sdf.fill_smooth(sdf.sd_segment(p, tip * 0.1, tip * 0.19) - 0.01, 0.003))


def detent(v: float) -> float:
    """v over the eight steps, 0..7, moving on only between them, as a detent does."""
    s = v * (STEPS - 1.0)
    return floor(s) + smoothstep(0.4, 0.6, fract(s))


def step_angle(k: float) -> float:
    """The middle of step k."""
    return -SWEEP + (k + 0.5) * 2.0 * SWEEP / STEPS


def range_ends(time: float) -> float2:
    return float2(turn(0.25 + 0.18 * sin(0.6 * time)), turn(0.72 + 0.2 * sin(0.9 * time + 1.0)))


def pointer(i: float, v: float, time: float) -> float:
    if i > 1.5 and i < 2.5:
        return step_angle(detent(v))
    if i > 2.5:
        ends = range_ends(time)
        return 0.5 * (ends.x + ends.y)
    return turn(v)


def value_ring(i: float, p: float2, v: float, time: float) -> float3:
    a = turn(v)
    if i < 0.5:
        tint = float3(1.0, 0.25, 0.6)
        tube = ring_piece(p, -SWEEP, SWEEP, RING, 0.06)
        fill = ring_piece(p, -SWEEP + 0.03, a, RING, 0.045)
        c = 0.5 * light.neon(tube, tint, 0.004, 0.01)
        return c + tint * (0.15 + 0.85 * light.glow_inner(fill, 0.01)) * sdf.fill_smooth(fill, 0.002)
    if i < 1.5:
        c = light.neon(ring_piece(p, -SWEEP, a, RING, 0.0), float3(0.2, 0.8, 1.0), 0.012, 0.022)
        depth = 0.5 + 0.3 * sin(0.37 * time)
        lo = max(a - depth, -SWEEP)
        hi = min(a + depth, SWEEP)
        r = RING - 0.055
        c += light.neon(ring_piece(p, lo, hi, r, 0.0), float3(0.85, 0.2, 1.0), 0.006, 0.012)
        lfo = clamp(a + depth * sin(4.0 * time), lo, hi)
        return c + light.led(p - on_ring(lfo, r), float3(0.9, 0.3, 1.0), 0.012, 0.02)
    if i < 2.5:
        position = detent(v)
        half = SWEEP / STEPS
        k0 = clamp(floor((atan2(p.x, p.y) + SWEEP) / (2.0 * half)), 0.0, STEPS - 1.0)
        tint = float3(1.0, 0.7, 0.2)
        c = float3(0.0)
        for j in range(3):
            k = clamp(k0 + float(j) - 1.0, 0.0, STEPS - 1.0)
            d = ring_piece(p, step_angle(k) - half + 0.05, step_angle(k) + half - 0.05, RING, 0.045)
            lit = clamp(1.0 - abs(position - k), 0.0, 1.0)
            body = tint * (0.08 + 0.3 * lit) * sdf.fill_smooth(d, 0.002)
            c = max(c, body + lit * light.neon(d, tint, 0.006, 0.014))
        return c
    ends = range_ends(time)
    c = light.neon(ring_piece(p, ends.x, ends.y, RING, 0.0), float3(1.0, 0.5, 0.1), 0.01, 0.02)
    c += light.led(p - on_ring(ends.x, RING), float3(1.0, 0.85, 0.5), 0.018, 0.028)
    return c + light.led(p - on_ring(ends.y, RING), float3(1.0, 0.85, 0.5), 0.018, 0.028)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 4.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    v = 0.5 + 0.48 * sin(0.6 * time + 2.3 * i)
    c = float3(0.025, 0.027, 0.033) + value_ring(i, p, v, time)
    c *= 1.0 - 0.7 * light.drop_shadow(sdf.sd_circle(p - float2(0.02, -0.03), 0.25), 0.03)
    c = mix(c, cap(p, pointer(i, v, time)), sdf.fill_smooth(sdf.sd_circle(p, 0.25), 0.003))
    return float4(light.tonemap_exposure(c, 1.4), 1.0)
```

## Textured knobs

Knobs as things, made of something: metal, rubber, plastic, wood, glass.
Each is lit as physically based renderers light a surface, so its parts stay
what they are as the light moves.

### Two materials

A knob seen from above is two parts: the top, flat or domed, its edge rounded
over (`bevel_normal`); and the side, sloping down and out to the panel. Each
part gets its own normal and its own material, and `shade` lights them both
under one light. The side's grip is a height field turning with the knob,
`surface.bump` tilting the side's normal by its slope; `surface.blend` paints
the pointer onto the top.

Spun aluminum reflects light as a streak through its center, toward the
light: its fine circular grooves are a highlight that runs along them
(Kajiya and Kay's, for hair), a few lines of its own over
`brushed_metal`'s rings. Left to right: a spun aluminum top on a ribbed
black rubber side; a domed gold top on twelve flutes of glossy black
plastic; copper on walnut; polished silver on knurled aluminum, the
pointer painted red.

```pyshader aspect="4:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light, material
from pyshader.stdlib.fragment.surface import Surface, shade, shade_ambient, bump, blend, with_normal
from pyshader.stdlib.fragment.color import linear_to_srgb

VIEW = float3(0.0, 0.0, 1.0)
SUN = float3(3.0)
SWEEP = 0.75 * PI
TOP = 0.19       # the top's radius
BASE = 0.31      # where the side meets the panel


def studio(r: float3, l: float3) -> float3:
    """What a shiny part mirrors: a dark room, a soft box where the light is."""
    room = mix(float3(0.015), float3(0.1, 0.11, 0.13), smoothstep(-0.6, 0.8, r.y))
    return room + float3(2.0) * pow(max(dot(r, l), 0.0), 12.0)


def lit(s: Surface, l: float3) -> float3:
    return shade(s, l, VIEW, SUN) + shade_ambient(s, VIEW, float3(0.04), studio(reflect(-VIEW, s.normal), l))


def spun(p: float2, l: float3) -> float:
    """Turned metal's streak: grooves running round, lit where they cross the light's direction."""
    t = normalize(float2(-p.y, p.x) + float2(0.00001))
    h = normalize(l + VIEW)
    th = dot(t, h.xy)
    return pow(max(1.0 - th * th, 0.0), 300.0)


def grip(k: int, p: float2, a: float) -> float:
    """The side's relief, 0..1, turning with the knob (a)."""
    q = atan2(p.x, p.y) - a
    if k == 0:
        return 0.5 + 0.5 * cos(q * 36.0)              # ribs
    if k == 1:
        return 1.0 - abs(sin(q * 6.0))               # twelve flutes
    if k == 3:
        u = q * 48.0 / (2.0 * PI)
        w = length(p) * 30.0
        return min(abs(2.0 * fract(u + w) - 1.0), abs(2.0 * fract(u - w) - 1.0))   # knurling
    return 0.0


def side(k: int, p: float2, n: float3) -> Surface:
    if k == 0:
        return material.rubber(p * 4.0, n, float3(0.02))
    if k == 1:
        return material.plastic(n, float3(0.012), 0.16)
    if k == 2:
        return material.wood(p * 5.0 + float2(4.0, 1.0), n, float3(0.3, 0.16, 0.08), float3(0.09, 0.045, 0.02))
    return material.metal(n, material.ALUMINUM, 0.32)


def top(k: int, p: float2, n: float3, mark: float) -> Surface:
    if k == 0:
        # Brushed in circles: the streaks run along the angle, so only the radius counts.
        s = with_normal(material.brushed_metal(float2(0.0, length(p) * 1.5), n, material.ALUMINUM, 0.0), n)
        return blend(s, Surface(float3(0.01), n, 0.7, 0.0, 0.04), mark)      # an engraved line
    if k == 1:
        return blend(material.metal(n, material.GOLD, 0.2), material.plastic(n, float3(0.8, 0.78, 0.7), 0.4), mark)
    if k == 2:
        return blend(material.metal(n, material.COPPER, 0.18), Surface(float3(0.02), n, 0.7, 0.0, 0.04), mark)
    return blend(material.metal(n, material.SILVER, 0.07), material.plastic(n, float3(0.7, 0.03, 0.02), 0.35), mark)


def knob(k: int, p: float2, a: float, l: float3) -> float4:
    """The knob turned to a, lit from l: its color and how much of the pixel it covers."""
    r = length(p)
    out = p / max(r, 0.0001)
    tip = float2(sin(a), cos(a))
    # The side: out and down from the top's edge, steeper toward the panel, its grip on it.
    t = clamp((r - TOP) / (BASE - TOP), 0.0, 1.0)
    tilt = 0.45 + 0.85 * t
    e = 0.001
    g = grip(k, p, a)
    slope = float2(grip(k, p + float2(e, 0.0), a) - g, grip(k, p + float2(0.0, e), a) - g) / e
    n = bump(normalize(float3(out * sin(tilt), cos(tilt))), slope, 0.006 if k == 3 else 0.004)
    c = lit(side(k, p, n), l) * smoothstep(0.0, 0.015, r - TOP)       # dark in the seam under the top
    # The top: domed a little (not the spun one), its edge rounded over.
    dome = 0.0 if k == 0 else (0.45 if k == 2 else 0.25)
    lip = light.bevel_normal(r - TOP, out, 0.02)
    n = normalize(float3(p * dome / TOP + lip.xy / lip.z, 1.0))
    mark = sdf.fill_smooth(sdf.sd_segment(p, tip * 0.05, tip * (TOP - 0.035)) - 0.007, 0.002)
    if k == 1:
        mark = sdf.fill_smooth(sdf.sd_circle(p - tip * (TOP - 0.05), 0.017), 0.002)
    face = lit(top(k, p, n, mark), l)
    if k == 0:
        face += material.ALUMINUM * SUN * 0.12 * spun(p, l) * (1.0 - mark)
    c = mix(c, face, sdf.fill_smooth(r - TOP, 0.002))
    edge = r - BASE + (0.008 * (1.0 - g) if k < 2 else 0.0)            # ribs and flutes notch the outline
    return float4(c, sdf.fill_smooth(edge, 0.002))


def ticks(p: float2) -> float:
    """Eleven printed ticks around the travel, the middle and ends longer."""
    pitch = 2.0 * SWEEP / 10.0
    k = clamp(floor((atan2(p.x, p.y) + SWEEP) / pitch + 0.5), 0.0, 10.0)
    a = -SWEEP + k * pitch
    d = float2(sin(a), cos(a))
    reach = 0.425 if mod(k, 5.0) < 0.5 else 0.4
    return sdf.fill_smooth(sdf.sd_segment(p, d * 0.36, d * reach) - 0.004, 0.002)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 4.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    a = (2.0 * (0.5 + 0.45 * sin(0.5 * time + 1.3 * i)) - 1.0) * SWEEP
    l = normalize(float3(-0.45 + 0.3 * sin(0.4 * time), 0.55, 0.8))
    panel = material.plastic(VIEW, mix(float3(0.012), float3(0.6), ticks(p)), 0.85)
    c = lit(panel, l) * (1.0 - 0.8 * light.drop_shadow(sdf.sd_circle(p + l.xy * 0.05, BASE), 0.035))
    k = knob(int(i), p, a, l)
    c = mix(c, k.rgb, k.a)
    return float4(linear_to_srgb(light.tonemap_aces(c)), 1.0)
```

### Light on the materials

The lights so far sat beside the knobs. Here they fall on them. Left to
right: a glass top, `material.glass` over a well with the pointer in neon,
bent by the dome as a lens bends it (`refraction_offset`); a light pipe, a
ring of light between an aluminum top and a rubber side, its color the
value, its glow spilling over both; an LED ring on the panel, each LED
lighting the side of the knob that faces it; and a chrome knob mirroring the
neon value ring around it. A metal shows what it reflects, so the ring is
part of what `shade_ambient` is given: the chrome's side looks out and down
at the panel, and sees the ring lit over the angles the value covers.

```pyshader aspect="4:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light, material
from pyshader.stdlib.fragment.surface import Surface, shade, shade_ambient, with_normal
from pyshader.stdlib.fragment.matrix import rotate2d
from pyshader.stdlib.fragment.color import linear_to_srgb, hsb_to_rgb

VIEW = float3(0.0, 0.0, 1.0)
SUN = float3(2.5)
SWEEP = 0.75 * PI
TOP = 0.19
BASE = 0.29
RING = 0.38
LEDS = 21.0


def studio(r: float3, l: float3) -> float3:
    room = mix(float3(0.01), float3(0.07, 0.08, 0.1), smoothstep(-0.6, 0.8, r.y))
    return room + float3(2.0) * pow(max(dot(r, l), 0.0), 12.0)


def lit(s: Surface, l: float3, reflected: float3) -> float3:
    return shade(s, l, VIEW, SUN) + shade_ambient(s, VIEW, float3(0.03), reflected)


def ring_piece(p: float2, start: float, end: float, r: float, th: float) -> float:
    half = max(0.5 * (end - start), 0.0005)
    return sdf.sd_ring(rotate2d(0.5 * (start + end)) * p, float2(cos(half), sin(half)), r, th)


def side_normal(p: float2, a: float, ribs: float) -> float3:
    """Out and down from the top's edge to the panel, `ribs` grooves turning with the knob."""
    r = length(p)
    out = p / max(r, 0.0001)
    tilt = 0.45 + 0.85 * clamp((r - TOP) / (BASE - TOP), 0.0, 1.0)
    groove = 0.25 * sin((atan2(p.x, p.y) - a) * ribs) * step(0.5, ribs)
    return normalize(float3(out * sin(tilt) + float2(out.y, -out.x) * groove, cos(tilt)))


def top_normal(p: float2, dome: float) -> float3:
    r = length(p)
    lip = light.bevel_normal(r - TOP, p / max(r, 0.0001), 0.02)
    return normalize(float3(p * dome / TOP + lip.xy / lip.z, 1.0))


def under_glass(q: float2, a: float, tint: float3) -> float3:
    """The well under the glass top: dark, lit by the pointer, a neon line."""
    tip = float2(sin(a), cos(a))
    c = float3(0.004) + tint * 0.05 * (1.0 - smoothstep(0.0, TOP, length(q)))
    return c + light.neon(sdf.sd_segment(q, tip * 0.03, tip * (TOP - 0.05)), tint, 0.008, 0.02)


def led_light(k: float, v: float) -> float3:
    """LED k of the ring: green to red around it, lit up to v, the last one fading in."""
    tint = hsb_to_rgb(float3(0.33 * (1.0 - k / (LEDS - 1.0)), 0.9, 1.0))
    return tint * (0.02 + clamp(v * (LEDS - 1.0) - k + 1.0, 0.0, 1.0))


def led_ring(p: float2, v: float) -> float3:
    pitch = 2.0 * SWEEP / (LEDS - 1.0)
    k0 = clamp(floor((atan2(p.x, p.y) + SWEEP) / pitch + 0.5), 0.0, LEDS - 1.0)
    c = float3(0.0)
    for j in range(3):
        k = clamp(k0 + float(j) - 1.0, 0.0, LEDS - 1.0)
        a = -SWEEP + k * pitch
        c = max(c, light.led(p - RING * float2(sin(a), cos(a)), led_light(k, v), 0.01, 0.012))
    return c


def spill(p: float2, v: float) -> float3:
    """The light of the LEDs nearest the angle of p, blended across, for what faces them."""
    s = clamp((atan2(p.x, p.y) + SWEEP) / (2.0 * SWEEP / (LEDS - 1.0)), 0.0, LEDS - 1.0)
    k = floor(s)
    return mix(led_light(k, v), led_light(min(k + 1.0, LEDS - 1.0), v), fract(s))


def mirrored_ring(r: float3, a: float, tint: float3) -> float3:
    """The value ring as a mirror sees it from the knob's side: out and down, over the lit angles."""
    angle = atan2(r.x, r.y)
    lit_angles = smoothstep(-SWEEP - 0.05, -SWEEP + 0.05, angle) * (1.0 - smoothstep(a - 0.05, a + 0.05, angle))
    return tint * 4.0 * lit_angles * exp(-pow((r.z + 0.35) / 0.18, 2.0))


def panel_light(k: int, p: float2, a: float, v: float, tint: float3) -> float3:
    if k == 2:
        return led_ring(p, v)
    if k == 3:
        return light.neon(ring_piece(p, -SWEEP, a, RING, 0.0), tint, 0.012, 0.025)
    return float3(0.0)


def knob(k: int, p: float2, a: float, v: float, l: float3, tint: float3) -> float4:
    r = length(p)
    tip = float2(sin(a), cos(a))
    n = side_normal(p, a, 0.0 if k == 3 else 30.0)
    s = material.rubber(p * 4.0, n, float3(0.02))
    if k == 3:
        s = material.metal(n, material.SILVER, 0.06)
    reflected = studio(reflect(-VIEW, n), l)
    if k == 3:
        reflected += mirrored_ring(reflect(-VIEW, n), a, tint)
    c = lit(s, l, reflected) * smoothstep(0.0, 0.015, r - TOP)
    if k == 2:
        c += spill(p, v) * 0.35 * max(dot(n.xy, p / r), 0.0) * smoothstep(TOP, BASE, r)
    # The top.
    n = top_normal(p, 0.6 if k == 0 else 0.15)
    mark = sdf.fill_smooth(sdf.sd_segment(p, tip * 0.05, tip * (TOP - 0.035)) - 0.007, 0.002)
    if k == 0:
        behind = under_glass(p + material.refraction_offset(n, material.GLASS_IOR, 0.12), a, tint)
        face = material.glass(behind, n, l, SUN, studio(reflect(-VIEW, n), l), float3(0.95), material.GLASS_IOR, 1.0)
    else:
        top = material.metal(n, material.SILVER if k == 3 else material.ALUMINUM, 0.06 if k == 3 else 0.3)
        top = Surface(mix(top.albedo, float3(0.02), mark), n, mix(top.roughness, 0.7, mark), 1.0 - mark, 0.04)
        face = lit(top, l, studio(reflect(-VIEW, n), l))
    c = mix(c, face, sdf.fill_smooth(r - TOP, 0.002))
    if k == 1:
        # The light pipe: a ring glowing in the seam, its color the value.
        c += tint * 1.5 * light.glow(abs(r - TOP - 0.004) - 0.006, 0.006)
    return float4(c, sdf.fill_smooth(r - BASE, 0.002))


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 4.0
    i = floor(uv.x * cells)
    k = int(i)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    v = 0.5 + 0.47 * sin(0.55 * time + 1.7 * i)
    a = (2.0 * v - 1.0) * SWEEP
    l = normalize(float3(-0.45 + 0.3 * sin(0.4 * time), 0.55, 0.8))
    tint = float3(0.15, 0.7, 1.0)
    if k == 1:
        tint = hsb_to_rgb(float3(0.62 * (1.0 - v), 0.85, 1.0))
    if k == 3:
        tint = float3(1.0, 0.25, 0.55)
    c = lit(material.plastic(VIEW, float3(0.012), 0.85), l, float3(0.02))
    c *= 1.0 - 0.8 * light.drop_shadow(sdf.sd_circle(p + l.xy * 0.05, BASE), 0.035)
    c += panel_light(k, p, a, v, tint)
    m = knob(k, p, a, v, l, tint)
    c = mix(c, m.rgb, m.a)
    return float4(linear_to_srgb(light.tonemap_aces(c)), 1.0)
```

## Cyberpunk encoders & sliders

Controls for a screen rather than a panel: no caps and no materials, only
flat shapes on black, lit by the lights in `light`.

### Flat encoders

A touch screen's encoder has no cap: it is only its ring, a thick
`sd_ring`, the whole travel in grey and the value's piece lit over it, its
flat ends cut along the radius. Lit means one of the lights: here the value
glows from inside, `glow_inner` brightening its edges and `glow` spilling
over the track around it, or it is outlined in `neon` over a dim fill.
Pieces that start at the top are bipolar (the large one). The panels are
`sd_rounded_box` outlines in `neon`, and the two toggles are lit buttons, on
or off.

```pyshader aspect="2:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light
from pyshader.stdlib.fragment.matrix import rotate2d
from pyshader.stdlib.fragment.coords import centered

SWEEP = 0.75 * PI
ORANGE = float3(1.0, 0.42, 0.06)
GREEN = float3(0.2, 1.0, 0.35)
# x, y, radius, kind: 0 from the start, 1 from the top (bipolar), 2 outlined in neon
ENCODERS = [
    float4(-0.73, 0.02, 0.17, 1.0),
    float4(-0.4, 0.19, 0.085, 0.0),
    float4(-0.17, 0.19, 0.085, 0.0),
    float4(-0.4, -0.17, 0.085, 0.0),
    float4(-0.17, -0.17, 0.085, 0.0),
    float4(0.155, 0.14, 0.1, 2.0),
    float4(0.385, 0.14, 0.1, 2.0),
    float4(0.615, 0.14, 0.1, 2.0),
    float4(0.845, 0.14, 0.1, 2.0),
    float4(0.615, -0.24, 0.075, 2.0),
    float4(0.845, -0.24, 0.075, 2.0),
]
TOGGLES = [float2(0.155, -0.24), float2(0.385, -0.24)]


def ring_piece(p: float2, start: float, end: float, r: float, th: float) -> float:
    half = max(0.5 * (end - start), 0.0005)
    return sdf.sd_ring(rotate2d(0.5 * (start + end)) * p, float2(cos(half), sin(half)), r, th)


def encoder(p: float2, e: float4, v: float, tint: float3) -> float3:
    """The encoder at e.xy of radius e.z, set to v: a thick grey ring, the value lit over it."""
    q = p - e.xy
    r = e.z * 0.7
    th = e.z * 0.6
    a = (2.0 * v - 1.0) * SWEEP
    start = 0.0 if abs(e.w - 1.0) < 0.5 else -SWEEP
    value = ring_piece(q, min(start, a), max(start, a), r, th)
    inside = sdf.fill_smooth(value, 0.002)
    c = float3(0.1) * sdf.fill_smooth(ring_piece(q, -SWEEP, SWEEP, r, th), 0.002) * (1.0 - inside)
    if e.w > 1.5:
        return c + tint * 0.25 * inside + light.neon(value, tint, 0.004, 0.01)
    lit = (tint + float3(0.2)) * (0.7 + 0.7 * light.glow_inner(min(value, 0.0), th * 0.15))
    return c + lit * inside + tint * 0.4 * light.glow(value, 0.008) * (1.0 - inside)


def toggle(p: float2, center: float2, on: float, tint: float3) -> float3:
    """A button: a frame in neon, its face lit when on."""
    d = sdf.sd_rounded_box(p - center, float2(0.075, 0.06), float4(0.015))
    face = d + 0.014
    c = 0.4 * light.neon(d, tint, 0.003, 0.006)
    lit = mix(tint, float3(1.0), 0.6) * (0.7 + 0.5 * light.glow_inner(min(face, 0.0), 0.02)) * sdf.fill_smooth(face, 0.002)
    return c + on * (lit + tint * 0.4 * light.glow(face, 0.015) * (1.0 - sdf.fill_smooth(face, 0.002)))


def frame(p: float2, center: float2, tint: float3) -> float3:
    return 0.6 * light.neon(sdf.sd_rounded_box(p - center, float2(0.47, 0.45), float4(0.03)), tint, 0.004, 0.012)


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = 0.5 * centered(uv, resolution)
    c = float3(0.008) + frame(p, float2(-0.5, 0.0), ORANGE) + frame(p, float2(0.5, 0.0), GREEN)
    for i in range(11):
        e = ENCODERS[i]
        v = 0.5 + 0.47 * sin(time * (0.35 + 0.05 * float(i)) + 1.7 * float(i))
        c += encoder(p, e, v, GREEN if e.w > 1.5 else ORANGE)
    for i in range(2):
        c += toggle(p, TOGGLES[i], step(0.5, fract(0.2 * time + 0.45 * float(i))), GREEN)
    return float4(light.tonemap_exposure(c, 1.3), 1.0)
```

### Endless encoders

An encoder has no end stops: it turns round and round, and the ring around it
shows where it is. Left to right: 24 LEDs, `led_ring_index` and
`led_ring_position` finding and placing them, `chase` running a tail behind
the one the encoder points at as it clicks on a detent at a time; a light
guide, the encoder turned back and forth, its position a short `neon` arc on
a dim ring, and its middle a push button that flashes the ring when pressed;
a turn counter, the inner arc the angle within one turn and the outer LEDs
the whole turns, one more lit each time round.

```pyshader aspect="3:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light
from pyshader.stdlib.fragment.matrix import rotate2d

RING = 0.38
CYAN = float3(0.15, 0.75, 1.0)
MAGENTA = float3(1.0, 0.1, 0.55)
YELLOW = float3(1.0, 0.8, 0.1)


def ring_piece(p: float2, start: float, end: float, r: float, th: float) -> float:
    half = max(0.5 * (end - start), 0.0005)
    return sdf.sd_ring(rotate2d(0.5 * (start + end)) * p, float2(cos(half), sin(half)), r, th)


def around(a: float, r: float) -> float2:
    """The point at angle a, clockwise from the top, on a circle of radius r."""
    return r * float2(sin(a), cos(a))


def cap(p: float2, tip: float2, press: float, tint: float3) -> float3:
    """A dark encoder, its pointer toward `tip`, its middle a button lit by `press`."""
    n = light.bevel_normal(sdf.sd_circle(p, 0.26), normalize(p + float2(0.0001)), 0.05)
    l = normalize(float3(-0.4, 0.6, 1.0))
    c = float3(0.035) * (0.3 + 0.7 * light.lambert(n, l)) + float3(0.12) * light.blinn_phong(n, l, 20.0)
    c = mix(c, float3(0.8), sdf.fill_smooth(sdf.sd_segment(p, tip * 0.18, tip * 0.23) - 0.008, 0.002))
    button = sdf.sd_circle(p, 0.11)
    c *= 1.0 - 0.7 * sdf.stroke_smooth(button, 0.006, 0.002)
    return c + tint * press * (0.2 + light.glow_inner(button, 0.03)) * sdf.fill_smooth(button, 0.002)


def main(uv: float2, time: float, resolution: float2) -> float4:
    cells = 3.0
    i = floor(uv.x * cells)
    p = float2(fract(uv.x * cells) - 0.5, (uv.y - 0.5) * cells * resolution.y / resolution.x)
    lights = float3(0.0)
    tip = float2(0.0, 1.0)
    press = 0.0
    tint = CYAN
    if i < 0.5:
        # A detent at a time; the LEDs count counterclockwise from +x.
        count = 24.0
        s = time * 3.0
        head = floor(s) + smoothstep(0.0, 0.35, fract(s))
        i0 = light.led_ring_index(p, count)
        for k in range(3):
            led = mod(i0 + float(k) - 1.0, count)
            level = light.chase(led, count, head, 8.0)
            lights = max(lights, (0.03 + level) * light.led(p - light.led_ring_position(led, count, RING), CYAN, 0.011, 0.014))
        tip = normalize(light.led_ring_position(head, count, 1.0))
    elif i < 1.5:
        a = 2.2 * sin(0.8 * time) + 0.5 * time
        press = exp(-4.0 * mod(time, 3.0))
        tint = mix(MAGENTA, float3(1.0), 0.5 * press)
        guide = abs(length(p) - RING)
        lights = tint * (0.05 + 0.6 * press) * light.glow(guide - 0.008, 0.01)
        lights += light.neon(ring_piece(p, a - 0.3, a + 0.3, RING, 0.0), tint, 0.012, 0.025)
        tip = around(a, 1.0)
    else:
        a = 1.3 * time
        turns = a / (2.0 * PI)
        lights = light.neon(ring_piece(p, 0.0, fract(turns) * 2.0 * PI, RING - 0.03, 0.0), CYAN, 0.01, 0.02)
        whole = mod(floor(turns), 13.0)
        k0 = mod(floor(atan2(p.x, p.y) / (2.0 * PI) * 12.0 + 0.5), 12.0)
        leds = float3(0.0)
        for j in range(3):
            slot = mod(k0 + float(j) - 1.0, 12.0)
            lit = step(slot + 0.5, whole)
            leds = max(leds, (0.03 + lit) * light.led(p - around(2.0 * PI * slot / 12.0, RING + 0.065), YELLOW, 0.008, 0.01))
        lights += leds
        tip = around(a, 1.0)
    c = float3(0.02, 0.022, 0.028) * (1.0 - 0.7 * light.drop_shadow(sdf.sd_circle(p - float2(0.02, -0.03), 0.26), 0.03))
    c += lights
    c = mix(c, cap(p, tip, press, tint), sdf.fill_smooth(sdf.sd_circle(p, 0.26), 0.003))
    return float4(light.tonemap_exposure(c, 1.4), 1.0)
```

### Sliders

The same lights along a straight line. A track is `sd_segment`, a bar
`sd_box`; the fill runs from the left (or the middle) to the value. Top to
bottom: a `neon` fill with an `led` for the thumb; a bipolar slider from the
middle, its fill a tube of light (`segment_light`) and its thumb a lit tab;
an LED ladder showing a level, cyan to magenta, its peak held a moment and falling; a flat
bar lit from inside, its edge at the value a neon line; and a ring for the
thumb, a circle's edge in `neon`, the track lit up to it.

```pyshader aspect="2:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light
from pyshader.stdlib.fragment.coords import centered
from pyshader.stdlib.fragment.color import hsb_to_rgb

LEFT = -0.85
RIGHT = 0.85


def meter(t: float) -> float:
    """Something like the level of music."""
    return clamp(0.45 + 0.3 * sin(2.1 * t) * sin(0.37 * t) + 0.2 * abs(sin(7.3 * t)), 0.0, 1.0)


def held_peak(t: float) -> float:
    """The highest level of the last second and a bit, falling from where it was."""
    peak = 0.0
    for i in range(16):
        back = float(i) * 0.08
        peak = max(peak, meter(t - back) - 0.25 * back)
    return peak


def lit_shape(d: float, tint: float3, edge: float) -> float3:
    """A shape lit from inside, brighter along its edges, glowing around."""
    inside = sdf.fill_smooth(d, 0.002)
    return (tint + float3(0.2)) * (0.6 + 0.6 * light.glow_inner(min(d, 0.0), edge)) * inside + tint * 0.5 * light.glow(d, 0.01) * (1.0 - inside)


def slider(j: float, q: float2, v: float, time: float) -> float3:
    x = mix(LEFT, RIGHT, v)
    groove = float3(0.06) * sdf.fill_smooth(sdf.sd_segment(q, float2(LEFT, 0.0), float2(RIGHT, 0.0)) - 0.008, 0.002)
    if j < 0.5:
        tint = float3(0.1, 0.75, 1.0)
        c = groove + light.neon(sdf.sd_segment(q, float2(LEFT, 0.0), float2(x, 0.0)), tint, 0.01, 0.02)
        return c + light.led(q - float2(x, 0.0), tint, 0.022, 0.035)
    if j < 1.5:
        tint = float3(1.0, 0.8, 0.1)
        x = 0.85 * (2.0 * v - 1.0)
        end = float2(0.002 if abs(x) < 0.002 else x, 0.0)
        c = groove + float3(0.2) * sdf.fill_smooth(sdf.sd_segment(q, float2(0.0, -0.04), float2(0.0, 0.04)) - 0.003, 0.002)
        c += tint * 0.8 * light.segment_light(q, float2(0.0), end, 0.01)
        return c + lit_shape(sdf.sd_rounded_box(q - float2(x, 0.0), float2(0.018, 0.05), float4(0.01)), tint, 0.01)
    if j < 2.5:
        count = 24.0
        pitch = (RIGHT - LEFT) / (count - 1.0)
        k0 = clamp(floor((q.x - LEFT) / pitch + 0.5), 0.0, count - 1.0)
        peak = floor(held_peak(time) * count)
        c = float3(0.0)
        for n in range(3):
            k = clamp(k0 + float(n) - 1.0, 0.0, count - 1.0)
            tint = hsb_to_rgb(float3(0.5 + 0.42 * k / (count - 1.0), 0.9, 1.0))
            lit = max(step(k + 0.5, v * count), 1.0 - step(0.5, abs(k - peak)))
            d = sdf.sd_rounded_box(q - float2(LEFT + k * pitch, 0.0), float2(pitch * 0.32, 0.035), float4(0.008))
            c = max(c, tint * (0.05 + 0.95 * lit) * light.glow(d, 0.003 + 0.006 * lit))
        return c
    if j < 3.5:
        tint = float3(1.0, 0.1, 0.55)
        bar = sdf.sd_box(q, float2(RIGHT, 0.04))
        fill = sdf.sd_box(q - float2(0.5 * (LEFT + x), 0.0), float2(0.5 * (x - LEFT), 0.04))
        c = tint * 0.1 * sdf.fill_smooth(bar, 0.002) * (1.0 - sdf.fill_smooth(fill, 0.002))
        c += lit_shape(fill, tint * 0.8, 0.02)
        return c + light.neon(sdf.sd_segment(q, float2(x, -0.04), float2(x, 0.04)), tint, 0.006, 0.015)
    tint = float3(0.85, 0.3, 1.0)
    clear = 1.0 - sdf.fill_smooth(sdf.sd_circle(q - float2(x, 0.0), 0.07), 0.004)
    c = groove * clear + tint * light.neon(sdf.sd_segment(q, float2(LEFT, 0.0), float2(x - 0.07, 0.0)), tint, 0.006, 0.012) * 0.5
    c += tint * 0.12 * sdf.fill_smooth(sdf.sd_circle(q - float2(x, 0.0), 0.045), 0.002)
    return c + light.neon(abs(sdf.sd_circle(q - float2(x, 0.0), 0.045)), tint, 0.008, 0.02)


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = 0.5 * centered(uv, resolution)
    j = clamp(floor((0.5 - p.y) * 5.0), 0.0, 4.0)
    q = float2(p.x, p.y - (0.4 - 0.2 * j))
    v = 0.5 + 0.45 * sin(0.5 * time + 1.3 * j)
    if j > 1.5 and j < 2.5:
        v = meter(time)
    # Each row's light fades out before the next row starts.
    c = float3(0.015, 0.016, 0.02) + slider(j, q, v, time) * (1.0 - smoothstep(0.06, 0.1, abs(q.y)))
    return float4(light.tonemap_exposure(c, 1.3), 1.0)
```

### Step bars and faders

A step sequencer's page: a row of bars per lane, each a slider of its own,
filled from the bottom to its value in a color running with the value, the
rest of the bar a dark tint of it, its top edge a `neon` line. The playhead
steps across them and lights the step it is on. Under them a lane of pads,
lit (`glow_inner`, `glow`) where a step is on, outlined white
(`glow_edge`) as the playhead passes. On the right, faders in neon frames:
a glowing thumb, and a tube of light (`segment_light`) in the slot under it.

```pyshader aspect="2:1"
from pyshader import *
from pyshader.stdlib.fragment import sdf, light
from pyshader.stdlib.fragment.coords import centered
from pyshader.stdlib.fragment.random import random1

THUMB = float3(0.5, 0.95, 1.0)


def column(p: float2, box: float4, count: float) -> float2:
    """Which of `count` columns across box (x0, y0, x1, y1) p is in, and where that column starts."""
    w = (box.z - box.x) / count
    k = clamp(floor((p.x - box.x) / w), 0.0, count - 1.0)
    return float2(k, box.x + k * w)


def cell(p: float2, x0: float, w: float, y0: float, y1: float) -> float:
    return sdf.sd_box(p - float2(x0 + 0.5 * w, 0.5 * (y0 + y1)), float2(0.5 * w - 0.005, 0.5 * (y1 - y0)))


def bars(p: float2, box: float4, count: float, playhead: float, low: float3, high: float3, seed: float, time: float) -> float3:
    w = (box.z - box.x) / count
    col = column(p, box, count)
    v = 0.2 + 0.75 * (0.5 + 0.5 * sin(0.35 * time + 6.28 * random1(col.x + seed)))
    level = mix(box.y, box.w, v)
    tint = mix(low, high, v)
    here = 1.0 - step(0.5, abs(col.x - playhead))
    filled = cell(p, col.y, w, box.y, level)
    inside = sdf.fill_smooth(filled, 0.001)
    c = tint * 0.14 * sdf.fill_smooth(cell(p, col.y, w, box.y, box.w), 0.001) * (1.0 - inside)
    c += tint * (0.7 + 0.5 * light.glow_inner(filled, 0.015) + 0.6 * here) * inside
    top = sdf.sd_segment(p, float2(col.y + 0.008, level), float2(col.y + w - 0.008, level))
    return c + light.neon(top, tint, 0.004, 0.01) * (0.4 + here)


def pads(p: float2, box: float4, count: float, playhead: float, tint: float3, seed: float) -> float3:
    w = (box.z - box.x) / count
    col = column(p, box, count)
    on = step(0.62, random1(col.x * 7.1 + seed))
    here = 1.0 - step(0.5, abs(col.x - playhead))
    d = cell(p, col.y, w, box.y, box.w)
    inside = sdf.fill_smooth(d, 0.001)
    c = tint * (0.12 + on * (0.8 + 0.6 * light.glow_inner(d, 0.02))) * inside
    c += tint * on * 0.4 * light.glow(d, 0.008) * (1.0 - inside)
    return c + float3(1.0) * here * (0.3 + 0.7 * on) * light.glow_edge(d, 0.003)


def scrollbar(p: float2, y: float, at: float) -> float3:
    track = sdf.sd_box(p - float2(-0.16, y), float2(0.82, 0.006))
    thumb = sdf.sd_box(p - float2(mix(-0.9, 0.58, at), y), float2(0.07, 0.006))
    return float3(0.05) * sdf.fill_smooth(track, 0.001) + float3(0.35) * sdf.fill_smooth(thumb, 0.001)


def fader(p: float2, box: float4, v: float, tint: float3) -> float3:
    center = float2(0.5 * (box.x + box.z), 0.5 * (box.y + box.w))
    half = float2(0.5 * (box.z - box.x), 0.5 * (box.w - box.y))
    frame = sdf.sd_rounded_box(p - center, half, float4(0.01))
    c = 0.5 * light.neon(frame, tint, 0.003, 0.008) + tint * 0.03 * sdf.fill_smooth(frame, 0.001)
    y = mix(box.y + 0.04, box.w - 0.04, v)
    c += THUMB * 0.3 * light.segment_light(p, float2(center.x, box.y + 0.02), float2(center.x, y), 0.008)
    thumb = sdf.sd_rounded_box(p - float2(center.x, y), float2(half.x - 0.014, 0.025), float4(0.006))
    inside = sdf.fill_smooth(thumb, 0.001)
    c = mix(c, THUMB * (0.8 + 0.6 * light.glow_inner(thumb, 0.01)), inside)
    return c + THUMB * 0.6 * light.glow(thumb, 0.012) * (1.0 - inside)


def main(uv: float2, time: float, resolution: float2) -> float4:
    p = 0.5 * centered(uv, resolution)
    c = float3(0.0)
    if p.x < 0.69:
        if p.y > -0.04:
            c = bars(p, float4(-0.98, -0.02, 0.66, 0.48), 13.0, floor(mod(time * 4.0, 13.0)),
                     float3(0.0, 0.28, 0.8), float3(0.0, 0.8, 0.75), 0.0, time)
        elif p.y > -0.075:
            c = scrollbar(p, -0.055, 0.5 + 0.5 * sin(0.2 * time))
        elif p.y > -0.335:
            c = bars(p, float4(-0.98, -0.32, 0.66, -0.09), 12.0, floor(mod(time * 4.0, 12.0)),
                     float3(1.0, 0.22, 0.0), float3(1.0, 0.78, 0.05), 5.0, time)
        elif p.y > -0.37:
            c = scrollbar(p, -0.352, 0.5 + 0.5 * sin(0.27 * time + 2.0))
        else:
            c = pads(p, float4(-0.98, -0.48, 0.66, -0.385), 12.0, floor(mod(time * 4.0, 12.0)), float3(0.5, 0.0, 1.0), 3.0)
    else:
        c = fader(p, float4(0.74, -0.02, 0.96, 0.48), 0.55 + 0.4 * sin(0.45 * time), float3(0.1, 0.6, 1.0))
        c += fader(p, float4(0.74, -0.4, 0.96, -0.09), 0.5 + 0.4 * sin(0.6 * time + 2.0), float3(1.0, 0.4, 0.05))
    return float4(light.tonemap_exposure(c, 1.3), 1.0)
```
