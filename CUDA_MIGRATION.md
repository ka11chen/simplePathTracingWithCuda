# CUDA GPU Migration Summary

This document summarizes the migration of the path tracer under `src/` to CUDA for NVIDIA H100 (`sm_90`), keeping `example.c` and the public C API in [include/pathTracing.h](include/pathTracing.h) unchanged.

---

## 1. Architecture Overview

The host C code continues to construct scenes (`Camera`, `Shape`, `Texture`, `Interface`, `Object`, `LightSource`) and load `.obj` / `.csv` assets. When rendering starts, the scene is serialized once into flat GPU arrays with a custom two-level BVH, rendered on the GPU via sample-parallel CUDA kernels, and copied back into `VirtualScreen`.

```text
example.c (unchanged C)
  └─> src/pathTracing.c  (renderBenchmark / renderToWindow / renderToPictures)
        └─> src/multithreads.c
              └─> src/gpu_render.cu  (CUDA kernels + session management)
                    └─> src/gpu_scene.cu  (scene inspection, LUTs, 2-level BVH)
```

---

## 2. New Files

| File | Purpose |
|---|---|
| `src/gpu_common.cuh` | `GpuReal` precision switch (`float` default, `double` with `-DGPU_DOUBLE`), vector/complex/ray math, FP32/FP64 epsilons (`GPU_EPS`, `GPU_T_EPS`, `GPU_MOVE_EPS`, `GPU_SSS_BACKSTEP`), and stateless per-sample `Pcg32` RNG seeded by `(seed, pixelIdx, sampleIdx)`. |
| `src/gpu_scene.cuh` | POD GPU scene structs (`GpuPrim`, `GpuBvhNode`, `GpuObject`, `GpuTexture`, `GpuInterface`, `GpuLightSource`, `GpuCamera`, `GpuSceneView`, `GpuScene`). |
| `src/gpu_scene.cu` | Scene uploader (`gpuUploadScene`, `gpuFreeScene`): flattens shapes (including nested `Group`s), builds per-object BLAS and scene TLAS using binned SAH (12 bins, max depth 28), deduplicates textures/interfaces, uploads static spectral/dispersion CSV tables, and samples custom host spectral callbacks on `[390, 790]` nm (`801` points, `0.5` nm step) into device LUTs. |
| `src/gpu_render.h` | C-linkage interface (`gpuInitDevice`, `gpuRunFixedWorkload`, `gpuCreateSession`, `gpuRenderProgressiveBatch`, `gpuDestroySession`). |
| `src/gpu_render.cu` | CUDA path tracing implementation (`renderSamplesKernel`, `resolvePixelsKernel`) stored against `__constant__ GpuSceneView g_scene`, implementing BVH traversal, GGX BRDF/BTDF, specular reflection/refraction, diffuse cosine sampling, NEE + MIS, random-walk subsurface scattering (`sampleSSS`), Beer's law attenuation, and Russian roulette. |
| `src/scene_internal.h` | Internal C inspection API allowing `gpu_scene.cu` to read opaque host structs (`Camera`, `Shape`, `Texture`, `Interface`, `Object`, `LightSource`, `VirtualScreen`) without exposing private definitions publicly. |

---

## 3. Modified Files

| File | Changes |
|---|---|
| `makeMakefile.sh` | Auto-detects `CC` (`clang` or `gcc`), adds `NVCC` (`nvcc`), `CUDA_ARCH` (default `sm_90`), and `GPU_DOUBLE` (`0` default, `1` adds `-DGPU_DOUBLE`). Compiles `.c` with `$CC` (without `-flto`), compiles `src/*.cu` with `$NVCC -std=c++17`, and links with `$NVCC` (forwarding `-Wl,*` and `-pthread` SDL flags cleanly). |
| `include/pathTracing.h`, `src/camera.h`, `src/frame.h`, `src/lightSource.h`, `src/multithreads.h`, `src/object.h`, `src/random.h`, `src/render.h`, `src/shapes.h`, `src/textures.h`, `src/transform.h` | Added `#ifdef __cplusplus extern "C" { ... }` guards so `.cu` (C++17) and `.c` sources link cleanly. |
| `src/base.h` | Added `PT_MAKE(T, ...)` macro for C99 compound literals / C++17 aggregate initialization; fixed `length2Of` (`v.y * v.y`); guarded `rcbrt` with `#ifndef __CUDACC__` to avoid colliding with CUDA's built-in `crt/math_functions.h` `rcbrt(double)`. |
| `src/camera.c`, `src/object.c`, `src/shapes.c`, `src/textures.c`, `src/lightSource.c` | Added `ptGet*` and `ptEval*` inspection helpers declared in `src/scene_internal.h`. |
| `src/render.c` | Added `ptGetScreen*Buffer` accessors for `VirtualScreen`; zero-initialized `preRay`, `preN1`, `preN2`, `preL`, `preV`, `preN` in `tracePath` to resolve GCC `-Wmaybe-uninitialized` warnings. |
| `src/multithreads.c` | Replaced CPU thread-pool rendering with `gpuRunFixedWorkload` (for `--bench`) and a single host driver thread calling `gpuRenderProgressiveBatch` (for `renderToWindow` and `renderToPictures`). |
| `src/pathTracing.c` | Added `gpuInitDevice()` in `renderToWindow`, `renderToPictures`, and before timing in `renderBenchmark`. |

---

## 4. Key GPU Design Choices & Bug Fixes

- **Sample-level parallelism with pixel tiling**: `renderSamplesKernel` launches `(8, 4, 4)` blocks (`8x4` pixel tiles × 4 samples per block) in batches up to `128` spp per kernel launch, balancing path-length divergence across SMs while preserving warp coherence on primary rays.
- **Double-precision accumulation**: Per-sample XYZ contributions accumulate in `double` via hardware `atomicAdd` (`sm_90`), then `resolvePixelsKernel` computes pixel means and tone-mapped 8-bit sRGB values.
- **Custom callback support without modifying `example.c`**: Host spectral function pointers (e.g., `coldLightBase` in `example.c` or custom `refractiveIndex` / `baseColor` / `sigmaS` callbacks in future testcases) are sampled on `[390, 790]` nm on the host and interpolated on the GPU.
- **CUDA stack & address-space fixes**:
  - Guarded `rcbrt` in `src/base.h` with `#ifndef __CUDACC__` to resolve the redefinition error with CUDA `crt/math_functions.h`.
  - Replaced the device lambda in `safeInvDir` with a `__device__ __forceinline__` function (`safeInv1`).
  - Reduced BVH traversal stacks to `int stack[32]` (max BVH depth `28`), raised `cudaLimitStackSize` to `8192`, and placed `GpuSceneView` in `static __constant__ GpuSceneView g_scene` accessed directly (never passed by generic reference/pointer across device calls).

---

## 5. Building & Running on the H100 Machine

```bash
ml cuda/12.6   # ensure nvcc is on PATH
CC=gcc ./makeMakefile.sh example.c > Makefile
make clean && make all

# 64 spp benchmark + XYZ output for relMAE validation
./bin/pathTracing --bench --spp 64 --seed 42 --out out.txt --out-xyz out.xyz
```

Optional build variables:
- `CUDA_ARCH=sm_90` (default; override if targeting a different GPU architecture)
- `GPU_DOUBLE=1` (switches internal GPU math from `float` to `double`)
