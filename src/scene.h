#ifndef SCENE_H
#define SCENE_H
#include "camera.h"
#include "lightSource.h"
#include "object.h"
#include "shapes.h"
#include "textures.h"

/*
 * A scene loaded from a scene file. The format is described in SCENE_FORMAT.md.
 */
typedef struct Scene {
    int width, height;     // output resolution
    Camera *camera;
    Object **objects;      // dynamic array, in file order
    LightSource **sources; // dynamic array, in file order

    // resources owned by the scene, released by destroyScene
    Texture **textures;
    Interface **interfaces;
    Shape **shapes;
} Scene;

// Load a scene file. overrideWidth / overrideHeight > 0 replace the resolution in the file.
// On any error, prints "<path>:<line>: <message>" to stderr and exits with status 1.
Scene *loadScene(const char *path, int overrideWidth, int overrideHeight);

void destroyScene(Scene *scene);

#endif
