#ifndef GPU_SCENE_CUH
#define GPU_SCENE_CUH

#include "gpu_common.cuh"
#include "scene_internal.h"

static constexpr int GPU_LUT_SAMPLES = 801;
static constexpr GpuReal GPU_LUT_MIN_LAMBDA = (GpuReal)390.0;
static constexpr GpuReal GPU_LUT_MAX_LAMBDA = (GpuReal)790.0;
static constexpr GpuReal GPU_LUT_STEP = (GpuReal)0.5;

enum GpuPrimType {
    GPU_PRIM_TRIANGLE = 0,
    GPU_PRIM_SPHERE = 1,
    GPU_PRIM_CONVEX_POLYGON = 2,
    GPU_PRIM_POLYGON = 3
};

struct GpuPrim {
    int type;
    int objIdx;
    GpuVec3 a, b, c;
    GpuVec3 normal;
    int vertOffset;
    int vertCount;
};

struct GpuBvhNode {
    GpuVec3 bmin;
    GpuVec3 bmax;
    int left;
    int right;
    int primOffset;
    int primCount;
};

struct GpuObject {
    int blasRoot;
    int ifaceIdx;
};

struct GpuTexture {
    uint32_t tags;
    int refrKind;
    int baseKind;
    int sigmaKind;
    int phaseKind;
    GpuReal concentration;
    int refrLutOffset;
    int baseLutOffset;
    int sigmaLutOffset;
};

struct GpuInterface {
    int inTexIdx;
    int outTexIdx;
    GpuReal roughness;
};

struct GpuLightSource {
    GpuVec3 center;
    GpuReal radius;
    int lightKind;
    int lutOffset;
};

struct GpuCamera {
    GpuReal width, height;
    GpuReal startX, endX;
    GpuReal startY, endY;
    GpuReal z;
    GpuVec3 start;
};

struct GpuSceneView {
    GpuCamera cam;
    const GpuPrim *prims;
    const GpuBvhNode *blasNodes;
    const GpuBvhNode *tlasNodes;
    const int *tlasObjIndices;
    int tlasRoot;
    const GpuObject *objects;
    int objectCount;
    const GpuInterface *interfaces;
    const GpuTexture *textures;
    const GpuLightSource *lights;
    int lightCount;
    const GpuVec3 *polyVerts3D;
    const GpuVec2 *polyVerts2D;
    const GpuReal *customLuts;
    const GpuComplex *agEta;
    const GpuComplex *auEta;
    const GpuComplex *cuEta;
    const GpuComplex *feEta;
    const GpuComplex *glassEta;
    const GpuComplex *sapphireEC;
    int agCount, auCount, cuCount, feCount, glassCount, sapphireCount;
    const GpuColorXYZ *xyzTable;
    int xyzCount;
};

struct GpuScene {
    GpuSceneView view;
    void *d_prims;
    void *d_blasNodes;
    void *d_tlasNodes;
    void *d_tlasObjIndices;
    void *d_objects;
    void *d_interfaces;
    void *d_textures;
    void *d_lights;
    void *d_polyVerts3D;
    void *d_polyVerts2D;
    void *d_customLuts;
    void *d_agEta;
    void *d_auEta;
    void *d_cuEta;
    void *d_feEta;
    void *d_glassEta;
    void *d_sapphireEC;
    void *d_xyzTable;
};

GpuScene *gpuUploadScene(Object **objects, LightSource **sources, Camera *camera);
void gpuFreeScene(GpuScene *scene);

#endif
