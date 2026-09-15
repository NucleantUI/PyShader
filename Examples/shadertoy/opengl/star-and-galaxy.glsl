// https://www.shadertoy.com/view/f3c3zX

// --- STAR NEST SETTINGS ---
#define iterations 7
#define formuparam 0.53
#define volsteps 26       
#define stepsize 0.1
#define zoom   0.400       
#define tile   0.850
#define speed  0.010 
#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850

// Simple pseudo-random noise function
float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

// 2D Noise for nebula texture generation
float noise2D(in vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    
    float a = hash(i.x + i.y * 57.0);
    float b = hash(i.x + 1.0 + i.y * 57.0);
    float c = hash(i.x + (i.y + 1.0) * 57.0);
    float d = hash(i.x + 1.0 + (i.y + 1.0) * 57.0);
    
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// FBM Noise to create fibrous gas structures
float fbm(in vec2 p) {
    float v = 0.0;
    float a = 0.5;
    vec2 shift = vec2(100.0);
    mat2 rot = mat2(cos(0.5), sin(0.5), -sin(0.5), cos(0.50));
    for (int i = 0; i < 4; ++i) {
        v += a * noise2D(p);
        p = rot * p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

// Star Nest rendering function
vec3 getStarNest(vec2 uv, float time) {
    vec3 dir = vec3(uv * zoom, 1.0);
    vec3 from = vec3(1.0, 0.5, 0.5);
    
    float s = 0.1, fade = 1.0;
    vec3 v = vec3(0.0);
    
    for (int r = 0; r < volsteps; r++) {
        vec3 p = from + s * dir * 0.5;
        p = abs(vec3(tile) - mod(p, vec3(tile * 2.0))); 
        float pa, a = pa = 0.0;
        
        for (int i = 0; i < iterations; i++) { 
            p = abs(p) / dot(p, p) - formuparam;
            p.xy *= mat2(cos(iTime * 0.03), sin(iTime * 0.03), -sin(iTime * 0.03), cos(iTime * 0.03));
            a += abs(length(p) - pa);
            pa = length(p);
        }
        
        float dm = max(0.0, darkmatter - a * a * 0.001);
        a *= a * a; 
        if (r > 6) fade *= 1.2 - dm;
        
        v += fade;
        v += vec3(s, s * s, s * s * s * s) * a * brightness * fade;
        fade *= distfading;
        s += stepsize;
    }
    
    v = mix(vec3(length(v)), v, saturation);
    return v * 0.015; 
}

void mainImage(out vec4 cf, vec2 CF) {
    // 1. CLEAN screen coordinates
    vec2 UVO = (2.0 * CF - iResolution.xy) / iResolution.y;
    
    // MASK FOR GREEN ZONE (active only at the top of the screen, fading towards the center)
    float greenZoneMask = smoothstep(0.0, 0.5, UVO.y);
    
    // Generate Oy relief noise modulated by the green zone mask
    float reliefNoise = fbm(vec2(UVO.x * 2.0, UVO.y * 5.0 + iTime * 0.1));
    float yRelief = sin(UVO.y * 8.0 + reliefNoise * 3.0) * 0.15 * greenZoneMask;
    
    // 2. PERSPECTIVE distorted coordinates (relief smoothly affects only the top)
    vec2 UVN = UVO * 3.0;
  
    UVN /= 1.0 - UVN.y * 0.4;
    UVN /= 1.0 - UVN.x * 0.215;
    
    cf = vec4(0.0);
    float T = iTime * 0.074; 
    
    // --- LAYER 1: MAIN GALAXY STARS ---
    for (float IP = 3000.0; IP >= 0.0; IP -= 6.67) {
        float r1 = hash(IP); 
        float r2 = hash(IP * 1.15 + 7.0);
        float r3 = hash(IP * 2.5 + 13.0);
        float r4 = hash(IP * 3.8 + 21.0);

        float radius = pow(r1, 2.2) * 2.8; 
        
        float arms = 2.0;
        float baseAngle = mod(IP, arms) * (3.14159265 / arms) * 2.0;
        float spiralAngle = baseAngle + radius * 3.2 - T;
        
        float armSpread = (r2 - 0.5) * mix(0.2, 0.7, radius * 0.4); 
        float angle = spiralAngle + armSpread;
        
        float CX = radius * cos(angle);
        float CY = radius * sin(angle);
        
        CX += sin(T * 3.0 + IP) * 0.03 * r3;
        CY += cos(T * 2.5 - IP) * 0.03 * r4;
        vec2 PP = vec2(CX, CY);

        float lifeCycle = sin(T * (1.5 + r3 * 2.0) + IP * 0.5);
        float sparkle = pow(max(0.0, sin(T * (3.0 + r1 * 5.0) + IP)), 6.0) * 4.0;
        float regularBlink = 0.3 + 0.7 * max(0.0, lifeCycle);
        float totalBrightness = regularBlink + sparkle;

        vec3 coreColor = vec3(1.0, 0.8, 0.5);
        vec3 newbornColor = vec3(0.4, 0.75, 1.0); 
        vec3 CP = mix(coreColor, newbornColor, smoothstep(0.15, 0.8, radius));
        
        CP += vec3(1.0) * sparkle * 0.3;
        CP *= totalBrightness;
        
        vec2 delta = UVN - PP;
        float dist = length(delta);
        
        float glowRadius = mix(0.012, 0.003, smoothstep(0.0, 2.0, radius));
        float RG = dist + glowRadius;
        
        if (sparkle > 0.5 && dist < 0.15) {
            float rays = (1.0 / (abs(delta.x) * 120.0 + 0.002)) + (1.0 / (abs(delta.y) * 120.0 + 0.002));
            RG = mix(RG, RG / (1.0 + rays * sparkle * 0.02), 0.5);
        }

        cf.rgb += CP * (0.000135 / RG);
    }

    // --- LAYER 2: NEBULA CALCULATION ---
    vec2 nebulaUV = UVN * 1.2;
    float angleT = T * 0.2;
    mat2 rotT = mat2(cos(angleT), sin(angleT), -sin(angleT), cos(angleT));
    nebulaUV = rotT * nebulaUV;

    float fbm1 = fbm(nebulaUV + vec2(T * 0.05, 0.0));
    float fbm2 = fbm(nebulaUV * 1.5 - fbm1 + vec2(0.0, T * 0.03));
    
    // Foreground nebula (main gas stream)
    float localNebulaDensity = fbm2 * smoothstep(4.0, 0.5, length(UVN));
    vec3 nebulaColor1 = vec3(0.05, 0.1, 0.3); 
    vec3 nebulaColor2 = vec3(0.2, 0.05, 0.25); 
    vec3 localNebula = mix(nebulaColor1, nebulaColor2, fbm1);
    float coreGlow = 1.0 / (length(UVN) * 0.5 + 0.4);
    localNebula *= localNebulaDensity * (0.4 + coreGlow * 0.8);

    // Deep space background
    vec2 bgUV = UVO * 1.5;
    mat2 rotBG = mat2(cos(T * 0.05), sin(T * 0.05), -sin(T * 0.05), cos(T * 0.05));
    bgUV = rotBG * bgUV;
    
    float backgroundNoise = fbm(bgUV + vec2(0.0, T * 0.01));
    vec3 spaceBackgroundColor = mix(vec3(0.02, 0.01, 0.04), vec3(0.01, 0.03, 0.06), backgroundNoise);
    vec3 deepNebula = spaceBackgroundColor * (0.4 + backgroundNoise * 1.4);

    // Add horizontal relief bands to the background gas (green zone only)
    deepNebula += vec3(0.02, 0.01, 0.04) * (yRelief * 2.0 + 0.2 * greenZoneMask);

    cf.rgb += deepNebula + localNebula * 0.65;

    // --- LAYER 3: STARS INSIDE THE DISTORTED STREAM ---
    for (float SP = 100.0; SP < 500.0; SP += 1.5) {
        float h1 = hash(SP);
        float h2 = hash(SP * 1.3 + 4.0);
        float h3 = hash(SP * 1.7 + 12.0);

        float seedRadius = h1 * 4.0;
        float seedAngle = h2 * 6.283 + T * (0.15 + h3 * 0.2);
        vec2 sparkPos = vec2(seedRadius * cos(seedAngle), seedRadius * sin(seedAngle));
        
        // Apply relief modulation and perspective deformation to spark stars
        sparkPos.y += sin(sparkPos.y * 8.0 + fbm(sparkPos*2.0) * 3.0) * 0.15 * smoothstep(0.0, 0.5, sparkPos.y);
        sparkPos /= 1.0 - sparkPos.y * 0.4;
        sparkPos /= 1.0 - sparkPos.x * 0.115;
        
        vec2 checkUV = rotT * sparkPos * 1.2;
        float gasDensityAtSpark = fbm(checkUV * 1.5 - fbm(checkUV + vec2(T * 0.05, 0.0)) + vec2(0.0, T * 0.03));
        
        float spawnCondition = smoothstep(0.35, 0.65, gasDensityAtSpark);
        spawnCondition *= smoothstep(6.0, 2.0, length(sparkPos));

        if (spawnCondition > 0.01) {
            float sparkBlink = 0.3 + 0.7 * sin(T * (5.0 + h1 * 5.0) + SP);
            vec3 sparkColor = mix(vec3(0.4, 0.7, 1.0), vec3(1.0), h2) * sparkBlink * spawnCondition;
            float sparkDist = distance(UVN, sparkPos);
            
            cf.rgb += sparkColor * (0.0003 / (sparkDist + 0.012));
        }
    }

    // --- LAYER 4: STAR NEST CONFINED TO GREEN ZONE ---
    vec2 nestUV = UVO;
    nestUV.y += yRelief * 0.3; 
    vec3 starNestBackground = getStarNest(nestUV, iTime);
    
    // Apply greenZoneMask to the Star Nest output
    cf.rgb += starNestBackground * 0.6 * greenZoneMask;

    // Final color grading and contrast boost
    cf = pow(cf * 2.5, vec4(1.1));
}

