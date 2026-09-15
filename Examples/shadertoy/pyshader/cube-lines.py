"""Cube lines

https://www.shadertoy.com/view/NslGRN — Danil (2021+), CC BY-NC-SA 3.0.
Port of opengl/cube-lines.glsl with the default defines (ROTATION_SPEED,
MOUSE_control, NO_ALPHA for the gallery; no AA, no DEBUG).

GLSL `out` parameters become tuple returns; `vec4[3]` locals become lists;
the `swap` macro is a Python tuple swap. A compute shader has no `fwidth`,
so `fcos` is the 8-tap fallback the original uses when derivatives are broken.
"""
from pyshader import *

tshift = 53.0

FDIST = 0.7
PI = 3.1415926
GROUNDSPACING = 0.5
GROUNDGRID = 0.05
BOXDIMS = float3(0.75, 0.75, 1.25)

IOR = 1.33

UP = float3(0.0, 1.0, 0.0)
# (hit, t, norm, self-intersect, tsi, normsi, fade, fadesi) when the patch is missed
NO_PATCH = (False, -1.0, UP, False, -1.0, UP, 1.0, 1.0)


def rotx(a: float) -> float3x3:
    s = sin(a)
    c = cos(a)
    return float3x3(float3(1.0, 0.0, 0.0), float3(0.0, c, s), float3(0.0, -s, c))


def roty(a: float) -> float3x3:
    s = sin(a)
    c = cos(a)
    return float3x3(float3(c, 0.0, s), float3(0.0, 1.0, 0.0), float3(-s, 0.0, c))


def rotz(a: float) -> float3x3:
    s = sin(a)
    c = cos(a)
    return float3x3(float3(c, s, 0.0), float3(-s, c, 0.0), float3(0.0, 0.0, 1.0))


def fcos(x: float3, resolution: float2) -> float3:
    # fcos1's no-derivative path: average 8 nearby samples
    tc = float3(0.0)
    for i in range(8):
        tc += cos(x + x * float(i - 4) * (0.01 * 400.0 / resolution.y))
    return tc / 8.0


def getColor(p: float3, resolution: float2) -> float3:
    p = abs(p)

    p *= 1.25
    p = 0.5 * p / dot(p, p)

    t = 0.13 * length(p)
    col = float3(0.3, 0.4, 0.5)
    col += 0.12 * fcos(6.28318 * t * 1.0 + float3(0.0, 0.8, 1.1), resolution)
    col += 0.11 * fcos(6.28318 * t * 3.1 + float3(0.3, 0.4, 0.1), resolution)
    col += 0.10 * fcos(6.28318 * t * 5.1 + float3(0.1, 0.7, 1.1), resolution)
    col += 0.10 * fcos(6.28318 * t * 17.1 + float3(0.2, 0.6, 0.7), resolution)
    col += 0.10 * fcos(6.28318 * t * 31.1 + float3(0.1, 0.6, 0.7), resolution)
    col += 0.10 * fcos(6.28318 * t * 65.1 + float3(0.0, 0.5, 0.8), resolution)
    col += 0.10 * fcos(6.28318 * t * 115.1 + float3(0.1, 0.4, 0.7), resolution)
    col += 0.10 * fcos(6.28318 * t * 265.1 + float3(1.1, 1.4, 2.7), resolution)
    col = clamp(col, 0.0, 1.0)

    return col


def calcColor(ro: float3, rd: float3, nor: float3, d: float, ln: float, idx: int, si: bool, td: float,
              resolution: float2) -> tuple[float4, float4]:
    colsi = float4(0.0)
    pos = ro + rd * d
    a = 1.0 - smoothstep(ln - 0.15 * 0.5, ln + 0.00001, length(pos))
    col = getColor(pos, resolution)
    colx = float4(col, a)
    if si:
        pos = ro + rd * td
        ta = 1.0 - smoothstep(ln - 0.15 * 0.5, ln + 0.00001, length(pos))
        col = getColor(pos, resolution)
        colsi = float4(col, ta)
    return colx, colsi


# xSI is self intersect data, fade to fix dFd on edges
def iBilinearPatch(ro: float3, rd: float3, ps: float4, ph: float4, sz: float) -> tuple[bool, float, float3, bool, float, float3, float, float]:
    va = float3(0.0, 0.0, ph.x + ph.w - ph.y - ph.z)
    vb = float3(0.0, ps.w - ps.y, ph.z - ph.x)
    vc = float3(ps.z - ps.x, 0.0, ph.y - ph.x)
    vd = float3(ps.xy, ph.x)

    tmp = 1.0 / (vb.y * vc.x)
    a = 0.0
    b = 0.0
    c = 0.0
    d = va.z * tmp
    e = 0.0
    f = 0.0
    g = (vc.z * vb.y - vd.y * va.z) * tmp
    h = (vb.z * vc.x - va.z * vd.x) * tmp
    i = -1.0
    j = (vd.x * vd.y * va.z + vd.z * vb.y * vc.x) * tmp - (vd.y * vb.z * vc.x + vd.x * vc.z * vb.y) * tmp

    p = dot(float3(a, b, c), rd.xzy * rd.xzy) + dot(float3(d, e, f), rd.xzy * rd.zyx)
    q = (dot(float3(2.0, 2.0, 2.0) * ro.xzy * rd.xyz, float3(a, b, c)) + dot(ro.xzz * rd.zxy, float3(d, d, e))
         + dot(ro.yyx * rd.zxy, float3(e, f, f)) + dot(float3(g, h, i), rd.xzy))
    r = dot(float3(a, b, c), ro.xzy * ro.xzy) + dot(float3(d, e, f), ro.xzy * ro.zyx) + dot(float3(g, h, i), ro.xzy) + j

    if abs(p) < 0.000001:
        tt = -r / q
        if tt <= 0.0:
            return NO_PATCH
        # normal
        pos = ro + tt * rd
        if length(pos) > sz:
            return NO_PATCH
        grad = float3(2.0) * pos.xzy * float3(a, b, c) + pos.zxz * float3(d, d, e) + pos.yyx * float3(f, e, f) + float3(g, h, i)
        return True, tt, -normalize(grad), False, -1.0, UP, 1.0, 1.0

    sq = q * q - 4.0 * p * r
    if sq < 0.0:
        return NO_PATCH

    s = sqrt(sq)
    t0 = (-q + s) / (2.0 * p)
    t1 = (-q - s) / (2.0 * p)
    tt1 = min(t1 if t0 < 0.0 else t0, t0 if t1 < 0.0 else t1)
    tt2 = max(t1 if t0 > 0.0 else t0, t0 if t1 > 0.0 else t1)
    tt0 = tt1
    if tt0 <= 0.0:
        return NO_PATCH
    pos = ro + tt0 * rd
    ru = step(sz, length(pos)) > 0.5
    if ru:
        tt0 = tt2
        pos = ro + tt0 * rd
    if tt0 <= 0.0:
        return NO_PATCH
    ru2 = step(sz, length(pos)) > 0.5
    if ru2:
        return NO_PATCH

    # self intersect
    si = False
    fadesi = 1.0
    tsi = -1.0
    normsi = UP
    if tt2 > 0.0 and not ru and not (step(sz, length(ro + tt2 * rd)) > 0.5):
        si = True
        fadesi = s
        tsi = tt2
        tpos = ro + tsi * rd
        # normal
        tgrad = (float3(2.0) * tpos.xzy * float3(a, b, c) + tpos.zxz * float3(d, d, e)
                 + tpos.yyx * float3(f, e, f) + float3(g, h, i))
        normsi = -normalize(tgrad)

    fade = s
    # normal
    grad = float3(2.0) * pos.xzy * float3(a, b, c) + pos.zxz * float3(d, d, e) + pos.yyx * float3(f, e, f) + float3(g, h, i)
    norm = -normalize(grad)

    return True, tt0, norm, si, tsi, normsi, fade, fadesi


def dot2(v: float3) -> float:
    return dot(v, v)


def segShadow(ro: float3, rd: float3, pa: float3, sh: float) -> float:
    dm = dot(rd.yz, rd.yz)
    k1 = (ro.x - pa.x) * dm
    k2 = (ro.x + pa.x) * dm
    k5 = (ro.yz + pa.yz) * dm
    k3 = dot(ro.yz + pa.yz, rd.yz)
    k4 = (pa.yz + pa.yz) * rd.yz
    k6 = (pa.yz + pa.yz) * dm

    for i in range(4):
        s = float2(i & 1, i >> 1)
        t = dot(s, k4) - k3

        if t > 0.0:
            sh = min(sh, dot2(float3(clamp(-rd.x * t, k1, k2), k5 - k6 * s) + rd * t) / (t * t))
    return sh


def boxSoftShadow(ro: float3, rd: float3, rad: float3, sk: float) -> float:
    rd += 0.0001 * (1.0 - abs(sign(rd)))
    rdd = rd
    roo = ro

    m = 1.0 / rdd
    n = m * roo
    k = abs(m) * rad

    t1 = -n - k
    t2 = -n + k

    tN = max(max(t1.x, t1.y), t1.z)
    tF = min(min(t2.x, t2.y), t2.z)

    if tN < tF and tF > 0.0:
        return 0.0

    sh = 1.0
    sh = segShadow(roo.xyz, rdd.xyz, rad.xyz, sh)
    sh = segShadow(roo.yzx, rdd.yzx, rad.yzx, sh)
    sh = segShadow(roo.zxy, rdd.zxy, rad.zxy, sh)
    sh = clamp(sk * sqrt(sh), 0.0, 1.0)
    return sh * sh * (3.0 - 2.0 * sh)


def box(ro: float3, rd: float3, r: float3, entering: bool) -> tuple[float, float3]:
    rd += 0.0001 * (1.0 - abs(sign(rd)))
    dr = 1.0 / rd
    n = ro * dr
    k = r * abs(dr)

    pin = -k - n
    pout = k - n
    tin = max(pin.x, max(pin.y, pin.z))
    tout = min(pout.x, min(pout.y, pout.z))
    if tin > tout:
        return -1.0, float3(0.0)
    if entering:
        nn = -sign(rd) * step(pin.zxy, pin.xyz) * step(pin.yzx, pin.xyz)
    else:
        nn = sign(rd) * step(pout.xyz, pout.zxy) * step(pout.xyz, pout.yzx)
    return (tin if entering else tout), nn


def bgcol(rd: float3) -> float3:
    return mix(float3(0.01), float3(0.336, 0.458, 0.668), 1.0 - pow(abs(rd.z + 0.25), 1.3))


def background(ro: float3, rd: float3, l_dir: float3) -> tuple[float3, float]:
    t = (-BOXDIMS.z - ro.z) / rd.z
    alpha = 0.0
    bgc = bgcol(rd)
    if t < 0.0:
        return bgc, alpha
    uv = ro.xy + t * rd.xy
    shad = boxSoftShadow(ro + t * rd, normalize(l_dir + float3(0.0, 0.0, 1.0)) * rotz(PI * 0.65), BOXDIMS, 1.5)
    aofac = smoothstep(-0.95, 0.75, length(abs(uv) - min(abs(uv), float2(0.45))))
    aofac = min(aofac, smoothstep(-0.65, 1.0, shad))
    lght = max(dot(normalize(ro + t * rd + float3(0.0, -0.0, -5.0)), normalize(l_dir - float3(0.0, 0.0, 1.0)) * rotz(PI * 0.65)), 0.0)
    col = mix(float3(0.4), float3(0.71, 0.772, 0.895), lght * lght * aofac + 0.05) * aofac
    alpha = 1.0 - smoothstep(7.0, 10.0, length(uv))
    return mix(col * length(col) * 0.8, bgc, smoothstep(7.0, 10.0, length(uv))), alpha


def insides(ro: float3, rd: float3, nor_c: float3, l_dir: float3, resolution: float2) -> tuple[float4, float]:
    tout = -1.0
    col = float3(0.0)

    pi = 3.1415926

    if abs(nor_c.x) > 0.5:
        rd = rd.xzy * nor_c.x
        ro = ro.xzy * nor_c.x
    elif abs(nor_c.z) > 0.5:
        l_dir *= roty(pi)
        rd = rd.yxz * nor_c.z
        ro = ro.yxz * nor_c.z
    elif abs(nor_c.y) > 0.5:
        l_dir *= rotz(-pi * 0.5)
        rd = rd * nor_c.y
        ro = ro * nor_c.y

    curvature = 0.5
    bil_size = 1.0
    ps = float4(-bil_size, -bil_size, bil_size, bil_size) * curvature
    ph = float4(-bil_size, bil_size, bil_size, -bil_size) * curvature

    colx = [float4(0.0)] * 3
    dx = [float3(-1.0)] * 3
    colxsi = [float4(0.0)] * 3
    order = [0, 1, 2]

    for i in range(3):
        if abs(nor_c.x) > 0.5:
            ro *= rotz(-pi * (1.0 / 3.0))
            rd *= rotz(-pi * (1.0 / 3.0))
        elif abs(nor_c.z) > 0.5:
            ro *= rotz(pi * (1.0 / 3.0))
            rd *= rotz(pi * (1.0 / 3.0))
        elif abs(nor_c.y) > 0.5:
            ro *= rotx(pi * (1.0 / 3.0))
            rd *= rotx(pi * (1.0 / 3.0))

        hit, tnew, normnew, si, tsi, normsi, fade, fadesi = iBilinearPatch(ro, rd, ps, ph, bil_size)
        if hit:
            if tnew > 0.0:
                tcol, tcolsi = calcColor(ro, rd, normnew, tnew, bil_size, i, si, tsi, resolution)
                if tcol.a > 0.0:
                    dx[i] = float3(tnew, float(si), tsi)

                    dif = clamp(dot(normnew, l_dir), 0.0, 1.0)
                    amb = clamp(0.5 + 0.5 * dot(normnew, l_dir), 0.0, 1.0)

                    shad = float3(0.32, 0.43, 0.54) * amb + float3(1.0, 0.9, 0.7) * dif
                    tcr = float3(1.0, 0.21, 0.11)
                    ta = clamp(length(tcol.rgb), 0.0, 1.0)
                    tcol = clamp(tcol * tcol * 2.0, 0.0, 1.0)
                    tvalx = float4(tcol.rgb * shad * 1.4 + 3.0 * (tcr * tcol.rgb) * clamp(1.0 - (amb + dif), 0.0, 1.0), min(tcol.a, ta))
                    tvalx.rgb = clamp(2.0 * tvalx.rgb * tvalx.rgb, 0.0, 1.0)
                    tvalx *= min(fade * 5.0, 1.0)
                    colx[i] = tvalx

                    if si:
                        dif = clamp(dot(normsi, l_dir), 0.0, 1.0)
                        amb = clamp(0.5 + 0.5 * dot(normsi, l_dir), 0.0, 1.0)
                        shad = float3(0.32, 0.43, 0.54) * amb + float3(1.0, 0.9, 0.7) * dif
                        ta = clamp(length(tcolsi.rgb), 0.0, 1.0)
                        tcolsi = clamp(tcolsi * tcolsi * 2.0, 0.0, 1.0)
                        tvalx = float4(tcolsi.rgb * shad + 3.0 * (tcr * tcolsi.rgb) * clamp(1.0 - (amb + dif), 0.0, 1.0), min(tcolsi.a, ta))
                        tvalx.rgb = clamp(2.0 * tvalx.rgb * tvalx.rgb, 0.0, 1.0)
                        tvalx.rgb *= min(fadesi * 5.0, 1.0)
                        colxsi[i] = tvalx

    # transparency logic and layers sorting
    a = 1.0
    if dx[0].x < dx[1].x:
        dx[0], dx[1] = dx[1], dx[0]
        order[0], order[1] = order[1], order[0]
    if dx[1].x < dx[2].x:
        dx[1], dx[2] = dx[2], dx[1]
        order[1], order[2] = order[2], order[1]
    if dx[0].x < dx[1].x:
        dx[0], dx[1] = dx[1], dx[0]
        order[0], order[1] = order[1], order[0]

    tout = max(max(dx[0].x, dx[1].x), dx[2].x)

    if dx[0].y < 0.5:
        a = colx[order[0]].a

    # self intersection
    rul = [
        dx[0].y > 0.5 and dx[1].x <= 0.0,
        dx[1].y > 0.5 and dx[0].x > dx[1].z,
        dx[2].y > 0.5 and dx[1].x > dx[2].z,
    ]
    for k in range(3):
        if rul[k]:
            tcolxsi = colxsi[order[k]]
            tcolx = colx[order[k]]

            tvalx = mix(tcolxsi, tcolx, tcolx.a)
            colx[order[k]] = tvalx

            tvalx2 = mix(float4(0.0), tvalx, max(tcolx.a, tcolxsi.a))
            colx[order[k]] = tvalx2

    a1 = colx[order[1]].a if dx[1].y < 0.5 else (colx[order[1]].a if dx[1].z > dx[0].x else 1.0)
    a2 = colx[order[2]].a if dx[2].y < 0.5 else (colx[order[2]].a if dx[2].z > dx[1].x else 1.0)
    col = mix(mix(colx[order[0]].rgb, colx[order[1]].rgb, a1), colx[order[2]].rgb, a2)
    a = max(max(a, a1), a2)
    return float4(col, a), tout


def main(frag_coord: float2, resolution: float2, time: float, mouse: float2) -> float4:
    l_dir = normalize(float3(0.0, 1.0, 0.0))
    l_dir *= rotz(0.5)
    mouseY = (1.0 - 1.15 * mouse.y / resolution.y) * 0.5 * PI
    if mouse.y < 1.0:
        mouseY = (PI * 0.49 - smoothstep(0.0, 8.5, mod((time + tshift) * 0.33, 25.0))
                  * (1.0 - smoothstep(14.0, 24.0, mod((time + tshift) * 0.33, 25.0))) * 0.55 * PI)
    mouseX = -2.0 * PI - 0.25 * (time * 0.8999 + tshift)
    mouseX += -(mouse.x / resolution.x) * 2.0 * PI

    eye = 4.0 * float3(cos(mouseX) * cos(mouseY), sin(mouseX) * cos(mouseY), sin(mouseY))
    w = normalize(-eye)
    up = float3(0.0, 0.0, 1.0)
    u = normalize(cross(w, up))
    v = cross(u, w)

    tot = float4(0.0)
    uv = (frag_coord - 0.5 * resolution) / resolution.x
    rd = normalize(w * FDIST + uv.x * u + uv.y * v)

    t, ni = box(eye, rd, BOXDIMS, True)
    ro = eye + t * rd
    coords = ro.xy * ni.z / BOXDIMS.xy + ro.yz * ni.x / BOXDIMS.yz + ro.zx * ni.y / BOXDIMS.zx
    fadeborders = (1.0 - smoothstep(0.915, 1.05, abs(coords.x))) * (1.0 - smoothstep(0.915, 1.05, abs(coords.y)))

    if t > 0.0:
        col = float3(0.0)
        R0 = (IOR - 1.0) / (IOR + 1.0)
        R0 *= R0

        theta = float2(0.0)
        n = float3(cos(theta.x) * sin(theta.y), sin(theta.x) * sin(theta.y), cos(theta.y))

        nr = n.zxy * ni.x + n.yzx * ni.y + n.xyz * ni.z
        rdr = reflect(rd, nr)
        reflcol, talpha = background(ro, rdr, l_dir)

        rd2 = refract(rd, nr, 1.0 / IOR)

        accum = 1.0
        no2 = ni
        ro_refr = ro

        colo = [float4(0.0)] * 2

        for j in range(2):
            coords2 = ro_refr.xy * no2.z + ro_refr.yz * no2.x + ro_refr.zx * no2.y
            eye2 = float3(coords2, -1.0)
            rd2trans = rd2.yzx * no2.x + rd2.zxy * no2.y + rd2.xyz * no2.z

            rd2trans.z = -rd2trans.z
            internalcol, tb = insides(eye2, rd2trans, no2, l_dir, resolution)
            if tb > 0.0:
                internalcol.rgb *= accum
                colo[j] = internalcol

            if tb <= 0.0 or internalcol.a < 1.0:
                tout, no2 = box(ro_refr, rd2, BOXDIMS, False)
                no2 = n.zyx * no2.x + n.xzy * no2.y + n.yxz * no2.z
                rout = ro_refr + tout * rd2
                rdout = refract(rd2, -no2, IOR)
                fresnel2 = R0 + (1.0 - R0) * pow(1.0 - dot(rdout, no2), 1.3)
                rd2 = reflect(rd2, -no2)

                ro_refr = rout
                ro_refr.z = max(ro_refr.z, -0.999)

                accum *= fresnel2
        fresnel = R0 + (1.0 - R0) * pow(1.0 - dot(-rd, nr), 5.0)
        col = mix(mix(colo[1].rgb * colo[1].a, colo[0].rgb, colo[0].a) * fadeborders, reflcol, pow(fresnel, 1.5))
        col = clamp(col, 0.0, 1.0)

        cineshader_alpha = clamp(0.15 * dot(eye, ro), 0.0, 1.0)
        tot += float4(col, cineshader_alpha)
    else:
        bg, alpha = background(eye, rd, l_dir)
        tot += float4(bg, 0.15)

    # NO_ALPHA: opaque for the gallery
    return float4(clamp(tot.rgb, 0.0, 1.0), 1.0)
