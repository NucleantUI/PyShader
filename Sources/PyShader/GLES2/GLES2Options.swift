//
//  GLES2Options.swift
//  PyShader
//
//  What the OpenGL ES 2 stages call what the app hands them, and how the
//  vertex stage a fragment or compute target gets places its quad. Every
//  name is an option, so the stages fit whatever program the app links them
//  into; the defaults are plain names, no matrices, the color from an
//  attribute.
//

/// The names OpenGL ES 2 output uses for its attributes, varyings and the
/// content sampler, and how the generated vertex stage transforms and colors
/// its vertices.
///
/// A fragment or compute target gets a vertex stage written from them:
///
/// ```glsl
/// attribute vec2 a_position;              // positionAttribute
/// attribute vec2 a_texcoord;              // texcoordAttribute, when the fragment stage reads uv
/// attribute vec4 a_color;                 // colorAttribute, when it reads color and colorUniform is nil
/// varying vec2 v_uv;                      // uvVarying
/// varying vec4 v_color;                   // colorVarying
/// void main(void) {
///     v_color = a_color;                  // colorUniform instead, times opacityUniform as alpha
///     v_uv = a_texcoord;                  // vec2(a_texcoord.x, 1.0 - a_texcoord.y) with uvIsTopDown
///     gl_Position = vec4(a_position.xy, 0.0, 1.0);   // positionMatrices first, left to right
/// }
/// ```
///
/// A graphics target's `vertex` takes the attributes as parameters instead:
/// `position: float2`, `texcoord: float2` and `color: float4` read
/// `positionAttribute`, `texcoordAttribute` and `colorAttribute`, and the
/// position it returns goes through `positionMatrices` too.
public struct GLES2Options: Sendable, Hashable {
    /// The `vec2` position each vertex comes with.
    public var positionAttribute: String
    /// The `vec2` texture coordinate each vertex comes with, passed on as `uvVarying`.
    public var texcoordAttribute: String
    /// The texture coordinates run top-down, so the generated vertex stage
    /// passes on `(x, 1 - y)` and `uv` (and `frag_coord`, `pixel` from it) is
    /// y-up. A graphics target's `texcoord` is the attribute as it is.
    public var uvIsTopDown: Bool
    /// The `vec4` color each vertex comes with, passed on as `colorVarying`;
    /// not used when `colorUniform` is set.
    public var colorAttribute: String
    /// A `vec4` uniform the color is instead.
    public var colorUniform: String?
    /// A `float` uniform the color's alpha is multiplied by.
    public var opacityUniform: String?
    /// `mat4` uniforms the position is multiplied by, left to right:
    /// `["p", "m"]` is `gl_Position = p * m * vec4(position.xy, 0.0, 1.0)`.
    /// None: the position is already in clip space.
    public var positionMatrices: [String]
    /// The `vec2` varying the fragment stage reads `uv` from.
    public var uvVarying: String
    /// The `vec4` varying the fragment stage reads `color` from (fragment target).
    public var colorVarying: String
    /// The `sampler2D` uniform `layer()` samples.
    public var contentSampler: String

    public init(
        positionAttribute: String = "a_position",
        texcoordAttribute: String = "a_texcoord",
        uvIsTopDown: Bool = false,
        colorAttribute: String = "a_color",
        colorUniform: String? = nil,
        opacityUniform: String? = nil,
        positionMatrices: [String] = [],
        uvVarying: String = "v_uv",
        colorVarying: String = "v_color",
        contentSampler: String = "u_content"
    ) {
        self.positionAttribute = positionAttribute
        self.texcoordAttribute = texcoordAttribute
        self.uvIsTopDown = uvIsTopDown
        self.colorAttribute = colorAttribute
        self.colorUniform = colorUniform
        self.opacityUniform = opacityUniform
        self.positionMatrices = positionMatrices
        self.uvVarying = uvVarying
        self.colorVarying = colorVarying
        self.contentSampler = contentSampler
    }

    /// Every name the options give, by the option's name.
    var names: [(option: String, name: String)] {
        var all = [
            ("positionAttribute", positionAttribute), ("texcoordAttribute", texcoordAttribute),
            ("colorAttribute", colorAttribute), ("uvVarying", uvVarying),
            ("colorVarying", colorVarying), ("contentSampler", contentSampler),
        ]
        if let colorUniform { all.append(("colorUniform", colorUniform)) }
        if let opacityUniform { all.append(("opacityUniform", opacityUniform)) }
        for matrix in positionMatrices { all.append(("positionMatrices", matrix)) }
        return all
    }

    /// Each name is a GLSL identifier GLSL does not keep for itself, and no
    /// two options share one.
    func validate() throws {
        var seen: [String: String] = [:]
        for (option, name) in names {
            let isIdentifier = name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
                && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
            guard isIdentifier, GLES2Names.usable(name) else {
                throw PyShaderError("`\(option)` `\(name)` is not a name a GLSL ES 1.00 shader can declare")
            }
            if let other = seen[name] {
                throw PyShaderError("`\(option)` and `\(other)` are both `\(name)`")
            }
            seen[name] = option
        }
    }
}
