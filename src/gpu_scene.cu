#include "gpu_scene.cuh"
#include <algorithm>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <unordered_map>
#include <vector>

#define CUDA_CHECK(call)                                                                           \
    do {                                                                                           \
        cudaError_t err__ = (call);                                                                \
        if (err__ != cudaSuccess) {                                                                \
            fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__,                       \
                    cudaGetErrorString(err__));                                                    \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

static inline int daSize(const void *arr) { return ptGetDynamicArraySize(arr); }

static inline GpuVec3 toG3(Tuple t) {
    return GpuVec3{(GpuReal)t.x, (GpuReal)t.y, (GpuReal)t.z};
}

struct Aabb {
    GpuVec3 bmin;
    GpuVec3 bmax;

    static Aabb empty() {
        return Aabb{GpuVec3{GPU_INF, GPU_INF, GPU_INF}, GpuVec3{-GPU_INF, -GPU_INF, -GPU_INF}};
    }

    void expand(GpuVec3 p) {
        bmin.x = g_min(bmin.x, p.x);
        bmin.y = g_min(bmin.y, p.y);
        bmin.z = g_min(bmin.z, p.z);
        bmax.x = g_max(bmax.x, p.x);
        bmax.y = g_max(bmax.y, p.y);
        bmax.z = g_max(bmax.z, p.z);
    }

    void expand(const Aabb &o) {
        expand(o.bmin);
        expand(o.bmax);
    }

    void pad(GpuReal eps) {
        bmin.x -= eps;
        bmin.y -= eps;
        bmin.z -= eps;
        bmax.x += eps;
        bmax.y += eps;
        bmax.z += eps;
    }

    GpuVec3 centroid() const {
        return GpuVec3{(GpuReal)0.5 * (bmin.x + bmax.x), (GpuReal)0.5 * (bmin.y + bmax.y),
                       (GpuReal)0.5 * (bmin.z + bmax.z)};
    }

    GpuReal surfaceArea() const {
        GpuReal dx = g_max((GpuReal)0.0, bmax.x - bmin.x);
        GpuReal dy = g_max((GpuReal)0.0, bmax.y - bmin.y);
        GpuReal dz = g_max((GpuReal)0.0, bmax.z - bmin.z);
        return (GpuReal)2.0 * (dx * dy + dy * dz + dz * dx);
    }
};

struct PrimEntry {
    GpuPrim prim;
    Aabb box;
    GpuVec3 centroid;
};

static Aabb computePrimAabb(const GpuPrim &prim, const std::vector<GpuVec3> &verts3D,
                            const std::vector<GpuVec2> &verts2D) {
    Aabb box = Aabb::empty();
    if (prim.type == GPU_PRIM_TRIANGLE) {
        box.expand(prim.a);
        box.expand(prim.b);
        box.expand(prim.c);
    } else if (prim.type == GPU_PRIM_SPHERE) {
        GpuReal r = prim.b.x;
        box.expand(GpuVec3{prim.a.x - r, prim.a.y - r, prim.a.z - r});
        box.expand(GpuVec3{prim.a.x + r, prim.a.y + r, prim.a.z + r});
    } else if (prim.type == GPU_PRIM_CONVEX_POLYGON) {
        for (int i = 0; i < prim.vertCount; i++) {
            box.expand(verts3D[prim.vertOffset + i]);
        }
    } else if (prim.type == GPU_PRIM_POLYGON) {
        for (int i = 0; i < prim.vertCount; i++) {
            GpuVec2 p2 = verts2D[prim.vertOffset + i];
            GpuVec3 p = v3Add(prim.a, v3Add(v3Mul(p2.x, prim.b), v3Mul(p2.y, prim.c)));
            box.expand(p);
        }
    }
    GpuVec3 ext = v3Sub(box.bmax, box.bmin);
    GpuReal maxExt = g_max(ext.x, g_max(ext.y, ext.z));
    box.pad(g_max((GpuReal)1e-3, maxExt * (GpuReal)1e-4));
    return box;
}

template <typename ElemT>
static int buildBvhRecursive(std::vector<ElemT> &elems, int start, int end, int depth,
                             std::vector<GpuBvhNode> &nodes) {
    int nodeIdx = (int)nodes.size();
    nodes.push_back(GpuBvhNode{});

    Aabb bounds = Aabb::empty();
    Aabb centBounds = Aabb::empty();
    for (int i = start; i < end; i++) {
        bounds.expand(elems[i].box);
        centBounds.expand(elems[i].centroid);
    }

    int count = end - start;
    if (count <= 2 || depth >= 28) {
        nodes[nodeIdx] = GpuBvhNode{bounds.bmin, bounds.bmax, -1, -1, start, count};
        return nodeIdx;
    }

    GpuVec3 cExt = v3Sub(centBounds.bmax, centBounds.bmin);
    int axis = 0;
    if (cExt.y > cExt.x) axis = 1;
    if (cExt.z > (axis == 0 ? cExt.x : cExt.y)) axis = 2;

    auto getCoord = [axis](const GpuVec3 &v) -> GpuReal {
        return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
    };

    GpuReal cMin = getCoord(centBounds.bmin);
    GpuReal cMax = getCoord(centBounds.bmax);
    int mid = start + count / 2;

    if (cMax - cMin <= (GpuReal)1e-6) {
        if (count <= 4) {
            nodes[nodeIdx] = GpuBvhNode{bounds.bmin, bounds.bmax, -1, -1, start, count};
            return nodeIdx;
        }
        // Fallback midpoint partition when centroids coincide
    } else {
        static constexpr int BINS = 12;
        struct Bin {
            Aabb box = Aabb::empty();
            int count = 0;
        };
        Bin bins[BINS];
        GpuReal scale = (GpuReal)BINS / (cMax - cMin);

        for (int i = start; i < end; i++) {
            int b = (int)((getCoord(elems[i].centroid) - cMin) * scale);
            if (b < 0) b = 0;
            if (b >= BINS) b = BINS - 1;
            bins[b].count++;
            bins[b].box.expand(elems[i].box);
        }

        Aabb leftBox[BINS - 1], rightBox[BINS - 1];
        int leftCount[BINS - 1], rightCount[BINS - 1];

        Aabb curL = Aabb::empty();
        int cntL = 0;
        for (int i = 0; i < BINS - 1; i++) {
            if (bins[i].count > 0) curL.expand(bins[i].box);
            cntL += bins[i].count;
            leftBox[i] = curL;
            leftCount[i] = cntL;
        }

        Aabb curR = Aabb::empty();
        int cntR = 0;
        for (int i = BINS - 1; i > 0; i--) {
            if (bins[i].count > 0) curR.expand(bins[i].box);
            cntR += bins[i].count;
            rightBox[i - 1] = curR;
            rightCount[i - 1] = cntR;
        }

        GpuReal bestCost = GPU_INF;
        int bestSplit = -1;
        for (int i = 0; i < BINS - 1; i++) {
            if (leftCount[i] == 0 || rightCount[i] == 0) continue;
            GpuReal cost = (GpuReal)leftCount[i] * leftBox[i].surfaceArea() +
                           (GpuReal)rightCount[i] * rightBox[i].surfaceArea();
            if (cost < bestCost) {
                bestCost = cost;
                bestSplit = i;
            }
        }

        if (bestSplit >= 0) {
            GpuReal splitPos = cMin + ((GpuReal)(bestSplit + 1)) / scale;
            auto it = std::partition(elems.begin() + start, elems.begin() + end,
                                     [&](const ElemT &e) { return getCoord(e.centroid) < splitPos; });
            int splitIdx = (int)(it - elems.begin());
            if (splitIdx > start && splitIdx < end) {
                mid = splitIdx;
            } else {
                std::nth_element(elems.begin() + start, elems.begin() + mid, elems.begin() + end,
                                 [&](const ElemT &a, const ElemT &b) {
                                     return getCoord(a.centroid) < getCoord(b.centroid);
                                 });
            }
        } else {
            std::nth_element(elems.begin() + start, elems.begin() + mid, elems.begin() + end,
                             [&](const ElemT &a, const ElemT &b) {
                                 return getCoord(a.centroid) < getCoord(b.centroid);
                             });
        }
    }

    int leftChild = buildBvhRecursive(elems, start, mid, depth + 1, nodes);
    int rightChild = buildBvhRecursive(elems, mid, end, depth + 1, nodes);
    nodes[nodeIdx] = GpuBvhNode{bounds.bmin, bounds.bmax, leftChild, rightChild, 0, 0};
    return nodeIdx;
}

static void flattenShape(const Shape *shape, int objIdx, std::vector<PrimEntry> &prims,
                         std::vector<GpuVec3> &verts3D, std::vector<GpuVec2> &verts2D) {
    PtShapeKind kind = ptGetShapeKind(shape);
    if (kind == PT_SHAPE_TRIANGLE) {
        Point p1, p2, p3;
        Vector normal;
        ptGetTriangleData(shape, &p1, &p2, &p3, &normal);
        GpuPrim gp{};
        gp.type = GPU_PRIM_TRIANGLE;
        gp.objIdx = objIdx;
        gp.a = toG3(p1);
        gp.b = toG3(p2);
        gp.c = toG3(p3);
        gp.normal = toG3(normal);
        Aabb box = computePrimAabb(gp, verts3D, verts2D);
        prims.push_back(PrimEntry{gp, box, box.centroid()});
    } else if (kind == PT_SHAPE_SPHERE) {
        Point center;
        Real radius;
        ptGetSphereData(shape, &center, &radius);
        GpuPrim gp{};
        gp.type = GPU_PRIM_SPHERE;
        gp.objIdx = objIdx;
        gp.a = toG3(center);
        gp.b = GpuVec3{(GpuReal)radius, 0, 0};
        Aabb box = computePrimAabb(gp, verts3D, verts2D);
        prims.push_back(PrimEntry{gp, box, box.centroid()});
    } else if (kind == PT_SHAPE_CONVEX_POLYGON) {
        const Point *verts = nullptr;
        int count = 0;
        Vector normal;
        ptGetConvexPolygonData(shape, &verts, &count, &normal);
        int offset = (int)verts3D.size();
        for (int i = 0; i < count; i++) {
            verts3D.push_back(toG3(verts[i]));
        }
        GpuPrim gp{};
        gp.type = GPU_PRIM_CONVEX_POLYGON;
        gp.objIdx = objIdx;
        gp.normal = toG3(normal);
        gp.vertOffset = offset;
        gp.vertCount = count;
        Aabb box = computePrimAabb(gp, verts3D, verts2D);
        prims.push_back(PrimEntry{gp, box, box.centroid()});
    } else if (kind == PT_SHAPE_POLYGON) {
        const Real *v2d = nullptr;
        int count = 0;
        Point p0;
        Vector normal, axisI, axisJ;
        ptGetPolygonData(shape, &v2d, &count, &p0, &normal, &axisI, &axisJ);
        int offset = (int)verts2D.size();
        for (int i = 0; i < count; i++) {
            verts2D.push_back(GpuVec2{(GpuReal)v2d[2 * i], (GpuReal)v2d[2 * i + 1]});
        }
        GpuPrim gp{};
        gp.type = GPU_PRIM_POLYGON;
        gp.objIdx = objIdx;
        gp.a = toG3(p0);
        gp.b = toG3(axisI);
        gp.c = toG3(axisJ);
        gp.normal = toG3(normal);
        gp.vertOffset = offset;
        gp.vertCount = count;
        Aabb box = computePrimAabb(gp, verts3D, verts2D);
        prims.push_back(PrimEntry{gp, box, box.centroid()});
    } else if (kind == PT_SHAPE_GROUP) {
        Shape *const *elements = nullptr;
        int count = 0;
        ptGetGroupData(shape, &elements, &count);
        for (int i = 0; i < count; i++) {
            flattenShape(elements[i], objIdx, prims, verts3D, verts2D);
        }
    } else {
        fprintf(stderr, "Unsupported shape kind in GPU scene upload\n");
        exit(1);
    }
}

template <typename T>
static void *uploadVector(const std::vector<T> &vec) {
    if (vec.empty()) return nullptr;
    void *d_ptr = nullptr;
    CUDA_CHECK(cudaMalloc(&d_ptr, vec.size() * sizeof(T)));
    CUDA_CHECK(cudaMemcpy(d_ptr, vec.data(), vec.size() * sizeof(T), cudaMemcpyHostToDevice));
    return d_ptr;
}

static void convertComplexArray(const Complex *src, int count, std::vector<GpuComplex> &dst) {
    dst.resize(count);
    for (int i = 0; i < count; i++) {
        dst[i] = GpuComplex{(GpuReal)src[i].R, (GpuReal)src[i].I};
    }
}

GpuScene *gpuUploadScene(Object **objects, LightSource **sources, Camera *camera) {
    GpuScene *scene = new GpuScene{};

    // 1. Camera
    Real cw, ch, sx, ex, sy, ey, cz;
    Point cstart;
    if (!ptGetRegularCameraParams(camera, &cw, &ch, &sx, &ex, &sy, &ey, &cz, &cstart)) {
        fprintf(stderr, "GPU backend currently requires a regular camera (newRegularCamera)\n");
        exit(1);
    }
    scene->view.cam = GpuCamera{(GpuReal)cw, (GpuReal)ch, (GpuReal)sx, (GpuReal)ex,
                                (GpuReal)sy, (GpuReal)ey, (GpuReal)cz, toG3(cstart)};

    // 2. Textures & Interfaces deduplication + custom spectral LUTs
    std::vector<GpuTexture> h_textures;
    std::vector<GpuInterface> h_interfaces;
    std::vector<GpuReal> h_customLuts;
    std::unordered_map<const Texture *, int> texMap;
    std::unordered_map<const Interface *, int> ifaceMap;

    auto addTexture = [&](const Texture *tex) -> int {
        auto it = texMap.find(tex);
        if (it != texMap.end()) return it->second;

        GpuTexture gt{};
        gt.tags = ptGetTextureTags(tex);
        gt.refrKind = (int)ptGetTextureRefrKind(tex);
        gt.baseKind = (int)ptGetTextureBaseColorKind(tex);
        gt.sigmaKind = (int)ptGetTextureSigmaSKind(tex);
        gt.phaseKind = (int)ptGetTexturePhaseKind(tex);
        gt.concentration = (GpuReal)ptGetTextureConcentration(tex);
        gt.refrLutOffset = -1;
        gt.baseLutOffset = -1;
        gt.sigmaLutOffset = -1;

        if (gt.refrKind == PT_REFR_CUSTOM) {
            gt.refrLutOffset = (int)h_customLuts.size();
            for (int k = 0; k < GPU_LUT_SAMPLES; k++) {
                Real lambda = (Real)GPU_LUT_MIN_LAMBDA + (Real)k * (Real)GPU_LUT_STEP;
                Complex c = ptEvalTextureRefractiveIndex(tex, lambda);
                h_customLuts.push_back((GpuReal)c.R);
                h_customLuts.push_back((GpuReal)c.I);
            }
        }
        if ((gt.tags & 0x6U) == 0x4U && !(gt.tags & 0x1U) && gt.baseKind == PT_BASE_CUSTOM) {
            gt.baseLutOffset = (int)h_customLuts.size();
            for (int k = 0; k < GPU_LUT_SAMPLES; k++) {
                Real lambda = (Real)GPU_LUT_MIN_LAMBDA + (Real)k * (Real)GPU_LUT_STEP;
                h_customLuts.push_back((GpuReal)ptEvalTextureBaseColor(tex, lambda));
            }
        }
        if ((gt.tags & 0x6U) == 0x6U && gt.sigmaKind == PT_SIGMA_CUSTOM) {
            gt.sigmaLutOffset = (int)h_customLuts.size();
            for (int k = 0; k < GPU_LUT_SAMPLES; k++) {
                Real lambda = (Real)GPU_LUT_MIN_LAMBDA + (Real)k * (Real)GPU_LUT_STEP;
                h_customLuts.push_back((GpuReal)ptEvalTextureSigmaS(tex, lambda));
            }
        }
        if ((gt.tags & 0x6U) == 0x6U && gt.phaseKind == PT_PHASE_CUSTOM) {
            fprintf(stderr, "Unsupported custom phase function in half-transparent texture\n");
            exit(1);
        }

        int idx = (int)h_textures.size();
        h_textures.push_back(gt);
        texMap[tex] = idx;
        return idx;
    };

    auto addInterface = [&](const Interface *iface) -> int {
        auto it = ifaceMap.find(iface);
        if (it != ifaceMap.end()) return it->second;

        const Texture *inTex = nullptr, *outTex = nullptr;
        Real roughness = 0;
        ptGetInterfaceParts(iface, &inTex, &outTex, &roughness);

        GpuInterface gi{};
        gi.inTexIdx = addTexture(inTex);
        gi.outTexIdx = addTexture(outTex);
        gi.roughness = (GpuReal)roughness;

        int idx = (int)h_interfaces.size();
        h_interfaces.push_back(gi);
        ifaceMap[iface] = idx;
        return idx;
    };

    // 3. Objects, flattened primitives, per-object BLAS, and TLAS
    int objectCount = daSize(objects);
    std::vector<PrimEntry> h_primEntries;
    std::vector<GpuVec3> h_verts3D;
    std::vector<GpuVec2> h_verts2D;
    std::vector<GpuBvhNode> h_blasNodes;
    std::vector<GpuObject> h_objects(objectCount);

    struct TlasElem {
        int objIdx;
        Aabb box;
        GpuVec3 centroid;
    };
    std::vector<TlasElem> tlasElems;

    for (int i = 0; i < objectCount; i++) {
        const Object *obj = objects[i];
        int ifaceIdx = addInterface(ptGetObjectInterface(obj));
        int primStart = (int)h_primEntries.size();
        flattenShape(ptGetObjectShape(obj), i, h_primEntries, h_verts3D, h_verts2D);
        int primEnd = (int)h_primEntries.size();

        int blasRoot = -1;
        if (primEnd > primStart) {
            blasRoot = buildBvhRecursive(h_primEntries, primStart, primEnd, 0, h_blasNodes);
            const GpuBvhNode &rootNode = h_blasNodes[blasRoot];
            Aabb objBox{rootNode.bmin, rootNode.bmax};
            tlasElems.push_back(TlasElem{i, objBox, objBox.centroid()});
        }
        h_objects[i] = GpuObject{blasRoot, ifaceIdx};
    }

    std::vector<GpuPrim> h_prims(h_primEntries.size());
    for (size_t i = 0; i < h_primEntries.size(); i++) {
        h_prims[i] = h_primEntries[i].prim;
    }

    std::vector<GpuBvhNode> h_tlasNodes;
    std::vector<int> h_tlasObjIndices;
    int tlasRoot = -1;
    if (!tlasElems.empty()) {
        tlasRoot = buildBvhRecursive(tlasElems, 0, (int)tlasElems.size(), 0, h_tlasNodes);
        h_tlasObjIndices.resize(tlasElems.size());
        for (size_t i = 0; i < tlasElems.size(); i++) {
            h_tlasObjIndices[i] = tlasElems[i].objIdx;
        }
    }

    // 4. Light sources + custom light spectrum LUTs
    int lightCount = daSize(sources);
    std::vector<GpuLightSource> h_lights(lightCount);
    for (int i = 0; i < lightCount; i++) {
        const LightSource *src = sources[i];
        if (ptGetShapeKind(src->shape) != PT_SHAPE_SPHERE) {
            fprintf(stderr, "LightSource shape must be Sphere\n");
            exit(1);
        }
        Point center;
        Real radius;
        ptGetSphereData(src->shape, &center, &radius);

        GpuLightSource gl{};
        gl.center = toG3(center);
        gl.radius = (GpuReal)radius;
        gl.lightKind = (int)ptGetLightKind(src->intensity);
        gl.lutOffset = -1;
        if (gl.lightKind == PT_LIGHT_CUSTOM) {
            gl.lutOffset = (int)h_customLuts.size();
            for (int k = 0; k < GPU_LUT_SAMPLES; k++) {
                Real lambda = (Real)GPU_LUT_MIN_LAMBDA + (Real)k * (Real)GPU_LUT_STEP;
                h_customLuts.push_back((GpuReal)src->intensity(lambda));
            }
        }
        h_lights[i] = gl;
    }

    // 5. Static spectral tables
    const Complex *agSrc, *auSrc, *cuSrc, *feSrc, *glassSrc, *sapphireSrc;
    int agCount, auCount, cuCount, feCount, glassCount, sapphireCount;
    ptGetTextureStaticTables(&agSrc, &agCount, &auSrc, &auCount, &cuSrc, &cuCount, &feSrc,
                             &feCount, &glassSrc, &glassCount, &sapphireSrc, &sapphireCount);

    std::vector<GpuComplex> h_ag, h_au, h_cu, h_fe, h_glass, h_sapphire;
    convertComplexArray(agSrc, agCount, h_ag);
    convertComplexArray(auSrc, auCount, h_au);
    convertComplexArray(cuSrc, cuCount, h_cu);
    convertComplexArray(feSrc, feCount, h_fe);
    convertComplexArray(glassSrc, glassCount, h_glass);
    convertComplexArray(sapphireSrc, sapphireCount, h_sapphire);

    int xyzCount = 0;
    const ColorXYZ *xyzSrc = ptGetWavelengthToXYZTable(&xyzCount);
    std::vector<GpuColorXYZ> h_xyz(xyzCount);
    for (int i = 0; i < xyzCount; i++) {
        h_xyz[i] = GpuColorXYZ{(GpuReal)xyzSrc[i].X, (GpuReal)xyzSrc[i].Y, (GpuReal)xyzSrc[i].Z};
    }

    // 6. Upload buffers to device
    scene->d_prims = uploadVector(h_prims);
    scene->d_blasNodes = uploadVector(h_blasNodes);
    scene->d_tlasNodes = uploadVector(h_tlasNodes);
    scene->d_tlasObjIndices = uploadVector(h_tlasObjIndices);
    scene->d_objects = uploadVector(h_objects);
    scene->d_interfaces = uploadVector(h_interfaces);
    scene->d_textures = uploadVector(h_textures);
    scene->d_lights = uploadVector(h_lights);
    scene->d_polyVerts3D = uploadVector(h_verts3D);
    scene->d_polyVerts2D = uploadVector(h_verts2D);
    scene->d_customLuts = uploadVector(h_customLuts);
    scene->d_agEta = uploadVector(h_ag);
    scene->d_auEta = uploadVector(h_au);
    scene->d_cuEta = uploadVector(h_cu);
    scene->d_feEta = uploadVector(h_fe);
    scene->d_glassEta = uploadVector(h_glass);
    scene->d_sapphireEC = uploadVector(h_sapphire);
    scene->d_xyzTable = uploadVector(h_xyz);

    scene->view.prims = (const GpuPrim *)scene->d_prims;
    scene->view.blasNodes = (const GpuBvhNode *)scene->d_blasNodes;
    scene->view.tlasNodes = (const GpuBvhNode *)scene->d_tlasNodes;
    scene->view.tlasObjIndices = (const int *)scene->d_tlasObjIndices;
    scene->view.tlasRoot = tlasRoot;
    scene->view.objects = (const GpuObject *)scene->d_objects;
    scene->view.objectCount = objectCount;
    scene->view.interfaces = (const GpuInterface *)scene->d_interfaces;
    scene->view.textures = (const GpuTexture *)scene->d_textures;
    scene->view.lights = (const GpuLightSource *)scene->d_lights;
    scene->view.lightCount = lightCount;
    scene->view.polyVerts3D = (const GpuVec3 *)scene->d_polyVerts3D;
    scene->view.polyVerts2D = (const GpuVec2 *)scene->d_polyVerts2D;
    scene->view.customLuts = (const GpuReal *)scene->d_customLuts;
    scene->view.agEta = (const GpuComplex *)scene->d_agEta;
    scene->view.auEta = (const GpuComplex *)scene->d_auEta;
    scene->view.cuEta = (const GpuComplex *)scene->d_cuEta;
    scene->view.feEta = (const GpuComplex *)scene->d_feEta;
    scene->view.glassEta = (const GpuComplex *)scene->d_glassEta;
    scene->view.sapphireEC = (const GpuComplex *)scene->d_sapphireEC;
    scene->view.agCount = agCount;
    scene->view.auCount = auCount;
    scene->view.cuCount = cuCount;
    scene->view.feCount = feCount;
    scene->view.glassCount = glassCount;
    scene->view.sapphireCount = sapphireCount;
    scene->view.xyzTable = (const GpuColorXYZ *)scene->d_xyzTable;
    scene->view.xyzCount = xyzCount;

    return scene;
}

void gpuFreeScene(GpuScene *scene) {
    if (!scene) return;
    cudaFree(scene->d_prims);
    cudaFree(scene->d_blasNodes);
    cudaFree(scene->d_tlasNodes);
    cudaFree(scene->d_tlasObjIndices);
    cudaFree(scene->d_objects);
    cudaFree(scene->d_interfaces);
    cudaFree(scene->d_textures);
    cudaFree(scene->d_lights);
    cudaFree(scene->d_polyVerts3D);
    cudaFree(scene->d_polyVerts2D);
    cudaFree(scene->d_customLuts);
    cudaFree(scene->d_agEta);
    cudaFree(scene->d_auEta);
    cudaFree(scene->d_cuEta);
    cudaFree(scene->d_feEta);
    cudaFree(scene->d_glassEta);
    cudaFree(scene->d_sapphireEC);
    cudaFree(scene->d_xyzTable);
    delete scene;
}
