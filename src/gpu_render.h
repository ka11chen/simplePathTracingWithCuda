#ifndef GPU_RENDER_H
#define GPU_RENDER_H

#include "camera.h"
#include "lightSource.h"
#include "object.h"
#include "render.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GpuRenderSession GpuRenderSession;

void gpuInitDevice(void);

void gpuRunFixedWorkload(VirtualScreen *vs, Object **objects, LightSource **sources, Camera *camera,
                         int maxDepth, int spp, uint32_t seed);

GpuRenderSession *gpuCreateSession(VirtualScreen *vs, Object **objects, LightSource **sources,
                                   Camera *camera, int maxDepth, uint32_t seed);

void gpuRenderProgressiveBatch(GpuRenderSession *session, int batchSpp);

void gpuDestroySession(GpuRenderSession *session);

#ifdef __cplusplus
}
#endif

#endif
