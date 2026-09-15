#!/bin/sh
# Compiles every Examples/*.py and validates the SPIR-V with spirv-val.
set -e
cd "$(dirname "$0")/.."
swift build --product pyshaderc >/dev/null 2>&1
bin=$(swift build --product pyshaderc --show-bin-path 2>/dev/null)
out=$(mktemp -d)
status=0
for f in Examples/*.py; do
    name=$(basename "$f" .py)
    if "$bin/pyshaderc" "$f" -o "$out/$name.spv" >/dev/null; then
        if spirv-val --target-env vulkan1.0 "$out/$name.spv"; then
            echo "ok    $f"
        else
            echo "INVALID $f"; status=1
        fi
    else
        echo "FAIL  $f"; status=1
    fi
done
for f in Examples/compute/*.py; do
    name=$(basename "$f" .py)
    if "$bin/pyshaderc" "$f" --target compute --content --arg gain:float --arg tint:float4 --arg mins:floatArray -o "$out/$name.spv" >/dev/null; then
        if spirv-val --target-env vulkan1.0 "$out/$name.spv"; then
            echo "ok    $f (compute)"
        else
            echo "INVALID $f"; status=1
        fi
    else
        echo "FAIL  $f"; status=1
    fi
done
exit $status
