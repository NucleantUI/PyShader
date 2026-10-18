//
//  ShaderPack: lists the shaders the build compiled from pyshader.toml.
//
//  Nothing here compiles anything: each `.spv` was produced by the
//  PyShaderBuildPlugin while this target was built, and is read as words —
//  what a renderer hands to `vkCreateShaderModule`.
//

import Foundation

for name in ["tiles", "ripple", "glow"] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "spv"),
          let data = try? Data(contentsOf: url) else {
        print("\(name): missing from the bundle")
        exit(1)
    }
    let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    guard words.first == 0x0723_0203 else {
        print("\(name): not SPIR-V")
        exit(1)
    }
    print("\(name).spv: \(words.count) words, SPIR-V \(words[1] >> 16).\((words[1] >> 8) & 0xFF)")
}
