#include "frame.h"
#include "base.h"
#include "dynamicArray.h"
#include "transform.h"
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * @author seaofvoices
 * @brief This file provides methods to convert the object files into frame first, then
 * one can convert frames into real groups of shapes. Only supports that of composed of convex
 * polygons
 */

typedef int *Face;

typedef struct Frame {
    Point *vertexes;
    Face *faces;
} Frame;

Frame *newFrame(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        printf("Open file %s failed\n", path);
        exit(1);
    }

    Frame *frame = malloc(sizeof(*frame));
    frame->faces = newDynamicArray(0, Face);
    frame->vertexes = newDynamicArray(0, Point);

    char *buffer = NULL;
    size_t bufferSize = 0;

    while (getline(&buffer, &bufferSize, f) != -1) {
        // split the line
        char *saveptr = NULL;
        static const char dim[] = " ";
        char *firstTok = strtok_r(buffer, dim, &saveptr);

        if (!strcmp(firstTok, "v")) { // first case: this line represent a vertex
            Point p;
            sscanf(buffer + 2, REAL_FMT REAL_FMT REAL_FMT, &p.x, &p.y,
                   &p.z); // skip the "v " at the start
            pushBack(&frame->vertexes, p, Point);
        }

        else if (!strcmp(firstTok, "f")) { // second case: this line represent a face
            bool lineEnd = false;
            Face f = newDynamicArray(0, int);
            while (!lineEnd) {
                char *token = strtok_r(NULL, dim, &saveptr);
                if (!token) {
                    lineEnd = true;
                    break;
                }
                // "a", "a/b", "a//c" and "a/b/c" all start with the vertex number a; tokens that
                // are not numbers (e.g. a trailing newline after a space) are skipped
                int vertexNumber;
                if (sscanf(token, "%d", &vertexNumber) != 1) continue;
                pushBack(&f,
                         vertexNumber - 1, // in obj files they are 1-based but we need 0-based here
                         int);
            }
            pushBack(&frame->faces, f, Face);
        }
    }

    free(buffer);
    fclose(f);
    return frame;
}

const char *frameError(Frame *frame) {
    static char message[160];
    int vertexCount = getSize(frame->vertexes);
    int faceCount = getSize(frame->faces);
    if (faceCount == 0) return "the file has no faces";
    for (int i = 0; i < faceCount; i++) {
        int n = getSize(frame->faces[i]);
        if (n < 3) {
            snprintf(message, sizeof(message), "face %d has %d vertexes, needs at least 3", i + 1, n);
            return message;
        }
        for (int j = 0; j < n; j++) {
            int v = frame->faces[i][j];
            if (v < 0 || v >= vertexCount) {
                snprintf(message, sizeof(message),
                         "face %d uses vertex %d, but the file has %d vertexes", i + 1, v + 1,
                         vertexCount);
                return message;
            }
        }
    }
    return NULL;
}

void destroyFrame(Frame *frame) {
    freeDynamicArray(frame->vertexes);
    for (int i = 0; i < getSize(frame->faces); i++) freeDynamicArray(frame->faces[i]);
    freeDynamicArray(frame->faces);
    free(frame);
}

Shape *newGroupFromFrame(Frame *m, Transform t, void *para) {
    Shape **shapes = newDynamicArray(0, Shape *);
    int faceCount = getSize(m->faces);
    for (int i = 0; i < faceCount; i++) {
        int vertexesCount = getSize(m->faces[i]);
        Point *vertexes = newDynamicArray(0, Point);
        for (int j = 0; j < vertexesCount; j++) {
            int vertexNumber = m->faces[i][j];
            Point p = m->vertexes[vertexNumber];
            p = t(p, para);
            pushBack(&vertexes, p, Point);
        }
        if (getSize(vertexes) > 3) {
            Shape *p = newPolygon(vertexes);
            pushBack(&shapes, p, Shape *);
        }
        else {
            Shape *tri = newTriangle(vertexes[0], vertexes[1], vertexes[2]);
            pushBack(&shapes, tri, Shape *);
        }
        freeDynamicArray(vertexes);
    }
    Shape *group = newGroup(shapes);
    freeDynamicArray(shapes); // newGroup keeps its own copy of the array
    return group;
}