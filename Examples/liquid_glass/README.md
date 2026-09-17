# Liquid glass

`lq.glsl` as a PyShader effect, and a home screen whose app icons are made
of it: each icon is a translucent colour slab with the glass over it, so
the wallpaper refracts through the colour and the glyph bends at the rim.
The toolbar is glass too.

The same math as a stand-alone, mouse-driven rounded-rect pad over the
stripes is in [`../shadertoy`](../shadertoy) (`opengl/liquid-glass.glsl`,
`pyshader/liquid-glass.py`), where the comparison app runs it next to the
GLSL — the two halves are identical.

```sh
cd Examples/liquid_glass/App && swift run
```

| file | what |
|---|---|
| `lq.glsl` | the original: ["Optically correct" liquid glass](https://www.shadertoy.com/view/wccSDf) |
| `liquid-glass.py` | its port as an effect: no background, no mouse pill; the view's rect (minus `inset`) is the pad |
| `liquid-glass-squircle.py` | a second recipe, from [OverShifted/LiquidGlass](https://github.com/OverShifted/LiquidGlass) (MIT); compiles, not in the demo |
| `App/` | the demo: icons drawn from shapes, each under its own glass |

## How an effect gets a backdrop

`.shader(_:)` gives a shader the view's own pixels, and glass needs what is
*under* the view. `backdrop: true` (new in NucleantSwiftUI with this
example) seeds the effect's texture with everything painted earlier under
the view's rect, so `layer(uv)` is backdrop plus view.

The shader's output is composited over the canvas, so a label drawn on top
of a glass pad would be covered; the demo puts the effect on the view
itself (`icon.liquidGlass()`, `Text(...).padding().liquidGlass()`), which
works because the pad is flat away from the rim — a sample there is the
pixel itself, so a glyph or label reads as drawn. Effects do not nest: a
glass icon inside a glass dock is not drawn, so there is no dock.

The rim pulls samples up to ~9 × thickness inward (the ray goes
`base_height = 8 × thickness` deep). A layer is only the view's rect, so on
a 64 pt icon with an 8 pt bevel the samples run past the far edge and clamp
to the edge texel — the rim goes flat. `Glassed` pads the content with a
transparent `margin` and passes it as the shader's `inset`, so the pad is
the icon and the texture reaches the wallpaper past it.

## Porting notes

- `dFdx`/`dFdy` of the SDF are fragment-only; the effect is a compute
  shader, so the normal uses forward differences of `sdf_rect` over one
  pixel instead — the same numbers.
- `n_cos` is clamped to 1: outside the pad the original takes `sqrt` of a
  negative and hides the NaN under its background mix. Here outside is
  alpha 0, and NaN × 0 is still NaN in the blend.
- `discard` (squircle) is fragment-only too; alpha 0 does the job and gets
  a pixel of anti-aliasing for free.
- ShaderArguments are pixels; `@Environment(\.displayScale)` turns points
  into them (`GlassStyle.arguments(scale:)` in the demo).
- The bevel is a lens: whatever is near the rim shows again, squeezed,
  in the rim. Icons take 8 pt on 64 pt (the original's proportion, 14 px
  on 128); text bars stay at 5 pt so the text is not in the lens.
  `Thicker` / `Thinner` change the icons' bevel.

## Other liquid glass shaders

Found while looking for what else the effect can be; none ported beyond
the two above.

ShaderToy (rounded-rect SDF + refraction, like `lq.glsl`):

- [Simple sdf shape refraction](https://www.shadertoy.com/view/wX3fDX) — `sdRoundedBox`, refraction through the SDF gradient.
- [Apple liquid glass replicate](https://www.shadertoy.com/view/3cdXDX) — refraction + lens highlight.
- [Liquid glass](https://www.shadertoy.com/view/3dBSRG), [Liquid Glass without blur](https://www.shadertoy.com/view/3clBRH), [Liquid glass ui](https://www.shadertoy.com/view/fXX3zr) — variations with and without a blur pass.

Elsewhere:

- [OverShifted/LiquidGlass](https://github.com/OverShifted/LiquidGlass) (OpenGL, MIT) — superellipse SDF, radial displacement, separable blur, grain, angular glow. Ported above.
- [naughtyduk/liquidGL](https://github.com/naughtyduk/liquidGL) (WebGL) — refraction with chromatic aberration and blur radius parameters.
- [DnV1eX/LiquidGlassKit](https://github.com/DnV1eX/LiquidGlassKit) (Metal) — backport of the system effect, refraction plus chromatic dispersion.
- [uginy/react-native-liquid-glass](https://github.com/uginy/react-native-liquid-glass) (AGSL) — refraction, chromatic aberration, iridescence.
- [dpawlikowski/liquid-glass](https://github.com/dpawlikowski/liquid-glass), [nikdelvin/liquid-glass](https://github.com/nikdelvin/liquid-glass) — CSS/SVG displacement-map versions; no shader, but the displacement maps show the same rim profile.
- [Building an infinite liquid glass grid with Three.js/TSL](https://tympanus.net/codrops/2026/09/08/building-an-infinite-liquid-glass-grid-with-three-js-webgpu-and-tsl/) — rounded corners, bevel and refraction all in the material.

What they add over the two ports, if wanted: chromatic aberration (sample
`layer` three times with slightly different refraction lengths per channel),
a blur pass over the backdrop before refracting, and a specular highlight
from a light direction rather than the fixed `reflect_vec.x - reflect_vec.y`.
