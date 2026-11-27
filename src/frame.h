#ifndef FRAME_H 
#define FRAME_H 
#include "shapes.h"
#include "transform.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Frame Frame;

Frame *newFrame(const char *path);

void destroyFrame(Frame *frame);

Shape *newGroupFromFrame(Frame *m, Transform t, void *transformPara);

#ifdef __cplusplus
}
#endif

#endif
