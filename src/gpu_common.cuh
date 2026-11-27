#ifndef GPU_COMMON_CUH
#define GPU_COMMON_CUH

#include <cuda_runtime.h>
#include <math.h>
#include <stdint.h>

#ifdef GPU_DOUBLE
typedef double GpuReal;
static constexpr GpuReal GPU_EPS = 1e-6;
static constexpr GpuReal GPU_T_EPS = 1e-6;
static constexpr GpuReal GPU_MOVE_EPS = 1e-4;
static constexpr GpuReal GPU_SSS_BACKSTEP = 2e-6;
static constexpr GpuReal GPU_INF = 1e300;
#else
typedef float GpuReal;
static constexpr GpuReal GPU_EPS = 1e-6f;
static constexpr GpuReal GPU_T_EPS = 1e-4f;
static constexpr GpuReal GPU_MOVE_EPS = 2e-4f;
static constexpr GpuReal GPU_SSS_BACKSTEP = 5e-4f;
static constexpr GpuReal GPU_INF = 1e30f;
#endif

static constexpr GpuReal GPU_PI = (GpuReal)3.14159265358979323846;

__host__ __device__ __forceinline__ GpuReal g_abs(GpuReal x) {
#ifdef GPU_DOUBLE
    return fabs(x);
#else
    return fabsf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_sqrt(GpuReal x) {
#ifdef GPU_DOUBLE
    return sqrt(x);
#else
    return sqrtf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_cbrt(GpuReal x) {
#ifdef GPU_DOUBLE
    return cbrt(x);
#else
    return cbrtf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_sin(GpuReal x) {
#ifdef GPU_DOUBLE
    return sin(x);
#else
    return sinf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_cos(GpuReal x) {
#ifdef GPU_DOUBLE
    return cos(x);
#else
    return cosf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_exp(GpuReal x) {
#ifdef GPU_DOUBLE
    return exp(x);
#else
    return expf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_log(GpuReal x) {
#ifdef GPU_DOUBLE
    return log(x);
#else
    return logf(x);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_pow(GpuReal x, GpuReal y) {
#ifdef GPU_DOUBLE
    return pow(x, y);
#else
    return powf(x, y);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_min(GpuReal a, GpuReal b) {
#ifdef GPU_DOUBLE
    return fmin(a, b);
#else
    return fminf(a, b);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_max(GpuReal a, GpuReal b) {
#ifdef GPU_DOUBLE
    return fmax(a, b);
#else
    return fmaxf(a, b);
#endif
}

__host__ __device__ __forceinline__ GpuReal g_lerp(GpuReal a, GpuReal b, GpuReal t) {
    return a + t * (b - a);
}

__host__ __device__ __forceinline__ GpuReal g_lerpInterval(GpuReal x1, GpuReal x2, GpuReal x,
                                                            GpuReal y1, GpuReal y2) {
    if (g_abs(x2 - x1) < GPU_EPS) return y1;
    return (y1 * (x2 - x) + y2 * (x - x1)) / (x2 - x1);
}

struct GpuVec2 {
    GpuReal x, y;
};

struct GpuVec3 {
    GpuReal x, y, z;
};

__host__ __device__ __forceinline__ GpuVec3 v3(GpuReal x, GpuReal y, GpuReal z) {
    return GpuVec3{x, y, z};
}

__host__ __device__ __forceinline__ GpuVec3 v3Add(GpuVec3 a, GpuVec3 b) {
    return GpuVec3{a.x + b.x, a.y + b.y, a.z + b.z};
}

__host__ __device__ __forceinline__ GpuVec3 v3Sub(GpuVec3 a, GpuVec3 b) {
    return GpuVec3{a.x - b.x, a.y - b.y, a.z - b.z};
}

__host__ __device__ __forceinline__ GpuVec3 v3Neg(GpuVec3 v) {
    return GpuVec3{-v.x, -v.y, -v.z};
}

__host__ __device__ __forceinline__ GpuVec3 v3Mul(GpuReal c, GpuVec3 v) {
    return GpuVec3{c * v.x, c * v.y, c * v.z};
}

__host__ __device__ __forceinline__ GpuReal v3Dot(GpuVec3 a, GpuVec3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

__host__ __device__ __forceinline__ GpuVec3 v3Cross(GpuVec3 a, GpuVec3 b) {
    return GpuVec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

__host__ __device__ __forceinline__ GpuReal v3Len(GpuVec3 v) {
    return g_sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

__host__ __device__ __forceinline__ GpuVec3 v3Unit(GpuVec3 v) {
    GpuReal len = v3Len(v);
    if (len < GPU_EPS) return GpuVec3{0, 0, 0};
    GpuReal inv = (GpuReal)1.0 / len;
    return GpuVec3{v.x * inv, v.y * inv, v.z * inv};
}

__device__ __forceinline__ GpuVec3 g_toWorld(GpuVec3 local, GpuVec3 N) {
    GpuVec3 helper = (g_abs(N.x) > (GpuReal)0.9) ? GpuVec3{0, 1, 0} : GpuVec3{1, 0, 0};
    GpuVec3 T = v3Unit(v3Cross(helper, N));
    GpuVec3 B = v3Cross(N, T);
    return GpuVec3{local.x * T.x + local.y * B.x + local.z * N.x,
                   local.x * T.y + local.y * B.y + local.z * N.y,
                   local.x * T.z + local.y * B.z + local.z * N.z};
}

struct GpuComplex {
    GpuReal R, I;
};

__device__ __forceinline__ GpuComplex gcSub(GpuComplex a, GpuComplex b) {
    return GpuComplex{a.R - b.R, a.I - b.I};
}

__device__ __forceinline__ GpuComplex gcAdd(GpuComplex a, GpuComplex b) {
    return GpuComplex{a.R + b.R, a.I + b.I};
}

__device__ __forceinline__ GpuComplex gcDiv(GpuComplex a, GpuComplex b) {
    GpuReal deno = b.R * b.R + b.I * b.I;
    return GpuComplex{(a.R * b.R + a.I * b.I) / deno, (a.I * b.R - a.R * b.I) / deno};
}

__device__ __forceinline__ GpuReal gcMod2(GpuComplex z) {
    return z.R * z.R + z.I * z.I;
}

struct GpuRay {
    GpuVec3 start;
    GpuVec3 direction;
    GpuReal wavelength;
};

struct GpuColorXYZ {
    GpuReal X, Y, Z;
};

struct Pcg32 {
    uint64_t state;
    uint64_t inc;

    __device__ __forceinline__ void seed(uint32_t userSeed, uint64_t pixelIdx,
                                         uint64_t sampleIdx) {
        uint64_t s =
            ((uint64_t)userSeed << 32) ^ (pixelIdx * 0x9E3779B97F4A7C15ULL + sampleIdx);
        s += 0x9E3779B97F4A7C15ULL;
        s = (s ^ (s >> 30)) * 0xBF58476D1CE4E5B9ULL;
        s = (s ^ (s >> 27)) * 0x94D049BB133111EBULL;
        s = s ^ (s >> 31);

        uint64_t seq = (pixelIdx << 16) ^ sampleIdx ^
                       ((uint64_t)userSeed * 0x517CC1B727220A95ULL);
        inc = (seq << 1u) | 1u;
        state = 0ULL;
        nextU32();
        state += s;
        nextU32();
    }

    __device__ __forceinline__ uint32_t nextU32() {
        uint64_t oldstate = state;
        state = oldstate * 6364136223846793005ULL + inc;
        uint32_t xorshifted = (uint32_t)(((oldstate >> 18u) ^ oldstate) >> 27u);
        uint32_t rot = (uint32_t)(oldstate >> 59u);
        return (xorshifted >> rot) | (xorshifted << ((0u - rot) & 31u));
    }

    __device__ __forceinline__ GpuReal nextReal() {
#ifdef GPU_DOUBLE
        uint64_t r = ((uint64_t)(nextU32() >> 5) << 26) | (uint64_t)(nextU32() >> 6);
        return (GpuReal)r * (1.0 / 9007199254740992.0);
#else
        return (GpuReal)(nextU32() >> 8) * (1.0f / 16777216.0f);
#endif
    }

    __device__ __forceinline__ uint32_t nextInt(uint32_t n) {
        uint64_t m = (uint64_t)nextU32() * (uint64_t)n;
        uint32_t l = (uint32_t)m;
        if (l < n) {
            uint32_t t = (0u - n) % n;
            while (l < t) {
                m = (uint64_t)nextU32() * (uint64_t)n;
                l = (uint32_t)m;
            }
        }
        return (uint32_t)(m >> 32);
    }
};

#endif
