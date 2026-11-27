#ifndef CAMERA_H
#define CAMERA_H
#include "base.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Camera Camera;

Camera *newRegularCamera(int width, int height, Real startX, Real endX, Real startY, Real endY,
                         Real z, Real depth);

void destroyRegularCamera(Camera *camera);

ReversedRay getInitRay(Camera *camera, Real x, Real y, Real wavelength);

#ifdef __cplusplus
}
#endif

#endif