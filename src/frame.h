#ifndef FRAME_H 
#define FRAME_H 
#include "shapes.h"
#include "transform.h"

typedef struct Frame Frame;

Frame *newFrame(const char *path);

void destroyFrame(Frame *frame);

// NULL if every face has at least 3 vertexes that exist, otherwise a description of the problem
const char *frameError(Frame *frame);

Shape *newGroupFromFrame(Frame *m, Transform t, void *transformPara);
#endif
