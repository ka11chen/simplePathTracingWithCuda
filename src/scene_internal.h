#ifndef SCENE_INTERNAL_H
#define SCENE_INTERNAL_H

#include "base.h"
#include "camera.h"
#include "lightSource.h"
#include "object.h"
#include "shapes.h"
#include "textures.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VirtualScreen VirtualScreen;

typedef enum {
    PT_SHAPE_UNKNOWN = 0,
    PT_SHAPE_TRIANGLE,
    PT_SHAPE_SPHERE,
    PT_SHAPE_CONVEX_POLYGON,
    PT_SHAPE_POLYGON,
    PT_SHAPE_GROUP
} PtShapeKind;

typedef enum {
    PT_REFR_CUSTOM = 0,
    PT_REFR_AIR,
    PT_REFR_PLASTIC,
    PT_REFR_AEROGEL,
    PT_REFR_MARBLE,
    PT_REFR_PINK_MARBLE,
    PT_REFR_DIAMOND,
    PT_REFR_SAPPHIRE,
    PT_REFR_SILVER,
    PT_REFR_GOLD,
    PT_REFR_COPPER,
    PT_REFR_IRON,
    PT_REFR_GLASS
} PtRefrKind;

typedef enum {
    PT_BASE_CUSTOM = 0,
    PT_BASE_WHITE,
    PT_BASE_BLACK,
    PT_BASE_RED
} PtBaseColorKind;

typedef enum {
    PT_SIGMA_CUSTOM = 0,
    PT_SIGMA_MARBLE,
    PT_SIGMA_PINK_MARBLE,
    PT_SIGMA_AEROGEL
} PtSigmaSKind;

typedef enum {
    PT_PHASE_CUSTOM = 0,
    PT_PHASE_HG_MARBLE,
    PT_PHASE_RAYLEIGH
} PtPhaseKind;

typedef enum {
    PT_LIGHT_CUSTOM = 0,
    PT_LIGHT_TUNGSTEN,
    PT_LIGHT_SUNLIGHT,
    PT_LIGHT_WHITE
} PtLightKind;

/* Camera inspection */
bool ptGetRegularCameraParams(const Camera *cam, Real *width, Real *height, Real *startX,
                              Real *endX, Real *startY, Real *endY, Real *z, Point *start);

/* Shape inspection */
PtShapeKind ptGetShapeKind(const Shape *shape);
void ptGetTriangleData(const Shape *shape, Point *p1, Point *p2, Point *p3, Vector *normal);
void ptGetSphereData(const Shape *shape, Point *center, Real *radius);
void ptGetConvexPolygonData(const Shape *shape, const Point **vertexes, int *count, Vector *normal);
void ptGetPolygonData(const Shape *shape, const Real **vertexes2D, int *count, Point *p0,
                      Vector *normal, Vector *axisI, Vector *axisJ);
void ptGetGroupData(const Shape *shape, Shape *const **elements, int *count);

/* Object & Interface & Texture inspection */
const Shape *ptGetObjectShape(const Object *obj);
const Interface *ptGetObjectInterface(const Object *obj);
void ptGetInterfaceParts(const Interface *iface, const Texture **inTex, const Texture **outTex,
                         Real *roughness);
uint32_t ptGetTextureTags(const Texture *tex);
PtRefrKind ptGetTextureRefrKind(const Texture *tex);
Real ptGetTextureConcentration(const Texture *tex);
Complex ptEvalTextureRefractiveIndex(const Texture *tex, Real lambda);
PtBaseColorKind ptGetTextureBaseColorKind(const Texture *tex);
Real ptEvalTextureBaseColor(const Texture *tex, Real lambda);
PtSigmaSKind ptGetTextureSigmaSKind(const Texture *tex);
Real ptEvalTextureSigmaS(const Texture *tex, Real lambda);
PtPhaseKind ptGetTexturePhaseKind(const Texture *tex);

void ptGetTextureStaticTables(const Complex **agEta, int *agCount, const Complex **auEta,
                              int *auCount, const Complex **cuEta, int *cuCount,
                              const Complex **feEta, int *feCount, const Complex **glassEta,
                              int *glassCount, const Complex **sapphireEC, int *sapphireCount);

/* LightSource inspection */
PtLightKind ptGetLightKind(LightIntensity (*fn)(Real));
const ColorXYZ *ptGetWavelengthToXYZTable(int *count);

/* VirtualScreen direct buffer access */
ScreenColor *ptGetScreenColorBuffer(VirtualScreen *vs);
ColorXYZ *ptGetScreenMeanBuffer(VirtualScreen *vs);
unsigned long long *ptGetScreenRenderCountBuffer(VirtualScreen *vs);
int ptGetDynamicArraySize(const void *arr);

#ifdef __cplusplus
}
#endif

#endif
