#include "multithreads.h"
#include "gpu_render.h"
#include "render.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * @author seaofvoices
 * @brief Manages GPU rendering sessions for progressive display and fixed-workload benchmarks.
 */

typedef struct Multithreads {
    pthread_t driverThread;
    GpuRenderSession *session;
    atomic_int exit;
} Multithreads;

static void *gpuDriverWorker(void *para) {
    Multithreads *mul = (Multithreads *)para;
    static const int progressiveBatchSpp = 4;
    while (atomic_load(&mul->exit) == 0) {
        gpuRenderProgressiveBatch(mul->session, progressiveBatchSpp);
    }
    return NULL;
}

Multithreads *initMultithreads(VirtualScreen *vs, int threadCount, Object **objects,
                               LightSource **sources, Camera *camera, int maxDepth) {
    (void)threadCount;
    Multithreads *mul = malloc(sizeof(Multithreads));
    if (mul == NULL) {
        fprintf(stderr, "malloc Multithreads failed\n");
        exit(1);
    }
    atomic_init(&mul->exit, 0);
    mul->session = gpuCreateSession(vs, objects, sources, camera, maxDepth, 19650218U);
    if (pthread_create(&mul->driverThread, NULL, gpuDriverWorker, mul) != 0) {
        fprintf(stderr, "pthread_create gpuDriverWorker failed\n");
        gpuDestroySession(mul->session);
        free(mul);
        exit(1);
    }
    return mul;
}

void destroyMultithreads(Multithreads *mul) {
    if (mul == NULL) return;
    atomic_store(&mul->exit, 1);
    pthread_join(mul->driverThread, NULL);
    gpuDestroySession(mul->session);
    free(mul);
}

void runFixedWorkload(VirtualScreen *vs, int threadCount, Object **objects, LightSource **sources,
                      Camera *camera, int maxDepth, int spp, uint32_t seed) {
    (void)threadCount;
    gpuRunFixedWorkload(vs, objects, sources, camera, maxDepth, spp, seed);
}
