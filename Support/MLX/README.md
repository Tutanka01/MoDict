# MLX Metal kernel library

`default.metallib` is MLX's precompiled Metal kernel library, vendored so the
released app can run MLX on any build machine.

## Why it is here

SwiftPM cannot compile Metal shaders, so a source build of `mlx-swift` (what CI
does) produces a binary with MLX's C++ Metal backend but **no** `default.metallib`.
MLX's `Device()` constructor loads that library eagerly
(`mlx/backend/metal/device.cpp`, `load_default_library`) and throws
`Failed to load the default metallib` on the first kernel without it. `make
bundle` copies the file to `Contents/MacOS/Resources/default.metallib`, one of
the paths MLX probes (a metallib directly in `Contents/MacOS` is treated as
nested code by `codesign --deep` and breaks verification).

## Provenance

- Package: mlx-swift **0.31.6** (MLX 0.31.1), pinned in `Package.swift`.
- Release asset: <https://github.com/ml-explore/mlx-swift/releases/download/0.31.6/Cmlx.xcframework.zip>
  (sha256 `a202bf1dcfe1e64404adabfeb5eb363332e3a6221d18e4289ca0663fa3ab86c9`).
- Path inside the archive: `macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib`.
- sha256 of this file: `4cb8ef6cbb43e43f4c07d466fe0944801987a45b1354324cf4810ec131278bf5`.

## Refreshing

When the mlx-swift/speech-swift pin in `Package.swift` changes, download the
matching `Cmlx.xcframework.zip` from that release, extract this file, verify it
still loads (`make verify-bundle` runs a real MLX kernel and a matmul), and
update the hashes above.

MLX is MIT-licensed, © 2023 Apple Inc. This file is a build artifact of the
MLX sources that the app already links; it redistributes under the same terms.
