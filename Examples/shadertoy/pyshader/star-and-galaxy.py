"""Star and galaxy

https://www.shadertoy.com/view/f3c3zX. Port of opengl/star-and-galaxy.glsl.
#defines become module constants, mat2 becomes float2x2, the float-stepped
for-loops become while-loops, and the output is made opaque.
"""
from pyshader import *

# --- STAR NEST SETTINGS ---
iterations = 7
formuparam = 0.53
volsteps = 26
stepsize = 0.1
zoom = 0.400
tile = 0.850
speed = 0.010
brightness = 0.0015
darkmatter = 0.300
distfading = 0.730
saturation = 0.850


# Simple pseudo-random noise function
def hash(n: float) -> float:
    return fract(sin(n) * 43758.5453123)


# 2D Noise for nebula texture generation
def noise2D(p: float2) -> float:
    i = floor(p)
    f = fract(p)
    u = f * f * (3.0 - 2.0 * f)

    a = hash(i.x + i.y * 57.0)
    b = hash(i.x + 1.0 + i.y * 57.0)
    c = hash(i.x + (i.y + 1.0) * 57.0)
    d = hash(i.x + 1.0 + (i.y + 1.0) * 57.0)

    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y


# FBM Noise to create fibrous gas structures
def fbm(p: float2) -> float:
    v = 0.0
    a = 0.5
    shift = float2(100.0)
    rot = float2x2(cos(0.5), sin(0.5), -sin(0.5), cos(0.50))
    for i in range(4):
        v += a * noise2D(p)
        p = rot * p * 2.0 + shift
        a *= 0.5
    return v


# Star Nest rendering function
def getStarNest(uv: float2, time: float) -> float3:
    dir = float3(uv * zoom, 1.0)
    frm = float3(1.0, 0.5, 0.5)

    s = 0.1
    fade = 1.0
    v = float3(0.0)

    for r in range(volsteps):
        p = frm + s * dir * 0.5
        p = abs(float3(tile) - mod(p, float3(tile * 2.0)))
        pa = 0.0
        a = 0.0

        for i in range(iterations):
            p = abs(p) / dot(p, p) - formuparam
            p.xy *= float2x2(cos(time * 0.03), sin(time * 0.03), -sin(time * 0.03), cos(time * 0.03))
            a += abs(length(p) - pa)
            pa = length(p)

        dm = max(0.0, darkmatter - a * a * 0.001)
        a *= a * a
        if r > 6:
            fade *= 1.2 - dm

        v += fade
        v += float3(s, s * s, s * s * s * s) * a * brightness * fade
        fade *= distfading
        s += stepsize

    v = mix(float3(length(v)), v, saturation)
    return v * 0.015


def main(frag_coord: float2, resolution: float2, time: float) -> float4:
    # 1. CLEAN screen coordinates
    UVO = (2.0 * frag_coord - resolution) / resolution.y

    # MASK FOR GREEN ZONE (active only at the top of the screen, fading towards the center)
    greenZoneMask = smoothstep(0.0, 0.5, UVO.y)

    # Generate Oy relief noise modulated by the green zone mask
    reliefNoise = fbm(float2(UVO.x * 2.0, UVO.y * 5.0 + time * 0.1))
    yRelief = sin(UVO.y * 8.0 + reliefNoise * 3.0) * 0.15 * greenZoneMask

    # 2. PERSPECTIVE distorted coordinates (relief smoothly affects only the top)
    UVN = UVO * 3.0

    UVN /= 1.0 - UVN.y * 0.4
    UVN /= 1.0 - UVN.x * 0.215

    cf = float4(0.0)
    T = time * 0.074

    # --- LAYER 1: MAIN GALAXY STARS ---
    IP = 3000.0
    while IP >= 0.0:
        r1 = hash(IP)
        r2 = hash(IP * 1.15 + 7.0)
        r3 = hash(IP * 2.5 + 13.0)
        r4 = hash(IP * 3.8 + 21.0)

        radius = pow(r1, 2.2) * 2.8

        arms = 2.0
        baseAngle = mod(IP, arms) * (3.14159265 / arms) * 2.0
        spiralAngle = baseAngle + radius * 3.2 - T

        armSpread = (r2 - 0.5) * mix(0.2, 0.7, radius * 0.4)
        angle = spiralAngle + armSpread

        CX = radius * cos(angle)
        CY = radius * sin(angle)

        CX += sin(T * 3.0 + IP) * 0.03 * r3
        CY += cos(T * 2.5 - IP) * 0.03 * r4
        PP = float2(CX, CY)

        lifeCycle = sin(T * (1.5 + r3 * 2.0) + IP * 0.5)
        sparkle = pow(max(0.0, sin(T * (3.0 + r1 * 5.0) + IP)), 6.0) * 4.0
        regularBlink = 0.3 + 0.7 * max(0.0, lifeCycle)
        totalBrightness = regularBlink + sparkle

        coreColor = float3(1.0, 0.8, 0.5)
        newbornColor = float3(0.4, 0.75, 1.0)
        CP = mix(coreColor, newbornColor, smoothstep(0.15, 0.8, radius))

        CP += float3(1.0) * sparkle * 0.3
        CP *= totalBrightness

        delta = UVN - PP
        dist = length(delta)

        glowRadius = mix(0.012, 0.003, smoothstep(0.0, 2.0, radius))
        RG = dist + glowRadius

        if sparkle > 0.5 and dist < 0.15:
            rays = (1.0 / (abs(delta.x) * 120.0 + 0.002)) + (1.0 / (abs(delta.y) * 120.0 + 0.002))
            RG = mix(RG, RG / (1.0 + rays * sparkle * 0.02), 0.5)

        cf.rgb += CP * (0.000135 / RG)
        IP -= 6.67

    # --- LAYER 2: NEBULA CALCULATION ---
    nebulaUV = UVN * 1.2
    angleT = T * 0.2
    rotT = float2x2(cos(angleT), sin(angleT), -sin(angleT), cos(angleT))
    nebulaUV = rotT * nebulaUV

    fbm1 = fbm(nebulaUV + float2(T * 0.05, 0.0))
    fbm2 = fbm(nebulaUV * 1.5 - fbm1 + float2(0.0, T * 0.03))

    # Foreground nebula (main gas stream)
    localNebulaDensity = fbm2 * smoothstep(4.0, 0.5, length(UVN))
    nebulaColor1 = float3(0.05, 0.1, 0.3)
    nebulaColor2 = float3(0.2, 0.05, 0.25)
    localNebula = mix(nebulaColor1, nebulaColor2, fbm1)
    coreGlow = 1.0 / (length(UVN) * 0.5 + 0.4)
    localNebula *= localNebulaDensity * (0.4 + coreGlow * 0.8)

    # Deep space background
    bgUV = UVO * 1.5
    rotBG = float2x2(cos(T * 0.05), sin(T * 0.05), -sin(T * 0.05), cos(T * 0.05))
    bgUV = rotBG * bgUV

    backgroundNoise = fbm(bgUV + float2(0.0, T * 0.01))
    spaceBackgroundColor = mix(float3(0.02, 0.01, 0.04), float3(0.01, 0.03, 0.06), backgroundNoise)
    deepNebula = spaceBackgroundColor * (0.4 + backgroundNoise * 1.4)

    # Add horizontal relief bands to the background gas (green zone only)
    deepNebula += float3(0.02, 0.01, 0.04) * (yRelief * 2.0 + 0.2 * greenZoneMask)

    cf.rgb += deepNebula + localNebula * 0.65

    # --- LAYER 3: STARS INSIDE THE DISTORTED STREAM ---
    SP = 100.0
    while SP < 500.0:
        h1 = hash(SP)
        h2 = hash(SP * 1.3 + 4.0)
        h3 = hash(SP * 1.7 + 12.0)

        seedRadius = h1 * 4.0
        seedAngle = h2 * 6.283 + T * (0.15 + h3 * 0.2)
        sparkPos = float2(seedRadius * cos(seedAngle), seedRadius * sin(seedAngle))

        # Apply relief modulation and perspective deformation to spark stars
        sparkPos.y += sin(sparkPos.y * 8.0 + fbm(sparkPos * 2.0) * 3.0) * 0.15 * smoothstep(0.0, 0.5, sparkPos.y)
        sparkPos /= 1.0 - sparkPos.y * 0.4
        sparkPos /= 1.0 - sparkPos.x * 0.115

        checkUV = rotT * sparkPos * 1.2
        gasDensityAtSpark = fbm(checkUV * 1.5 - fbm(checkUV + float2(T * 0.05, 0.0)) + float2(0.0, T * 0.03))

        spawnCondition = smoothstep(0.35, 0.65, gasDensityAtSpark)
        spawnCondition *= smoothstep(6.0, 2.0, length(sparkPos))

        if spawnCondition > 0.01:
            sparkBlink = 0.3 + 0.7 * sin(T * (5.0 + h1 * 5.0) + SP)
            sparkColor = mix(float3(0.4, 0.7, 1.0), float3(1.0), h2) * sparkBlink * spawnCondition
            sparkDist = distance(UVN, sparkPos)

            cf.rgb += sparkColor * (0.0003 / (sparkDist + 0.012))
        SP += 1.5

    # --- LAYER 4: STAR NEST CONFINED TO GREEN ZONE ---
    nestUV = UVO
    nestUV.y += yRelief * 0.3
    starNestBackground = getStarNest(nestUV, time)

    # Apply greenZoneMask to the Star Nest output
    cf.rgb += starNestBackground * 0.6 * greenZoneMask

    # Final color grading and contrast boost
    cf = pow(cf * 2.5, float4(1.1))
    # The original leaves alpha at 0 (ShaderToy ignores it); NucleantSwiftUI composites with it.
    return float4(cf.rgb, 1.0)
