#include "gpu_render.h"
#include "gpu_scene.cuh"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CUDA_CHECK(call)                                                                           \
    do {                                                                                           \
        cudaError_t err__ = (call);                                                                \
        if (err__ != cudaSuccess) {                                                                \
            fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__,                       \
                    cudaGetErrorString(err__));                                                    \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

static __constant__ GpuSceneView g_scene;

struct GpuHit {
    bool collide;
    GpuReal distance;
    GpuVec3 normal;
    int objIdx;
};

struct GpuLightHit {
    bool collide;
    GpuReal distance;
    GpuVec3 normal;
    int lightIdx;
};

struct GpuNextSim {
    GpuReal scalingFactor;
    GpuRay nxtRay;
    GpuComplex n1, n2;
    GpuVec3 l, v, N;
    GpuVec3 collidePoint;
    bool isSpecularBounce;
};

__device__ __forceinline__ GpuNextSim nextSimFail() { return GpuNextSim{}; }

__device__ __forceinline__ GpuNextSim nextSimStep(GpuReal scale, const GpuRay &ray) {
    GpuNextSim r{};
    r.scalingFactor = scale;
    r.nxtRay = ray;
    return r;
}

static constexpr uint32_t TEX_METALLIC = 0x1U;
static constexpr uint32_t TEX_FULLY_TRANSPARENT = 0x2U;
static constexpr uint32_t TEX_HALF_TRANSPARENT = 0x6U;

__device__ __forceinline__ bool texIsMetallic(const GpuTexture &t) {
    return (t.tags & TEX_METALLIC) != 0;
}

__device__ __forceinline__ bool texIsTransparent(const GpuTexture &t) {
    return (t.tags & TEX_FULLY_TRANSPARENT) != 0;
}

__device__ __forceinline__ bool texIsFullyTransparent(const GpuTexture &t) {
    return (t.tags & TEX_HALF_TRANSPARENT) == TEX_FULLY_TRANSPARENT;
}

__device__ __forceinline__ bool texIsHalfTransparent(const GpuTexture &t) {
    return (t.tags & TEX_HALF_TRANSPARENT) == TEX_HALF_TRANSPARENT;
}

__device__ __forceinline__ GpuReal evalCustomRealLut(const GpuReal *luts, int offset,
                                                     GpuReal lambda) {
    GpuReal t = (lambda - GPU_LUT_MIN_LAMBDA) * ((GpuReal)1.0 / GPU_LUT_STEP);
    if (t <= (GpuReal)0.0) return luts[offset];
    if (t >= (GpuReal)(GPU_LUT_SAMPLES - 1)) return luts[offset + GPU_LUT_SAMPLES - 1];
    int idx = (int)t;
    GpuReal frac = t - (GpuReal)idx;
    return g_lerp(luts[offset + idx], luts[offset + idx + 1], frac);
}

__device__ __forceinline__ GpuComplex evalCustomComplexLut(const GpuReal *luts, int offset,
                                                           GpuReal lambda) {
    GpuReal t = (lambda - GPU_LUT_MIN_LAMBDA) * ((GpuReal)1.0 / GPU_LUT_STEP);
    if (t <= (GpuReal)0.0) return GpuComplex{luts[offset], luts[offset + 1]};
    if (t >= (GpuReal)(GPU_LUT_SAMPLES - 1)) {
        int last = offset + 2 * (GPU_LUT_SAMPLES - 1);
        return GpuComplex{luts[last], luts[last + 1]};
    }
    int idx = (int)t;
    GpuReal frac = t - (GpuReal)idx;
    int base = offset + 2 * idx;
    return GpuComplex{g_lerp(luts[base], luts[base + 2], frac),
                      g_lerp(luts[base + 1], luts[base + 3], frac)};
}

__device__ __forceinline__ GpuComplex evalTableRefr(GpuReal lambda, const GpuComplex *eta,
                                                    GpuReal lambdaStep, int lineCount) {
    if (lambda < (GpuReal)390.0) return GpuComplex{0, 0};
    if (lambda > (GpuReal)390.0 + (GpuReal)lineCount * lambdaStep) return GpuComplex{0, 0};
    int slot = (int)((lambda - (GpuReal)390.0) / lambdaStep);
    if (slot < 0 || slot + 1 >= lineCount) return GpuComplex{0, 0};
    GpuReal preLambda = (GpuReal)390.0 + lambdaStep * (GpuReal)slot;
    GpuReal nxtLambda = (GpuReal)390.0 + lambdaStep * (GpuReal)(slot + 1);
    return GpuComplex{g_lerpInterval(preLambda, nxtLambda, lambda, eta[slot].R, eta[slot + 1].R),
                      g_lerpInterval(preLambda, nxtLambda, lambda, eta[slot].I, eta[slot + 1].I)};
}

__device__ __forceinline__ GpuComplex evalRefractiveIndex(const GpuTexture &tex, GpuReal lambda) {
    switch (tex.refrKind) {
    case PT_REFR_AIR:
        return GpuComplex{(GpuReal)1.0, (GpuReal)0.0};
    case PT_REFR_PLASTIC:
        return GpuComplex{(GpuReal)1.5, (GpuReal)0.0};
    case PT_REFR_AEROGEL:
        return GpuComplex{(GpuReal)1.01, (GpuReal)1e-7};
    case PT_REFR_DIAMOND: {
        GpuReal x = lambda * (GpuReal)1e-3;
        GpuReal t1 = (GpuReal)0.1750 / x;
        GpuReal t2 = (GpuReal)0.1060 / x;
        GpuReal n2 = (GpuReal)1.0 + (GpuReal)0.3306 / ((GpuReal)1.0 - t1 * t1) +
                     (GpuReal)4.3356 / ((GpuReal)1.0 - t2 * t2);
        return GpuComplex{g_sqrt(n2), (GpuReal)0.0};
    }
    case PT_REFR_MARBLE: {
        GpuReal l = lambda * (GpuReal)1e-3;
        GpuReal l2 = l * l;
        GpuReal n2 = (GpuReal)0.73358749 +
                     ((GpuReal)0.96464345 * l2) / (l2 - (GpuReal)1.94325203e-2) +
                     ((GpuReal)1.82831454 * l2) / (l2 - (GpuReal)120.0);
        return GpuComplex{g_sqrt(n2), (GpuReal)6e-6};
    }
    case PT_REFR_PINK_MARBLE: {
        GpuReal k;
        if (lambda < (GpuReal)470.0) {
            k = (GpuReal)6e-6;
        } else if (lambda < (GpuReal)530.0) {
            k = g_lerp((GpuReal)6e-6, (GpuReal)8e-6, (lambda - (GpuReal)470.0) / (GpuReal)60.0);
        } else if (lambda < (GpuReal)650.0) {
            k = g_lerp((GpuReal)8e-6, (GpuReal)2e-6, (lambda - (GpuReal)530.0) / (GpuReal)120.0);
        } else {
            k = (GpuReal)2e-6;
        }
        GpuReal l = lambda * (GpuReal)1e-3;
        GpuReal l2 = l * l;
        GpuReal n2 = (GpuReal)0.73358749 +
                     ((GpuReal)0.96464345 * l2) / (l2 - (GpuReal)1.94325203e-2) +
                     ((GpuReal)1.82831454 * l2) / (l2 - (GpuReal)120.0);
        return GpuComplex{g_sqrt(n2), k};
    }
    case PT_REFR_SAPPHIRE: {
        GpuComplex eCombined =
            evalTableRefr(lambda, g_scene.sapphireEC, (GpuReal)10.0, g_scene.sapphireCount);
        GpuReal l = lambda * (GpuReal)1e-3;
        GpuReal l2 = l * l;
        GpuReal nterm1 = (GpuReal)1.5039759 * l2 / (l2 - (GpuReal)(0.0740288 * 0.0740288));
        GpuReal nterm2 = (GpuReal)0.55069141 * l2 / (l2 - (GpuReal)(0.1216529 * 0.1216529));
        GpuReal nterm3 = (GpuReal)6.5927379 * l2 / (l2 - (GpuReal)(20.072248 * 20.072248));
        GpuReal n = g_sqrt((GpuReal)1.0 + nterm1 + nterm2 + nterm3);
        GpuReal epsilon = (eCombined.R + eCombined.I) * (GpuReal)0.5;
        GpuReal alpha = (GpuReal)2.302585092994046 * epsilon * tex.concentration * (GpuReal)1e-4;
        GpuReal k = alpha * l / ((GpuReal)4.0 * GPU_PI);
        return GpuComplex{n, k};
    }
    case PT_REFR_SILVER:
        return evalTableRefr(lambda, g_scene.agEta, (GpuReal)1.0, g_scene.agCount);
    case PT_REFR_GOLD:
        return evalTableRefr(lambda, g_scene.auEta, (GpuReal)10.0, g_scene.auCount);
    case PT_REFR_COPPER:
        return evalTableRefr(lambda, g_scene.cuEta, (GpuReal)10.0, g_scene.cuCount);
    case PT_REFR_IRON:
        return evalTableRefr(lambda, g_scene.feEta, (GpuReal)10.0, g_scene.feCount);
    case PT_REFR_GLASS:
        return evalTableRefr(lambda, g_scene.glassEta, (GpuReal)10.0, g_scene.glassCount);
    default:
        return evalCustomComplexLut(g_scene.customLuts, tex.refrLutOffset, lambda);
    }
}

__device__ __forceinline__ GpuReal evalBaseColor(const GpuTexture &tex, GpuReal lambda) {
    switch (tex.baseKind) {
    case PT_BASE_WHITE:
        return (GpuReal)0.8;
    case PT_BASE_BLACK:
        return (GpuReal)0.0;
    case PT_BASE_RED:
        return (GpuReal)0.05 +
               (GpuReal)0.75 / ((GpuReal)1.0 + g_exp((GpuReal)(-0.06) * (lambda - (GpuReal)650.0)));
    default:
        return evalCustomRealLut(g_scene.customLuts, tex.baseLutOffset, lambda);
    }
}

__device__ __forceinline__ GpuReal evalSigmaS(const GpuTexture &tex, GpuReal lambda) {
    switch (tex.sigmaKind) {
    case PT_SIGMA_MARBLE:
        return (GpuReal)0.2;
    case PT_SIGMA_PINK_MARBLE:
        if (lambda < (GpuReal)470.0) return (GpuReal)0.21;
        if (lambda < (GpuReal)530.0) {
            return g_lerp((GpuReal)0.21, (GpuReal)0.22, (lambda - (GpuReal)470.0) / (GpuReal)60.0);
        }
        if (lambda < (GpuReal)650.0) {
            return g_lerp((GpuReal)0.22, (GpuReal)0.20, (lambda - (GpuReal)530.0) / (GpuReal)120.0);
        }
        return (GpuReal)0.20;
    case PT_SIGMA_AEROGEL: {
        GpuReal r = (GpuReal)550.0 / lambda;
        GpuReal r2 = r * r;
        return (GpuReal)4e-3 * r2 * r2;
    }
    default:
        return evalCustomRealLut(g_scene.customLuts, tex.sigmaLutOffset, lambda);
    }
}

__device__ __forceinline__ GpuVec3 samplePhaseDirection(const GpuTexture &tex, GpuVec3 input,
                                                        Pcg32 &rng) {
    if (tex.phaseKind == PT_PHASE_HG_MARBLE) {
        GpuReal g = (GpuReal)0.9;
        GpuReal u = rng.nextReal();
        GpuReal v = rng.nextReal();
        GpuReal theta = (GpuReal)2.0 * GPU_PI * u;
        GpuReal g2 = g * g;
        GpuReal temp = ((GpuReal)1.0 - g2) / ((GpuReal)1.0 + g - (GpuReal)2.0 * g * v);
        GpuReal cosPhi = ((GpuReal)1.0 + g2 - temp * temp) / ((GpuReal)2.0 * g);
        GpuReal sinPhi = g_sqrt(g_max((GpuReal)1.0 - cosPhi * cosPhi, (GpuReal)0.0));
        GpuVec3 local{g_cos(theta) * sinPhi, g_sin(theta) * sinPhi, cosPhi};
        return g_toWorld(local, input);
    }
    // PT_PHASE_RAYLEIGH
    GpuReal v = (GpuReal)2.0 - (GpuReal)4.0 * rng.nextReal();
    GpuReal t = g_cbrt(v + g_sqrt(v * v + (GpuReal)1.0));
    GpuReal cosPhi = t - ((GpuReal)1.0 / t);
    GpuReal sinPhi = g_sqrt(g_max((GpuReal)1.0 - cosPhi * cosPhi, (GpuReal)0.0));
    GpuReal theta = (GpuReal)2.0 * GPU_PI * rng.nextReal();
    GpuVec3 local{g_cos(theta) * sinPhi, g_sin(theta) * sinPhi, cosPhi};
    return g_toWorld(local, input);
}

__device__ __forceinline__ double devBlackbody(double wavelength, double T) {
    double lambda = wavelength * 1e-9;
    constexpr double h = 6.62607015e-34;
    constexpr double c = 2.99792458e+8;
    constexpr double kB = 1.380649e-23;
    constexpr double c1 = 2.0 * h * c * c;
    constexpr double c2 = (h * c) / kB;
    double exponent = c2 / (lambda * T);
    if (exponent > 700.0) return 0.0;
    double l2 = lambda * lambda;
    double l5 = l2 * l2 * lambda;
    return c1 / (l5 * (exp(exponent) - 1.0));
}

__device__ __forceinline__ GpuReal evalLightIntensity(int lightIdx, GpuReal wavelength) {
    const GpuLightSource &ls = g_scene.lights[lightIdx];
    switch (ls.lightKind) {
    case PT_LIGHT_TUNGSTEN:
        return (GpuReal)(devBlackbody((double)wavelength, 2800.0) / 215561768139.854309);
    case PT_LIGHT_SUNLIGHT:
        return (GpuReal)(devBlackbody((double)wavelength, 5500.0) / 20481294390815.578125);
    case PT_LIGHT_WHITE:
        return (GpuReal)(devBlackbody((double)wavelength, 6500.0) / devBlackbody(555.0, 6500.0));
    default:
        return evalCustomRealLut(g_scene.customLuts, ls.lutOffset, wavelength);
    }
}

__device__ __forceinline__ GpuColorXYZ devWavelengthToXYZ(GpuReal wavelength) {
    if (wavelength < (GpuReal)390.0 || wavelength > (GpuReal)(390.0 + 5.0 * 89.0)) {
        return GpuColorXYZ{0, 0, 0};
    }
    int slot = (int)((wavelength - (GpuReal)390.0) / (GpuReal)5.0);
    if (slot >= 89) return g_scene.xyzTable[89];
    GpuReal l1 = (GpuReal)390.0 + (GpuReal)5.0 * (GpuReal)slot;
    GpuReal l2 = l1 + (GpuReal)5.0;
    const GpuColorXYZ &c1 = g_scene.xyzTable[slot];
    const GpuColorXYZ &c2 = g_scene.xyzTable[slot + 1];
    return GpuColorXYZ{g_lerpInterval(l1, l2, wavelength, c1.X, c2.X),
                       g_lerpInterval(l1, l2, wavelength, c1.Y, c2.Y),
                       g_lerpInterval(l1, l2, wavelength, c1.Z, c2.Z)};
}

__device__ __forceinline__ uint8_t devAdj(double C) {
    if (C < 0.0) C = 0.0;
    double sRGB = (fabs(C) < 0.0031308) ? (12.92 * C) : (1.055 * pow(C, 0.41666) - 0.055);
    double v = sRGB / (1.0 + sRGB) * 255.0;
    if (v < 0.0) v = 0.0;
    if (v > 255.0) v = 255.0;
    return (uint8_t)v;
}

__device__ __forceinline__ uint32_t devXYZtoRGB(double X, double Y, double Z) {
    ScreenColor sc;
    sc.color.R = devAdj(3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z);
    sc.color.G = devAdj(-0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z);
    sc.color.B = devAdj(0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z);
    sc.color.A = 0;
    return sc.pixel;
}

/* ==================== Geometry & BVH Intersection ==================== */

__device__ __forceinline__ GpuReal safeInv1(GpuReal v) {
    if (g_abs(v) > (GpuReal)1e-20) return (GpuReal)1.0 / v;
    return v >= (GpuReal)0.0 ? (GpuReal)1e20 : (GpuReal)-1e20;
}

__device__ __forceinline__ GpuVec3 safeInvDir(GpuVec3 d) {
    return GpuVec3{safeInv1(d.x), safeInv1(d.y), safeInv1(d.z)};
}

__device__ __forceinline__ bool intersectAABB(GpuVec3 bmin, GpuVec3 bmax, GpuVec3 orig,
                                              GpuVec3 invDir, GpuReal maxT, GpuReal &tminOut) {
    GpuReal t0x = (bmin.x - orig.x) * invDir.x;
    GpuReal t1x = (bmax.x - orig.x) * invDir.x;
    GpuReal tmin = g_min(t0x, t1x);
    GpuReal tmax = g_max(t0x, t1x);

    GpuReal t0y = (bmin.y - orig.y) * invDir.y;
    GpuReal t1y = (bmax.y - orig.y) * invDir.y;
    tmin = g_max(tmin, g_min(t0y, t1y));
    tmax = g_min(tmax, g_max(t0y, t1y));

    GpuReal t0z = (bmin.z - orig.z) * invDir.z;
    GpuReal t1z = (bmax.z - orig.z) * invDir.z;
    tmin = g_max(tmin, g_min(t0z, t1z));
    tmax = g_min(tmax, g_max(t0z, t1z));

    tminOut = tmin;
    return tmax >= g_max((GpuReal)0.0, tmin) && tmin < maxT;
}

__device__ __forceinline__ bool intersectSphereGeom(GpuVec3 center, GpuReal radius,
                                                    const GpuRay &ray, GpuReal maxT,
                                                    GpuReal &tOut, GpuVec3 &nOut) {
    GpuVec3 W = v3Sub(ray.start, center);
    GpuReal a = v3Dot(ray.direction, ray.direction);
    GpuReal h = v3Dot(ray.direction, W);
    GpuReal c = v3Dot(W, W) - radius * radius;
    GpuReal disc = h * h - a * c;
    if (disc < (GpuReal)0.0) return false;
    GpuReal sqrtDisc = g_sqrt(disc);
    GpuReal t1, t2;
    if (h == (GpuReal)0.0 && c == (GpuReal)0.0) {
        return false;
    }
    GpuReal q = (h >= (GpuReal)0.0) ? (-h - sqrtDisc) : (-h + sqrtDisc);
    GpuReal r1 = q / a;
    GpuReal r2 = (q != (GpuReal)0.0) ? (c / q) : GPU_INF;
    t1 = g_min(r1, r2);
    t2 = g_max(r1, r2);
    GpuReal t = (t1 > GPU_T_EPS) ? t1 : t2;
    if (t <= GPU_T_EPS || t > maxT) return false;
    GpuVec3 p = v3Add(ray.start, v3Mul(t, ray.direction));
    tOut = t;
    nOut = v3Unit(v3Sub(p, center));
    return true;
}

__device__ __forceinline__ bool rayXsegmentIntersection(GpuVec2 O, GpuVec2 A, GpuVec2 B) {
    if ((O.y < A.y) == (O.y < B.y)) return false;
    GpuReal xplust = g_lerpInterval(A.y, B.y, O.y, A.x, B.x);
    return (xplust - O.x) >= (GpuReal)0.0;
}

__device__ __forceinline__ bool intersectPrim(const GpuPrim &prim, const GpuRay &ray, GpuReal maxT,
                                              GpuReal &tOut, GpuVec3 &nOut) {
    if (prim.type == GPU_PRIM_TRIANGLE) {
        GpuVec3 A = v3Sub(prim.b, prim.a);
        GpuVec3 B = v3Sub(prim.c, prim.a);
        GpuVec3 D = ray.direction;
        GpuVec3 pvec = v3Cross(D, B);
        GpuReal det = v3Dot(A, pvec);
        if (g_abs(det) < GPU_EPS) return false;
        GpuReal invDet = (GpuReal)1.0 / det;
        GpuVec3 W = v3Sub(ray.start, prim.a);
        GpuReal u = v3Dot(W, pvec) * invDet;
        if (u < (GpuReal)0.0 || u > (GpuReal)1.0) return false;
        GpuVec3 qvec = v3Cross(W, A);
        GpuReal v = v3Dot(D, qvec) * invDet;
        if (v < (GpuReal)0.0 || u + v > (GpuReal)1.0) return false;
        GpuReal t = v3Dot(B, qvec) * invDet;
        if (t <= GPU_T_EPS || t > maxT) return false;
        tOut = t;
        nOut = prim.normal;
        return true;
    } else if (prim.type == GPU_PRIM_SPHERE) {
        return intersectSphereGeom(prim.a, prim.b.x, ray, maxT, tOut, nOut);
    } else if (prim.type == GPU_PRIM_CONVEX_POLYGON) {
        GpuVec3 N = prim.normal;
        GpuReal NdotD = v3Dot(N, ray.direction);
        if (g_abs(NdotD) < GPU_EPS) return false;
        GpuVec3 v0 = g_scene.polyVerts3D[prim.vertOffset];
        GpuReal t = (v3Dot(N, v0) - v3Dot(N, ray.start)) / NdotD;
        if (t <= GPU_T_EPS || t > maxT) return false;
        GpuVec3 P = v3Add(ray.start, v3Mul(t, ray.direction));
        for (int i = 0; i < prim.vertCount; i++) {
            GpuVec3 p1 = g_scene.polyVerts3D[prim.vertOffset + i];
            GpuVec3 p2 =
                g_scene.polyVerts3D[prim.vertOffset + ((i + 1 == prim.vertCount) ? 0 : i + 1)];
            GpuVec3 E = v3Sub(P, p1);
            GpuVec3 E1 = v3Sub(p2, p1);
            if (v3Dot(v3Cross(E1, E), N) < (GpuReal)0.0) return false;
        }
        tOut = t;
        nOut = N;
        return true;
    } else {
        // GPU_PRIM_POLYGON
        GpuVec3 N = prim.normal;
        GpuReal NdotD = v3Dot(N, ray.direction);
        if (g_abs(NdotD) < GPU_EPS) return false;
        GpuReal t = (v3Dot(N, prim.a) - v3Dot(N, ray.start)) / NdotD;
        if (t <= GPU_T_EPS || t > maxT) return false;
        GpuVec3 collidePoint = v3Add(ray.start, v3Mul(t, ray.direction));
        GpuVec3 disp = v3Sub(collidePoint, prim.a);
        GpuVec2 P{v3Dot(disp, prim.b), v3Dot(disp, prim.c)};
        int hits = 0;
        for (int i = 0; i < prim.vertCount; i++) {
            GpuVec2 p1 = g_scene.polyVerts2D[prim.vertOffset + i];
            GpuVec2 p2 =
                g_scene.polyVerts2D[prim.vertOffset + ((i + 1 == prim.vertCount) ? 0 : i + 1)];
            if (rayXsegmentIntersection(P, p1, p2)) hits++;
        }
        if ((hits & 1) == 0) return false;
        tOut = t;
        nOut = N;
        return true;
    }
}

__device__ void intersectObjectBlas(int objIdx, const GpuRay &ray, GpuVec3 invDir, GpuReal &bestT,
                                    GpuHit &bestHit) {
    int root = g_scene.objects[objIdx].blasRoot;
    if (root < 0) return;

    int stack[32];
    int sp = 0;
    stack[sp++] = root;

    while (sp > 0) {
        const GpuBvhNode &node = g_scene.blasNodes[stack[--sp]];
        GpuReal nodeTmin;
        if (!intersectAABB(node.bmin, node.bmax, ray.start, invDir, bestT, nodeTmin)) continue;

        if (node.primCount > 0) {
            for (int i = 0; i < node.primCount; i++) {
                GpuReal t;
                GpuVec3 n;
                if (intersectPrim(g_scene.prims[node.primOffset + i], ray, bestT, t, n)) {
                    if (t <= bestT) {
                        bestT = t;
                        bestHit.collide = true;
                        bestHit.distance = t;
                        bestHit.normal = n;
                        bestHit.objIdx = objIdx;
                    }
                }
            }
        } else {
            GpuReal tL, tR;
            const GpuBvhNode &nL = g_scene.blasNodes[node.left];
            const GpuBvhNode &nR = g_scene.blasNodes[node.right];
            bool hitL = intersectAABB(nL.bmin, nL.bmax, ray.start, invDir, bestT, tL);
            bool hitR = intersectAABB(nR.bmin, nR.bmax, ray.start, invDir, bestT, tR);
            if (hitL && hitR && sp + 2 <= 32) {
                if (tL < tR) {
                    stack[sp++] = node.right;
                    stack[sp++] = node.left;
                } else {
                    stack[sp++] = node.left;
                    stack[sp++] = node.right;
                }
            } else if (hitL && sp < 32) {
                stack[sp++] = node.left;
            } else if (hitR && sp < 32) {
                stack[sp++] = node.right;
            }
        }
    }
}

__device__ bool anyHitObjectBlas(int objIdx, const GpuRay &ray, GpuVec3 invDir, GpuReal maxT) {
    int root = g_scene.objects[objIdx].blasRoot;
    if (root < 0) return false;

    int stack[32];
    int sp = 0;
    stack[sp++] = root;

    while (sp > 0) {
        const GpuBvhNode &node = g_scene.blasNodes[stack[--sp]];
        GpuReal nodeTmin;
        if (!intersectAABB(node.bmin, node.bmax, ray.start, invDir, maxT, nodeTmin)) continue;

        if (node.primCount > 0) {
            for (int i = 0; i < node.primCount; i++) {
                GpuReal t;
                GpuVec3 n;
                if (intersectPrim(g_scene.prims[node.primOffset + i], ray, maxT, t, n)) {
                    return true;
                }
            }
        } else if (sp + 2 <= 32) {
            stack[sp++] = node.left;
            stack[sp++] = node.right;
        }
    }
    return false;
}

__device__ GpuHit intersectSceneObjects(const GpuRay &ray) {
    GpuHit best{false, GPU_INF, GpuVec3{0, 0, 0}, -1};
    if (g_scene.tlasRoot < 0) return best;

    GpuVec3 invDir = safeInvDir(ray.direction);
    GpuReal bestT = GPU_INF;

    int stack[32];
    int sp = 0;
    stack[sp++] = g_scene.tlasRoot;

    while (sp > 0) {
        const GpuBvhNode &node = g_scene.tlasNodes[stack[--sp]];
        GpuReal nodeTmin;
        if (!intersectAABB(node.bmin, node.bmax, ray.start, invDir, bestT, nodeTmin)) continue;

        if (node.primCount > 0) {
            for (int i = 0; i < node.primCount; i++) {
                int objIdx = g_scene.tlasObjIndices[node.primOffset + i];
                intersectObjectBlas(objIdx, ray, invDir, bestT, best);
            }
        } else {
            GpuReal tL, tR;
            const GpuBvhNode &nL = g_scene.tlasNodes[node.left];
            const GpuBvhNode &nR = g_scene.tlasNodes[node.right];
            bool hitL = intersectAABB(nL.bmin, nL.bmax, ray.start, invDir, bestT, tL);
            bool hitR = intersectAABB(nR.bmin, nR.bmax, ray.start, invDir, bestT, tR);
            if (hitL && hitR && sp + 2 <= 32) {
                if (tL < tR) {
                    stack[sp++] = node.right;
                    stack[sp++] = node.left;
                } else {
                    stack[sp++] = node.left;
                    stack[sp++] = node.right;
                }
            } else if (hitL && sp < 32) {
                stack[sp++] = node.left;
            } else if (hitR && sp < 32) {
                stack[sp++] = node.right;
            }
        }
    }
    return best;
}

__device__ GpuLightHit intersectSceneLights(const GpuRay &ray) {
    GpuLightHit best{false, GPU_INF, GpuVec3{0, 0, 0}, -1};
    for (int i = 0; i < g_scene.lightCount; i++) {
        GpuReal t;
        GpuVec3 n;
        if (intersectSphereGeom(g_scene.lights[i].center, g_scene.lights[i].radius, ray,
                                best.distance, t, n)) {
            if (t <= best.distance) {
                best.collide = true;
                best.distance = t;
                best.normal = n;
                best.lightIdx = i;
            }
        }
    }
    return best;
}

__device__ bool visibilityTest(const GpuRay &shadowRay, GpuReal distance, int targetLightIdx) {
    GpuReal maxT = distance - GPU_T_EPS;
    if (maxT <= GPU_T_EPS) return true;

    if (g_scene.tlasRoot >= 0) {
        GpuVec3 invDir = safeInvDir(shadowRay.direction);
        int stack[32];
        int sp = 0;
        stack[sp++] = g_scene.tlasRoot;

        while (sp > 0) {
            const GpuBvhNode &node = g_scene.tlasNodes[stack[--sp]];
            GpuReal nodeTmin;
            if (!intersectAABB(node.bmin, node.bmax, shadowRay.start, invDir, maxT, nodeTmin)) {
                continue;
            }
            if (node.primCount > 0) {
                for (int i = 0; i < node.primCount; i++) {
                    int objIdx = g_scene.tlasObjIndices[node.primOffset + i];
                    if (anyHitObjectBlas(objIdx, shadowRay, invDir, maxT)) return false;
                }
            } else if (sp + 2 <= 32) {
                stack[sp++] = node.left;
                stack[sp++] = node.right;
            }
        }
    }

    for (int i = 0; i < g_scene.lightCount; i++) {
        if (i == targetLightIdx) continue;
        GpuReal t;
        GpuVec3 n;
        if (intersectSphereGeom(g_scene.lights[i].center, g_scene.lights[i].radius, shadowRay, maxT,
                                t, n)) {
            return false;
        }
    }
    return true;
}

/* ==================== BSDF / NEE / SSS / Path Tracing ==================== */

__device__ __forceinline__ GpuVec3 fixedNextStart(GpuVec3 curPoint, GpuVec3 N, bool transmission) {
    return v3Add(curPoint, v3Mul(transmission ? -GPU_MOVE_EPS : GPU_MOVE_EPS, N));
}

__device__ __forceinline__ GpuRay makeRay(GpuVec3 start, GpuVec3 dir, GpuReal wavelength) {
    return GpuRay{start, v3Unit(dir), wavelength};
}

__device__ __forceinline__ GpuVec3 sampleGGX(Pcg32 &rng, GpuReal alpha) {
    GpuReal u1 = rng.nextReal();
    GpuReal u2 = rng.nextReal();
    GpuReal theta = (GpuReal)2.0 * GPU_PI * u1;
    GpuReal cosPhi = g_sqrt(((GpuReal)1.0 - u2) / ((GpuReal)1.0 + (alpha * alpha - (GpuReal)1.0) * u2));
    GpuReal sinPhi = g_sqrt(g_max((GpuReal)0.0, (GpuReal)1.0 - cosPhi * cosPhi));
    return GpuVec3{g_cos(theta) * sinPhi, g_sin(theta) * sinPhi, cosPhi};
}

__device__ __forceinline__ GpuVec3 sampleCosine(Pcg32 &rng) {
    GpuReal u1 = rng.nextReal();
    GpuReal u2 = rng.nextReal();
    GpuReal sinPhi = g_sqrt(g_max((GpuReal)0.0, (GpuReal)1.0 - u1));
    GpuReal theta = (GpuReal)2.0 * GPU_PI * u2;
    return GpuVec3{g_cos(theta) * sinPhi, g_sin(theta) * sinPhi, g_sqrt(u1)};
}

__device__ __forceinline__ GpuVec3 getRefractionDirection(GpuReal n1R, GpuReal n2R, GpuReal cosTheta1,
                                                          GpuVec3 I, GpuVec3 N) {
    GpuReal eta = n1R / n2R;
    GpuReal eta2 = eta * eta;
    GpuReal sin2Theta1 = g_max((GpuReal)1.0 - cosTheta1 * cosTheta1, (GpuReal)0.0);
    GpuReal coeff = eta * cosTheta1 - g_sqrt(g_max((GpuReal)0.0, (GpuReal)1.0 - eta2 * sin2Theta1));
    return v3Add(v3Mul(eta, I), v3Mul(coeff, N));
}

__device__ __forceinline__ GpuReal getGeometryTermDenom(GpuReal NdotL, GpuReal NdotV, GpuReal alpha) {
    GpuReal alpha2 = alpha * alpha;
    GpuReal NdotV2 = NdotV * NdotV;
    GpuReal NdotL2 = NdotL * NdotL;
    return NdotL * g_sqrt(alpha2 + ((GpuReal)1.0 - alpha2) * NdotV2) +
           NdotV * g_sqrt(alpha2 + ((GpuReal)1.0 - alpha2) * NdotL2);
}

__device__ __forceinline__ GpuReal getGeometryTerm(GpuReal NdotV, GpuReal NdotL, GpuReal alpha) {
    GpuReal absNdotV = g_abs(NdotV);
    GpuReal absNdotL = g_abs(NdotL);
    return (GpuReal)2.0 * absNdotV * absNdotL / getGeometryTermDenom(absNdotL, absNdotV, alpha);
}

__device__ __forceinline__ GpuReal getFresnelTerm(GpuComplex n1, GpuComplex n2, GpuReal cosTheta) {
    GpuReal cosThetaForF;
    if (n1.R > n2.R) {
        GpuReal n1R2 = n1.R * n1.R;
        GpuReal n2R2 = n2.R * n2.R;
        GpuReal sin2Theta = g_max((GpuReal)0.0, (GpuReal)1.0 - cosTheta * cosTheta);
        if (n1R2 * sin2Theta >= n2R2) {
            return (GpuReal)1.0;
        }
        GpuReal sin2Theta2 = (n1R2 / n2R2) * sin2Theta;
        cosThetaForF = g_sqrt(g_max((GpuReal)0.0, (GpuReal)1.0 - sin2Theta2));
    } else {
        cosThetaForF = cosTheta;
    }

    GpuComplex num = gcSub(n1, n2);
    GpuComplex den = gcAdd(n1, n2);
    GpuReal F0 = gcMod2(gcDiv(num, den));
    GpuReal y = (GpuReal)1.0 - cosThetaForF;
    GpuReal y2 = y * y;
    GpuReal y5 = y2 * y2 * y;
    return F0 + ((GpuReal)1.0 - F0) * y5;
}

__device__ __forceinline__ GpuNextSim sampleBRDF(GpuVec3 m, GpuVec3 v, GpuVec3 N, GpuReal alpha,
                                                 GpuReal F, GpuVec3 collidePoint,
                                                 const GpuRay &curRay) {
    GpuVec3 l = v3Sub(v3Mul((GpuReal)2.0 * v3Dot(v, m), m), v);
    GpuReal NdotV = v3Dot(N, v);
    GpuReal NdotL = v3Dot(N, l);
    GpuReal NdotM = v3Dot(N, m);
    GpuReal MdotV = v3Dot(m, v);

    if (NdotV <= GPU_EPS || NdotL <= GPU_EPS || NdotM <= GPU_EPS) {
        return nextSimFail();
    }

    GpuReal denom = getGeometryTermDenom(NdotL, NdotV, alpha);
    GpuReal scalingFactor = F * ((GpuReal)2.0 * NdotL * MdotV) / (denom * NdotM);
    GpuVec3 nxtStart = fixedNextStart(collidePoint, N, false);
    return nextSimStep(scalingFactor, makeRay(nxtStart, l, curRay.wavelength));
}

__device__ __forceinline__ GpuNextSim sampleSpecular(GpuVec3 N, GpuVec3 v, GpuReal F,
                                                     GpuVec3 collidePoint, const GpuRay &curRay) {
    GpuVec3 l = v3Sub(v3Mul((GpuReal)2.0 * v3Dot(v, N), N), v);
    GpuVec3 nxtStart = fixedNextStart(collidePoint, N, false);
    return nextSimStep(F, makeRay(nxtStart, l, curRay.wavelength));
}

__device__ __forceinline__ GpuNextSim sampleBTDF(GpuVec3 N, GpuVec3 v, GpuVec3 m, GpuReal alpha,
                                                 GpuReal F, GpuVec3 collidePoint, const GpuRay &ray,
                                                 GpuComplex n1, GpuComplex n2) {
    GpuReal n1R = n1.R;
    GpuReal n2R = n2.R;

    if (g_abs(n1R - n2R) < GPU_EPS) {
        GpuVec3 nxtStart = fixedNextStart(collidePoint, N, true);
        return nextSimStep((GpuReal)1.0, makeRay(nxtStart, ray.direction, ray.wavelength));
    }

    GpuReal cosTheta1 = v3Dot(m, v);
    GpuVec3 l = getRefractionDirection(n1R, n2R, cosTheta1, ray.direction, m);
    GpuReal NdotL = v3Dot(N, l);
    GpuReal NdotV = v3Dot(N, v);
    GpuReal NdotM = v3Dot(N, m);

    if (NdotL >= -GPU_EPS || NdotV <= GPU_EPS || NdotM <= GPU_EPS) {
        return nextSimFail();
    }

    GpuReal MdotL = v3Dot(m, l);
    GpuReal MdotV = v3Dot(m, v);
    if (MdotL * MdotV >= -GPU_EPS) {
        return nextSimFail();
    }

    GpuReal absNdotL = g_abs(NdotL);
    GpuReal absMdotV = g_abs(MdotV);
    GpuReal GTermDenom = getGeometryTermDenom(absNdotL, NdotV, alpha);
    GpuReal GTerm = ((GpuReal)2.0 * NdotV * absNdotL) / GTermDenom;
    GpuReal eta = n1R / n2R;
    GpuReal scalingFactor = ((GpuReal)1.0 - F) * eta * eta * (absMdotV * GTerm) / (NdotV * NdotM);
    GpuVec3 nxtStart = fixedNextStart(collidePoint, N, true);
    return nextSimStep(scalingFactor, makeRay(nxtStart, l, ray.wavelength));
}

__device__ __forceinline__ GpuNextSim sampleRefraction(GpuVec3 N, GpuVec3 v, GpuVec3 collidePoint,
                                                       const GpuRay &ray, GpuComplex n1,
                                                       GpuComplex n2) {
    GpuReal n1R = n1.R;
    GpuReal n2R = n2.R;
    GpuReal cosTheta1 = v3Dot(v, N);
    GpuVec3 l = getRefractionDirection(n1R, n2R, cosTheta1, ray.direction, N);
    GpuVec3 nxtStart = fixedNextStart(collidePoint, N, true);
    GpuReal eta = n1R / n2R;
    return nextSimStep(eta * eta, makeRay(nxtStart, l, ray.wavelength));
}

__device__ __forceinline__ GpuNextSim sampleDiffusion(Pcg32 &rng, GpuVec3 N, GpuReal F,
                                                      const GpuRay &ray, GpuVec3 collidePoint,
                                                      const GpuTexture &insideTex) {
    GpuVec3 local = sampleCosine(rng);
    GpuVec3 nxtDir = g_toWorld(local, N);
    GpuVec3 nxtStart = fixedNextStart(collidePoint, N, false);
    GpuReal baseColor = evalBaseColor(insideTex, ray.wavelength);
    GpuReal scalingFactor = baseColor * ((GpuReal)1.0 - F);
    return nextSimStep(scalingFactor, makeRay(nxtStart, nxtDir, ray.wavelength));
}

__device__ GpuNextSim sampleSSS(int objIdx, const GpuTexture &scatterTex, GpuComplex n2, Pcg32 &rng,
                                const GpuRay &curRay) {
    static constexpr int SSS_MAX_STEPS = 10000000;
    GpuReal lambda = curRay.wavelength;
    GpuReal sigmaS = evalSigmaS(scatterTex, lambda);
    GpuReal k = n2.I;
    GpuReal sigmaA = ((GpuReal)4.0 * GPU_PI * k / lambda) * (GpuReal)1e5;
    GpuReal sigmaT = sigmaA + sigmaS;
    GpuReal albedo = (sigmaT > GPU_EPS) ? (sigmaS / sigmaT) : (GpuReal)1.0;

    GpuRay ray = curRay;
    GpuReal scalingFactor = (GpuReal)1.0;

    for (int i = 0; i < SSS_MAX_STEPS; i++) {
        GpuHit hit{false, GPU_INF, GpuVec3{0, 0, 0}, -1};
        GpuReal bestT = GPU_INF;
        GpuVec3 invDir = safeInvDir(ray.direction);
        intersectObjectBlas(objIdx, ray, invDir, bestT, hit);
        GpuReal boundaryDistance = hit.collide ? hit.distance : GPU_INF;

        GpuReal xi = g_max(GPU_EPS, rng.nextReal());
        GpuReal walkDistance = (sigmaT < GPU_EPS) ? GPU_INF : (-g_log(xi) / sigmaT);

        if (walkDistance >= boundaryDistance) {
            GpuReal step = (boundaryDistance > GPU_SSS_BACKSTEP)
                               ? (boundaryDistance - GPU_SSS_BACKSTEP)
                               : (GpuReal)0.0;
            ray.start = v3Add(ray.start, v3Mul(step, ray.direction));
            return nextSimStep(scalingFactor, ray);
        }

        GpuReal q = (i > 10) ? g_min(albedo, (GpuReal)0.99) : albedo;
        if (rng.nextReal() > q) {
            return nextSimFail();
        }
        scalingFactor *= (albedo / q);

        GpuVec3 nxtDir = samplePhaseDirection(scatterTex, ray.direction, rng);
        GpuVec3 nxtStart = v3Add(ray.start, v3Mul(walkDistance, ray.direction));
        ray = makeRay(nxtStart, nxtDir, lambda);
    }
    return nextSimFail();
}

__device__ GpuNextSim sampleBSDF(const GpuHit &hit, GpuReal &extinctionFactor, const GpuRay &ray,
                                 Pcg32 &rng) {
    const GpuInterface &iface = g_scene.interfaces[g_scene.objects[hit.objIdx].ifaceIdx];
    const GpuTexture &inTex = g_scene.textures[iface.inTexIdx];
    const GpuTexture &outTex = g_scene.textures[iface.outTexIdx];

    GpuVec3 d = ray.direction;
    GpuVec3 collidePoint = v3Add(ray.start, v3Mul(hit.distance, d));
    GpuVec3 N = hit.normal;

    bool hitFromInside = v3Dot(N, d) > (GpuReal)0.0;
    const GpuTexture *curTexPtr = hitFromInside ? &inTex : &outTex;
    const GpuTexture *nxtTexPtr = hitFromInside ? &outTex : &inTex;
    if (hitFromInside) N = v3Neg(N);

    GpuComplex n1 = evalRefractiveIndex(*curTexPtr, ray.wavelength);
    GpuComplex n2 = evalRefractiveIndex(*nxtTexPtr, ray.wavelength);
    bool isCurrentHalfTransparent = texIsHalfTransparent(*curTexPtr);
    bool isNextHalfTransparent = texIsHalfTransparent(*nxtTexPtr);
    bool isNextFullyTransparent = texIsFullyTransparent(*nxtTexPtr);
    bool isNextMetallic = texIsMetallic(*nxtTexPtr);

    GpuVec3 v = v3Neg(d);
    GpuReal roughness = iface.roughness;
    GpuReal alpha = roughness * roughness;

    GpuVec3 m = (roughness >= GPU_EPS) ? g_toWorld(sampleGGX(rng, alpha), N) : N;
    GpuReal VdotM = v3Dot(v, m);
    if (VdotM <= (GpuReal)0.0) return nextSimFail();

    GpuReal F = getFresnelTerm(n1, n2, VdotM);
    GpuReal scalingFactor = (GpuReal)1.0;
    GpuNextSim nxt{};
    bool isSpecularBounce = false;

    if (isNextMetallic || rng.nextReal() <= F) {
        if (F < GPU_EPS) return nextSimFail();
        if (alpha < GPU_EPS) {
            isSpecularBounce = true;
            nxt = sampleSpecular(N, v, F, collidePoint, ray);
        } else {
            nxt = sampleBRDF(m, v, N, alpha, F, collidePoint, ray);
        }
        scalingFactor *= nxt.scalingFactor;
        if (!isNextMetallic) scalingFactor /= F;
    } else {
        if ((GpuReal)1.0 - F < GPU_EPS) return nextSimFail();
        if (isNextFullyTransparent || isNextHalfTransparent) {
            if (alpha < GPU_EPS) {
                isSpecularBounce = true;
                nxt = sampleRefraction(N, v, collidePoint, ray, n1, n2);
            } else {
                nxt = sampleBTDF(N, v, m, alpha, F, collidePoint, ray, n1, n2);
            }
            scalingFactor *= nxt.scalingFactor / ((GpuReal)1.0 - F);
        } else {
            nxt = sampleDiffusion(rng, N, F, ray, collidePoint, inTex);
            scalingFactor *= nxt.scalingFactor / ((GpuReal)1.0 - F);
        }
    }

    if (nxt.scalingFactor == (GpuReal)0.0) return nextSimFail();

    bool transmission = v3Dot(N, nxt.nxtRay.direction) < (GpuReal)0.0;
    GpuComplex IOR = transmission ? n2 : n1;
    extinctionFactor = (GpuReal)4.0 * GPU_PI * IOR.I / ray.wavelength * (GpuReal)1e5;

    bool halfTransparent = transmission ? isNextHalfTransparent : isCurrentHalfTransparent;
    if (halfTransparent) {
        const GpuTexture &scatterTex = transmission ? *nxtTexPtr : *curTexPtr;
        nxt = sampleSSS(hit.objIdx, scatterTex, IOR, rng, nxt.nxtRay);
        if (nxt.scalingFactor == (GpuReal)0.0) return nextSimFail();
        scalingFactor *= nxt.scalingFactor;
    }

    GpuNextSim out;
    out.scalingFactor = scalingFactor;
    out.nxtRay = nxt.nxtRay;
    out.n1 = n1;
    out.n2 = n2;
    out.l = nxt.nxtRay.direction;
    out.v = v;
    out.N = N;
    out.collidePoint = collidePoint;
    out.isSpecularBounce = isSpecularBounce;
    return out;
}

__device__ __forceinline__ GpuReal getNormalDistributionTerm(GpuReal NdotM, GpuReal alpha) {
    alpha = g_max(alpha, GPU_EPS);
    GpuReal alpha2 = alpha * alpha;
    GpuReal NdotM2 = NdotM * NdotM;
    GpuReal denomPart = NdotM2 * (alpha2 - (GpuReal)1.0) + (GpuReal)1.0;
    return alpha2 / (GPU_PI * denomPart * denomPart);
}

__device__ __forceinline__ int distinguishReflectionOrRefraction(GpuVec3 l, GpuVec3 v, GpuVec3 N) {
    GpuReal NdotL = v3Dot(N, l);
    GpuReal NdotV = v3Dot(N, v);
    GpuReal prod = NdotL * NdotV;
    if (prod > GPU_EPS) return 1;
    if (prod < -GPU_EPS) return 2;
    return 0;
}

__device__ GpuReal evalBSDF(GpuComplex n1, GpuComplex n2, GpuVec3 l, GpuVec3 v, GpuVec3 N, GpuReal alpha,
                            int objIdx, GpuReal lambda, bool transmission) {
    if (g_abs(n1.R - n2.R) < GPU_EPS) return (GpuReal)0.0;

    const GpuInterface &iface = g_scene.interfaces[g_scene.objects[objIdx].ifaceIdx];
    const GpuTexture &inTex = g_scene.textures[iface.inTexIdx];
    bool metallic = texIsMetallic(inTex);
    bool transparent = texIsTransparent(inTex);

    if (v3Dot(N, l) < (GpuReal)0.0) N = v3Neg(N);

    GpuReal NdotL = v3Dot(N, l);
    GpuReal NdotV = v3Dot(N, v);
    GpuVec3 m;
    GpuReal NdotM, MdotL, MdotV;

    if (!transmission) {
        if (NdotL * NdotV <= GPU_EPS) return (GpuReal)0.0;
        m = v3Unit(v3Add(l, v));
        NdotM = v3Dot(N, m);
        MdotL = v3Dot(m, l);
        MdotV = v3Dot(m, v);
        if (MdotL * MdotV <= GPU_EPS || NdotM <= GPU_EPS) return (GpuReal)0.0;
    } else {
        if (NdotL * NdotV >= -GPU_EPS) return (GpuReal)0.0;
        m = v3Unit(v3Add(v3Mul(n1.R, v), v3Mul(n2.R, l)));
        if (v3Dot(N, m) < (GpuReal)0.0) m = v3Neg(m);
        NdotM = v3Dot(N, m);
        MdotL = v3Dot(m, l);
        MdotV = v3Dot(m, v);
        if (MdotL * MdotV >= -GPU_EPS || NdotM <= GPU_EPS) return (GpuReal)0.0;
    }

    GpuReal F = getFresnelTerm(n1, n2, g_abs(MdotV));
    GpuReal G = getGeometryTerm(NdotV, NdotL, alpha);
    GpuReal D = getNormalDistributionTerm(NdotM, alpha);

    if (transmission) {
        GpuReal firstTerm = g_abs(MdotL * MdotV / (NdotL * NdotV));
        GpuReal secondTermDenom = n2.R * MdotL + n1.R * MdotV;
        GpuReal secondTerm =
            (n1.R * n1.R * D * ((GpuReal)1.0 - F) * G) / (secondTermDenom * secondTermDenom);
        return firstTerm * secondTerm;
    }

    GpuReal BRDF = D * F * G / g_abs((GpuReal)4.0 * NdotL * NdotV);
    if (!metallic && !transparent) {
        GpuReal diffusion = evalBaseColor(inTex, lambda) / GPU_PI;
        return BRDF + diffusion * ((GpuReal)1.0 - F);
    }
    return BRDF;
}

__device__ GpuReal evalPBSDF(GpuComplex n1, GpuComplex n2, int objIdx, GpuVec3 l, GpuVec3 v,
                             GpuVec3 N) {
    if (g_abs(n1.R - n2.R) < GPU_EPS) return (GpuReal)0.0;

    int dist = distinguishReflectionOrRefraction(l, v, N);
    if (dist == 0) return (GpuReal)0.0;
    bool transmission = (dist - 1) != 0;

    const GpuInterface &iface = g_scene.interfaces[g_scene.objects[objIdx].ifaceIdx];
    const GpuTexture &inTex = g_scene.textures[iface.inTexIdx];
    bool transparent = texIsFullyTransparent(inTex) || texIsHalfTransparent(inTex);
    bool metallic = texIsMetallic(inTex);

    GpuVec3 m;
    if (transmission) {
        if (!transparent) return (GpuReal)0.0;
        m = v3Unit(v3Add(v3Mul(n1.R, v), v3Mul(n2.R, l)));
    } else {
        m = v3Unit(v3Add(v, l));
    }
    if (v3Dot(N, m) < (GpuReal)0.0) m = v3Neg(m);

    GpuReal MdotL = v3Dot(m, l);
    GpuReal MdotV = v3Dot(m, v);
    GpuReal NdotM = v3Dot(m, N);
    GpuReal roughness = iface.roughness;
    GpuReal alpha = roughness * roughness;
    GpuReal D = getNormalDistributionTerm(NdotM, alpha);
    GpuReal F = getFresnelTerm(n1, n2, g_abs(MdotV));

    if (transmission) {
        if (MdotL * MdotV > -GPU_EPS || NdotM < GPU_EPS) return (GpuReal)0.0;
        GpuReal nom = ((GpuReal)1.0 - F) * D * g_abs(NdotM) * n2.R * n2.R * g_abs(MdotL);
        GpuReal denomPart = n1.R * MdotV + n2.R * MdotL;
        return nom / (denomPart * denomPart);
    } else {
        if (MdotL * MdotV < GPU_EPS || NdotM < GPU_EPS) return (GpuReal)0.0;
        GpuReal pdfBranch = metallic ? (GpuReal)1.0 : F;
        GpuReal pdfSpecular = (D * g_abs(NdotM)) / ((GpuReal)4.0 * g_abs(MdotL));
        if (!metallic && !transparent) {
            GpuReal pdfDiffuse = g_abs(v3Dot(N, l)) / GPU_PI;
            return pdfBranch * pdfSpecular + ((GpuReal)1.0 - F) * pdfDiffuse;
        }
        return pdfBranch * pdfSpecular;
    }
}

__device__ GpuReal sampleNEE(GpuComplex n1, GpuComplex n2, const GpuHit &hit, GpuVec3 collidePoint,
                             Pcg32 &rng, const GpuRay &ray, GpuReal extinctionFactor) {
    if (g_scene.lightCount <= 0) return (GpuReal)0.0;

    int lightIdx = (int)rng.nextInt((uint32_t)g_scene.lightCount);
    const GpuLightSource &src = g_scene.lights[lightIdx];
    GpuReal intensity = evalLightIntensity(lightIdx, ray.wavelength);

    GpuReal u = rng.nextReal();
    GpuReal rv = rng.nextReal();
    GpuReal theta = (GpuReal)2.0 * GPU_PI * u;
    GpuReal z = (GpuReal)1.0 - (GpuReal)2.0 * rv;
    GpuReal sinPhi = g_sqrt(g_max((GpuReal)0.0, (GpuReal)1.0 - z * z));
    GpuVec3 lightN{sinPhi * g_cos(theta), sinPhi * g_sin(theta), z};
    GpuVec3 point = v3Add(src.center, v3Mul(src.radius, lightN));
    GpuReal randomPointPDF = (GpuReal)1.0 / ((GpuReal)4.0 * GPU_PI * src.radius * src.radius);

    GpuVec3 v = v3Neg(ray.direction);
    GpuVec3 l = v3Unit(v3Sub(point, collidePoint));
    GpuVec3 N = hit.normal;
    if (v3Dot(N, v) < (GpuReal)0.0) N = v3Neg(N);

    GpuReal roughness = g_scene.interfaces[g_scene.objects[hit.objIdx].ifaceIdx].roughness;
    GpuReal alpha = roughness * roughness;

    int dist = distinguishReflectionOrRefraction(l, v, N);
    if (dist == 0) return (GpuReal)0.0;
    bool transmission = (dist - 1) != 0;

    GpuVec3 nxtStart = fixedNextStart(collidePoint, N, transmission);
    GpuVec3 toLight = v3Sub(point, nxtStart);
    GpuReal distance = v3Len(toLight);
    if (distance < GPU_EPS) return (GpuReal)0.0;
    l = v3Mul((GpuReal)1.0 / distance, toLight);

    GpuReal BSDFTerm = evalBSDF(n1, n2, l, v, N, alpha, hit.objIdx, ray.wavelength, transmission);
    if (BSDFTerm <= (GpuReal)0.0) return (GpuReal)0.0;

    GpuRay shadowRay = GpuRay{nxtStart, l, ray.wavelength};
    if (!visibilityTest(shadowRay, distance, lightIdx)) return (GpuReal)0.0;

    GpuReal lightCos = g_abs(v3Dot(lightN, l));
    if (lightCos < GPU_EPS) return (GpuReal)0.0;

    GpuReal jacobian = (distance * distance) / lightCos;
    GpuReal pLightNEE = (randomPointPDF * jacobian) / (GpuReal)g_scene.lightCount;
    GpuReal pLightBSDF = evalPBSDF(n1, n2, hit.objIdx, l, v, N);

    GpuReal M = g_max(pLightNEE, pLightBSDF);
    if (M <= (GpuReal)0.0) return (GpuReal)0.0;
    GpuReal A = pLightNEE / M;
    GpuReal B = pLightBSDF / M;
    GpuReal weightNEE = (A * A) / (A * A + B * B);

    GpuReal NEEext =
        transmission ? ((GpuReal)4.0 * GPU_PI * n2.I / ray.wavelength * (GpuReal)1e5)
                     : extinctionFactor;
    GpuReal beers = g_exp(-NEEext * distance);

    return weightNEE * beers * intensity * BSDFTerm / pLightNEE * g_abs(v3Dot(N, l));
}

__device__ __forceinline__ GpuReal evalPNEE(const GpuRay &shadowRay, const GpuLightHit &lightHit) {
    if (lightHit.lightIdx < 0) return (GpuReal)0.0;
    const GpuLightSource &src = g_scene.lights[lightHit.lightIdx];
    GpuReal distance = lightHit.distance;
    GpuVec3 collidePoint = v3Add(shadowRay.start, v3Mul(distance, shadowRay.direction));
    GpuVec3 lightN = v3Unit(v3Sub(collidePoint, src.center));
    GpuReal cosineTerm = g_abs(v3Dot(lightN, shadowRay.direction));
    if (cosineTerm < GPU_EPS) return (GpuReal)0.0;
    GpuReal surfaceTerm = (GpuReal)1.0 / ((GpuReal)4.0 * GPU_PI * src.radius * src.radius);
    return ((GpuReal)1.0 / (GpuReal)g_scene.lightCount) * distance * distance * surfaceTerm /
           cosineTerm;
}

__device__ GpuReal tracePath(const GpuRay &initRay, Pcg32 &rng, int maxDepth) {
    GpuReal intensity = (GpuReal)0.0;
    GpuReal throughput = (GpuReal)1.0;
    GpuReal extinctionFactor = (GpuReal)0.0;

    GpuRay curRay = initRay;
    GpuComplex preN1{}, preN2{};
    int preObjIdx = -1;
    GpuVec3 preL{}, preV{}, preN{};
    bool isSpecularBounce = true;

    for (int i = 0; i < maxDepth; i++) {
        GpuHit objHit = intersectSceneObjects(curRay);
        GpuLightHit lightHit = intersectSceneLights(curRay);

        GpuReal travelingDistance = g_min(lightHit.distance, objHit.distance);
        throughput *= g_exp(-extinctionFactor * travelingDistance);

        if (!objHit.collide && !lightHit.collide) {
            return (GpuReal)0.0;
        }

        bool collideLightFirst = lightHit.collide && (lightHit.distance <= objHit.distance);
        if (collideLightFirst) {
            GpuReal sourceIntensity = evalLightIntensity(lightHit.lightIdx, curRay.wavelength);
            if (isSpecularBounce) {
                intensity += throughput * sourceIntensity;
                break;
            }
            GpuReal pNEE_BSDF = evalPNEE(curRay, lightHit);
            GpuReal pBSDF_BSDF = evalPBSDF(preN1, preN2, preObjIdx, preL, preV, preN);

            GpuReal M = g_max(pNEE_BSDF, pBSDF_BSDF);
            GpuReal weightBSDF = (GpuReal)0.0;
            if (M > (GpuReal)0.0) {
                GpuReal AM = pBSDF_BSDF / M;
                GpuReal BM = pNEE_BSDF / M;
                weightBSDF = (AM * AM) / (AM * AM + BM * BM);
            }
            intensity += throughput * weightBSDF * sourceIntensity;
            break;
        }

        GpuNextSim bsdfNxt = sampleBSDF(objHit, extinctionFactor, curRay, rng);
        if (bsdfNxt.scalingFactor < GPU_EPS) break;

        isSpecularBounce = bsdfNxt.isSpecularBounce;
        GpuComplex n1 = bsdfNxt.n1;
        GpuComplex n2 = bsdfNxt.n2;

        const GpuInterface &iface = g_scene.interfaces[g_scene.objects[objHit.objIdx].ifaceIdx];
        const GpuTexture &inTex = g_scene.textures[iface.inTexIdx];
        GpuReal alpha = iface.roughness * iface.roughness;
        bool isPureDelta = (alpha < GPU_EPS) && (texIsFullyTransparent(inTex) ||
                                                 texIsHalfTransparent(inTex) ||
                                                 texIsMetallic(inTex));

        if (!isPureDelta) {
            GpuReal NEEres =
                sampleNEE(n1, n2, objHit, bsdfNxt.collidePoint, rng, curRay, extinctionFactor);
            intensity += throughput * NEEres;
        }

        throughput *= bsdfNxt.scalingFactor;
        curRay = bsdfNxt.nxtRay;
        preN1 = n1;
        preN2 = n2;
        preObjIdx = objHit.objIdx;
        preL = bsdfNxt.l;
        preV = bsdfNxt.v;
        preN = bsdfNxt.N;

        if (i > 3 && !isSpecularBounce) {
            GpuReal chanceToLive = g_max((GpuReal)0.05, g_min((GpuReal)1.0, throughput));
            if (rng.nextReal() > chanceToLive) break;
            throughput /= chanceToLive;
        }
    }

    return intensity;
}

/* ==================== Kernels ==================== */

__global__ void renderSamplesKernel(int imgW, int imgH, int maxDepth, uint32_t seed,
                                    int sampleOffset, int batchSpp, double *accumX, double *accumY,
                                    double *accumZ, unsigned long long *counts) {
    int x = (int)(blockIdx.x * blockDim.x + threadIdx.x);
    int row = (int)(blockIdx.y * blockDim.y + threadIdx.y);
    int s = (int)(blockIdx.z * blockDim.z + threadIdx.z);
    if (x >= imgW || row >= imgH || s >= batchSpp) return;

    int y = imgH - row - 1;
    uint64_t pixelIdx = (uint64_t)row * (uint64_t)imgW + (uint64_t)x;
    uint64_t sampleIdx = (uint64_t)sampleOffset + (uint64_t)s;

    Pcg32 rng;
    rng.seed(seed, pixelIdx, sampleIdx);

    GpuReal fixedX = (GpuReal)x + rng.nextReal();
    GpuReal fixedY = (GpuReal)y + rng.nextReal();
    constexpr GpuReal intervalSize = (GpuReal)400.0;
    GpuReal lambda = rng.nextReal() * intervalSize + (GpuReal)390.0;

    GpuReal cx =
        g_lerpInterval((GpuReal)0.0, g_scene.cam.width, fixedX, g_scene.cam.startX, g_scene.cam.endX);
    GpuReal cy =
        g_lerpInterval((GpuReal)0.0, g_scene.cam.height, fixedY, g_scene.cam.startY, g_scene.cam.endY);
    GpuVec3 dir = v3Sub(GpuVec3{cx, cy, g_scene.cam.z}, g_scene.cam.start);
    GpuRay initRay = makeRay(g_scene.cam.start, dir, lambda);

    GpuReal intensityResult = tracePath(initRay, rng, maxDepth);
    if (!isfinite(intensityResult)) return;

    intensityResult = g_min(intensityResult, (GpuReal)1e7);
    GpuColorXYZ xyz = devWavelengthToXYZ(lambda);
    GpuReal scale = intensityResult * intervalSize;

    atomicAdd(&accumX[pixelIdx], (double)(scale * xyz.X));
    atomicAdd(&accumY[pixelIdx], (double)(scale * xyz.Y));
    atomicAdd(&accumZ[pixelIdx], (double)(scale * xyz.Z));
    atomicAdd(&counts[pixelIdx], 1ULL);
}

__global__ void resolvePixelsKernel(int numPixels, const double *accumX, const double *accumY,
                                    const double *accumZ, const unsigned long long *counts,
                                    ColorXYZ *meanOut, uint32_t *pixelsOut) {
    int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
    if (i >= numPixels) return;

    unsigned long long n = counts[i];
    if (n > 0) {
        double inv = 1.0 / (double)n;
        double mx = accumX[i] * inv;
        double my = accumY[i] * inv;
        double mz = accumZ[i] * inv;
        if (meanOut != nullptr) {
            meanOut[i] = ColorXYZ{(Real)mx, (Real)my, (Real)mz};
        }
        pixelsOut[i] = devXYZtoRGB(mx, my, mz);
    } else {
        if (meanOut != nullptr) {
            meanOut[i] = ColorXYZ{(Real)0.0, (Real)0.0, (Real)0.0};
        }
        pixelsOut[i] = 0U;
    }
}

/* ==================== Host Session & Entry Points ==================== */

struct GpuRenderSession {
    VirtualScreen *vs;
    GpuScene *scene;
    int width;
    int height;
    int numPixels;
    int maxDepth;
    uint32_t seed;
    int totalSamplesLaunched;
    double *d_accumX;
    double *d_accumY;
    double *d_accumZ;
    unsigned long long *d_counts;
    ColorXYZ *d_mean;
    uint32_t *d_pixels;
    uint32_t *h_pixelsTmp;
};

void gpuInitDevice(void) {
    CUDA_CHECK(cudaFree(0));
    CUDA_CHECK(cudaDeviceSetLimit(cudaLimitStackSize, 8192));
}

// copy data to gpu and flatten them
GpuRenderSession *gpuCreateSession(VirtualScreen *vs, Object **objects, LightSource **sources,
                                   Camera *camera, int maxDepth, uint32_t seed) {
    CUDA_CHECK(cudaDeviceSetLimit(cudaLimitStackSize, 8192)); // we raise the limit of stack size since SSS might need that
    GpuRenderSession *sess = new GpuRenderSession{};          // init the flattened memory in RAM
    // set the corresponding value
    sess->vs = vs;
    sess->width = getScreenWidth(vs);
    sess->height = getScreenHeight(vs);
    sess->numPixels = sess->width * sess->height;
    sess->maxDepth = maxDepth;
    sess->seed = seed;
    sess->totalSamplesLaunched = 0;
    // upload to GPU and flatten them
    sess->scene = gpuUploadScene(objects, sources, camera);
    CUDA_CHECK(cudaMemcpyToSymbol(g_scene, &sess->scene->view, sizeof(GpuSceneView)));

    // allocate memory for GPU
    size_t np = (size_t)sess->numPixels;
    CUDA_CHECK(cudaMalloc(&sess->d_accumX, np * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&sess->d_accumY, np * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&sess->d_accumZ, np * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&sess->d_counts, np * sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&sess->d_mean, np * sizeof(ColorXYZ)));
    CUDA_CHECK(cudaMalloc(&sess->d_pixels, np * sizeof(uint32_t)));
    sess->h_pixelsTmp = (uint32_t *)malloc(np * sizeof(uint32_t));

    CUDA_CHECK(cudaMemset(sess->d_accumX, 0, np * sizeof(double)));
    CUDA_CHECK(cudaMemset(sess->d_accumY, 0, np * sizeof(double)));
    CUDA_CHECK(cudaMemset(sess->d_accumZ, 0, np * sizeof(double)));
    CUDA_CHECK(cudaMemset(sess->d_counts, 0, np * sizeof(unsigned long long)));

    return sess;
}

static void launchSamples(GpuRenderSession *sess, int batchSpp) {
    static constexpr int MAX_BATCH = 128;
    int remaining = batchSpp;
    while (remaining > 0) {
        int curBatch = remaining > MAX_BATCH ? MAX_BATCH : remaining;
        dim3 block(8, 4, 4);
        dim3 grid((sess->width + 7) / 8, (sess->height + 3) / 4, (curBatch + 3) / 4);
        renderSamplesKernel<<<grid, block>>>(sess->width, sess->height, sess->maxDepth, sess->seed,
                                             sess->totalSamplesLaunched, curBatch, sess->d_accumX,
                                             sess->d_accumY, sess->d_accumZ, sess->d_counts);
        CUDA_CHECK(cudaGetLastError());
        sess->totalSamplesLaunched += curBatch;
        remaining -= curBatch;
    }
}

void gpuRenderProgressiveBatch(GpuRenderSession *sess, int batchSpp) {
    if (!sess || batchSpp <= 0 || sess->scene->view.lightCount <= 0) return;

    launchSamples(sess, batchSpp);

    int threads = 256;
    int blocks = (sess->numPixels + threads - 1) / threads;
    resolvePixelsKernel<<<blocks, threads>>>(sess->numPixels, sess->d_accumX, sess->d_accumY,
                                             sess->d_accumZ, sess->d_counts, nullptr,
                                             sess->d_pixels);
    CUDA_CHECK(cudaGetLastError());

    CUDA_CHECK(cudaMemcpy(sess->h_pixelsTmp, sess->d_pixels,
                          (size_t)sess->numPixels * sizeof(uint32_t), cudaMemcpyDeviceToHost));

    ScreenColor *dst = ptGetScreenColorBuffer(sess->vs);
    memcpy(dst, sess->h_pixelsTmp, (size_t)sess->numPixels * sizeof(uint32_t));
}

void gpuDestroySession(GpuRenderSession *sess) {
    if (!sess) return;
    cudaDeviceSynchronize();
    gpuFreeScene(sess->scene);
    cudaFree(sess->d_accumX);
    cudaFree(sess->d_accumY);
    cudaFree(sess->d_accumZ);
    cudaFree(sess->d_counts);
    cudaFree(sess->d_mean);
    cudaFree(sess->d_pixels);
    free(sess->h_pixelsTmp);
    delete sess;
}

void gpuRunFixedWorkload(VirtualScreen *vs, Object **objects, LightSource **sources, Camera *camera,
                         int maxDepth, int spp, uint32_t seed) {
    if (sources == NULL || spp <= 0) return;

    GpuRenderSession *sess = gpuCreateSession(vs, objects, sources, camera, maxDepth, seed);
    if (sess->scene->view.lightCount > 0) {
        launchSamples(sess, spp);
        CUDA_CHECK(cudaDeviceSynchronize());

        int threads = 256;
        int blocks = (sess->numPixels + threads - 1) / threads;
        resolvePixelsKernel<<<blocks, threads>>>(sess->numPixels, sess->d_accumX, sess->d_accumY,
                                                 sess->d_accumZ, sess->d_counts, sess->d_mean,
                                                 sess->d_pixels);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        size_t np = (size_t)sess->numPixels;
        CUDA_CHECK(cudaMemcpy(ptGetScreenColorBuffer(vs), sess->d_pixels, np * sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(ptGetScreenMeanBuffer(vs), sess->d_mean, np * sizeof(ColorXYZ),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(ptGetScreenRenderCountBuffer(vs), sess->d_counts,
                              np * sizeof(unsigned long long), cudaMemcpyDeviceToHost));
    }
    gpuDestroySession(sess);
}
