#include "scene.h"
#include "dynamicArray.h"
#include "frame.h"
#include "transform.h"
#include <ctype.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * @brief Scene file loader. Reads the line-based format described in SCENE_FORMAT.md and builds
 * the objects, light sources and camera the renderer needs.
 */

#define MAX_NAME 64

typedef struct {
    const char *path;
    int line;
} Context;

typedef struct {
    char *key, *value;
} Option;

typedef struct {
    char name[MAX_NAME];
    void *item; // Texture * or Interface *
    bool isSapphire;
} NamedItem;

static void fail(const Context *ctx, const char *format, ...) {
    va_list args;
    if (ctx->line > 0)
        fprintf(stderr, "%s:%d: ", ctx->path, ctx->line);
    else
        fprintf(stderr, "%s: ", ctx->path);
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
    exit(1);
}

// ---------- parsing helpers ----------

static Real parseReal(const Context *ctx, const char *token, const char *what) {
    char *end;
    Real value = strtod(token, &end);
    if (end == token || *end != '\0' || !isfinite(value))
        fail(ctx, "%s: '%s' is not a number", what, token);
    return value;
}

static int parsePositiveInt(const Context *ctx, const char *token, const char *what) {
    char *end;
    long value = strtol(token, &end, 10);
    if (end == token || *end != '\0' || value <= 0 || value > 100000)
        fail(ctx, "%s: '%s' is not a positive integer", what, token);
    return (int)value;
}

// "x,y,z" -> Vector
static Vector parseVector(const Context *ctx, const char *token, const char *what) {
    char buffer[256];
    if (strlen(token) >= sizeof(buffer)) fail(ctx, "%s: value too long", what);
    strcpy(buffer, token);
    Real v[3];
    char *saveptr = NULL;
    char *part = strtok_r(buffer, ",", &saveptr);
    for (int i = 0; i < 3; i++) {
        if (part == NULL) fail(ctx, "%s: expected 3 comma-separated numbers, got '%s'", what, token);
        v[i] = parseReal(ctx, part, what);
        part = strtok_r(NULL, ",", &saveptr);
    }
    if (part != NULL) fail(ctx, "%s: expected 3 comma-separated numbers, got '%s'", what, token);
    return (Vector){v[0], v[1], v[2]};
}

static bool isValidName(const char *name) {
    if (*name == '\0' || strlen(name) >= MAX_NAME) return false;
    for (const char *c = name; *c; c++)
        if (!isalnum((unsigned char)*c) && *c != '_') return false;
    return true;
}

static void checkName(const Context *ctx, const char *name) {
    if (!isValidName(name))
        fail(ctx, "invalid name '%s' (use letters, digits and '_', at most %d characters)", name,
             MAX_NAME - 1);
}

static NamedItem *findNamed(NamedItem *items, const char *name) {
    for (int i = 0; i < getSize(items); i++)
        if (!strcmp(items[i].name, name)) return &items[i];
    return NULL;
}

// Every option must be one of `valid` (NULL-terminated) and appear at most once.
static void checkOptions(const Context *ctx, const char *directive, Option *options,
                         const char *const *valid) {
    for (int i = 0; i < getSize(options); i++) {
        bool known = false;
        for (int j = 0; valid[j] != NULL; j++)
            if (!strcmp(options[i].key, valid[j])) known = true;
        if (!known) {
            char list[256] = "";
            for (int j = 0; valid[j] != NULL; j++) {
                if (j > 0) strncat(list, ", ", sizeof(list) - strlen(list) - 1);
                strncat(list, valid[j], sizeof(list) - strlen(list) - 1);
            }
            if (valid[0] == NULL)
                fail(ctx, "'%s' takes no options, got '%s'", directive, options[i].key);
            fail(ctx, "unknown option '%s' for '%s' (valid: %s)", options[i].key, directive, list);
        }
        for (int j = 0; j < i; j++)
            if (!strcmp(options[i].key, options[j].key))
                fail(ctx, "option '%s' given twice", options[i].key);
    }
}

static const char *getOption(Option *options, const char *key) {
    for (int i = 0; i < getSize(options); i++)
        if (!strcmp(options[i].key, key)) return options[i].value;
    return NULL;
}

static void expectArgs(const Context *ctx, const char *directive, int got, int expected,
                       const char *usage) {
    if (got != expected)
        fail(ctx, "'%s' needs %d values, got %d (usage: %s)", directive, expected, got, usage);
}

// positional args [first, count) must be groups of 3 numbers; returns a dynamic array of points
static Point *parsePoints(const Context *ctx, const char *directive, char **args, int first,
                          int count, int minPoints) {
    int numbers = count - first;
    if (numbers % 3 != 0)
        fail(ctx, "'%s' needs points as groups of 3 numbers (x y z), got %d numbers", directive,
             numbers);
    if (numbers / 3 < minPoints)
        fail(ctx, "'%s' needs at least %d points, got %d", directive, minPoints, numbers / 3);
    Point *points = newDynamicArray(0, Point);
    for (int i = first; i < count; i += 3) {
        Point p = {parseReal(ctx, args[i], "x"), parseReal(ctx, args[i + 1], "y"),
                   parseReal(ctx, args[i + 2], "z")};
        pushBack(&points, p, Point);
    }
    return points;
}

// ---------- materials ----------

typedef struct {
    const char *name;
    Texture *(*make)(void);
} MaterialPreset;

static const MaterialPreset presets[] = {
    {"air", newAir},           {"glass", newGlass},     {"diamond", newDiamond},
    {"whitePlastic", newWhitePlastic},                  {"gold", newGold},
    {"silver", newSilver},     {"copper", newCopper},   {"iron", newIron},
    {"marble", newMarble},     {"pinkMarble", newPinkMarble},
    {"aerogel", newAerogel},
};

static Texture *makeMaterial(const Context *ctx, const char *preset, const char *concentration,
                             bool *isSapphire) {
    *isSapphire = !strcmp(preset, "sapphire");
    if (*isSapphire) {
        if (concentration == NULL)
            fail(ctx, "'sapphire' needs concentration=<value> (suggested 1e-3 to 1e-2)");
        Real c = parseReal(ctx, concentration, "concentration");
        if (c < 0) fail(ctx, "concentration must not be negative");
        return newSapphire(c);
    }
    if (concentration != NULL) fail(ctx, "only 'sapphire' takes concentration=");
    for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); i++)
        if (!strcmp(preset, presets[i].name)) return presets[i].make();
    fail(ctx,
         "unknown material '%s' (valid: air, glass, diamond, sapphire, whitePlastic, gold, "
         "silver, copper, iron, marble, pinkMarble, aerogel)",
         preset);
    return NULL;
}

// ---------- loader ----------

typedef struct {
    Scene *scene;
    NamedItem *materials;
    NamedItem *interfaces;
    bool haveResolution, haveCamera;
    int width, height;
    Real camera[6]; // startX endX startY endY z depth
} Loader;

static Interface *lookupInterface(const Context *ctx, Loader *L, const char *name) {
    NamedItem *item = findNamed(L->interfaces, name);
    if (item == NULL) fail(ctx, "unknown interface '%s' (define it with 'interface' first)", name);
    return item->item;
}

static void addObject(Loader *L, Shape *shape, Interface *interface) {
    pushBack(&L->scene->shapes, shape, Shape *);
    Object *obj = newObject(shape, interface);
    pushBack(&L->scene->objects, obj, Object *);
}

static void handleLine(const Context *ctx, Loader *L, char **args, int n, Option *options) {
    const char *d = args[0];
    int argc = n - 1; // positional values after the directive

    if (!strcmp(d, "resolution")) {
        static const char *const valid[] = {NULL};
        checkOptions(ctx, d, options, valid);
        if (L->haveResolution) fail(ctx, "'resolution' given twice");
        expectArgs(ctx, d, argc, 2, "resolution <width> <height>");
        L->width = parsePositiveInt(ctx, args[1], "width");
        L->height = parsePositiveInt(ctx, args[2], "height");
        L->haveResolution = true;
    }
    else if (!strcmp(d, "camera")) {
        static const char *const valid[] = {NULL};
        checkOptions(ctx, d, options, valid);
        if (L->haveCamera) fail(ctx, "'camera' given twice");
        expectArgs(ctx, d, argc, 6, "camera <startX> <endX> <startY> <endY> <z> <depth>");
        static const char *const names[] = {"startX", "endX", "startY", "endY", "z", "depth"};
        for (int i = 0; i < 6; i++) L->camera[i] = parseReal(ctx, args[i + 1], names[i]);
        if (L->camera[0] == L->camera[1] || L->camera[2] == L->camera[3])
            fail(ctx, "the camera sensor has zero width or height");
        if (L->camera[5] == 0) fail(ctx, "camera depth must not be 0");
        L->haveCamera = true;
    }
    else if (!strcmp(d, "material")) {
        static const char *const valid[] = {"concentration", NULL};
        checkOptions(ctx, d, options, valid);
        expectArgs(ctx, d, argc, 2, "material <name> <preset> [concentration=<c>]");
        checkName(ctx, args[1]);
        if (findNamed(L->materials, args[1])) fail(ctx, "material '%s' defined twice", args[1]);
        NamedItem item = {{0}, NULL, false};
        strcpy(item.name, args[1]);
        item.item = makeMaterial(ctx, args[2], getOption(options, "concentration"),
                                 &item.isSapphire);
        pushBack(&L->materials, item, NamedItem);
        pushBack(&L->scene->textures, (Texture *)item.item, Texture *);
    }
    else if (!strcmp(d, "interface")) {
        static const char *const valid[] = {"roughness", NULL};
        checkOptions(ctx, d, options, valid);
        expectArgs(ctx, d, argc, 3, "interface <name> <inside> <outside> roughness=<r>");
        checkName(ctx, args[1]);
        if (findNamed(L->interfaces, args[1])) fail(ctx, "interface '%s' defined twice", args[1]);
        NamedItem *in = findNamed(L->materials, args[2]);
        NamedItem *out = findNamed(L->materials, args[3]);
        if (in == NULL) fail(ctx, "unknown material '%s' (define it with 'material' first)", args[2]);
        if (out == NULL) fail(ctx, "unknown material '%s' (define it with 'material' first)", args[3]);
        const char *r = getOption(options, "roughness");
        if (r == NULL) fail(ctx, "'interface' needs roughness=<0..1>");
        Real roughness = parseReal(ctx, r, "roughness");
        if (roughness < 0 || roughness > 1) fail(ctx, "roughness must be between 0 and 1");
        NamedItem item = {{0}, NULL, false};
        strcpy(item.name, args[1]);
        item.item = newInterface(in->item, out->item, roughness);
        pushBack(&L->interfaces, item, NamedItem);
        pushBack(&L->scene->interfaces, (Interface *)item.item, Interface *);
    }
    else if (!strcmp(d, "sphere")) {
        static const char *const valid[] = {NULL};
        checkOptions(ctx, d, options, valid);
        expectArgs(ctx, d, argc, 5, "sphere <interface> <cx> <cy> <cz> <radius>");
        Interface *interface = lookupInterface(ctx, L, args[1]);
        Point c = {parseReal(ctx, args[2], "cx"), parseReal(ctx, args[3], "cy"),
                   parseReal(ctx, args[4], "cz")};
        Real radius = parseReal(ctx, args[5], "radius");
        if (radius <= 0) fail(ctx, "radius must be positive");
        addObject(L, newSphere(c, radius), interface);
    }
    else if (!strcmp(d, "triangle")) {
        static const char *const valid[] = {NULL};
        checkOptions(ctx, d, options, valid);
        expectArgs(ctx, d, argc, 10, "triangle <interface> <x1 y1 z1> <x2 y2 z2> <x3 y3 z3>");
        Interface *interface = lookupInterface(ctx, L, args[1]);
        Point *p = parsePoints(ctx, d, args, 2, n, 3);
        addObject(L, newTriangle(p[0], p[1], p[2]), interface);
        freeDynamicArray(p);
    }
    else if (!strcmp(d, "convex") || !strcmp(d, "polygon")) {
        static const char *const valid[] = {NULL};
        checkOptions(ctx, d, options, valid);
        if (argc < 1) fail(ctx, "'%s' needs an interface and at least 3 points", d);
        Interface *interface = lookupInterface(ctx, L, args[1]);
        Point *p = parsePoints(ctx, d, args, 2, n, 3);
        Shape *shape = !strcmp(d, "convex") ? newConvexPolygon(p) : newPolygon(p);
        addObject(L, shape, interface);
        freeDynamicArray(p); // both constructors copy the vertexes
    }
    else if (!strcmp(d, "mesh")) {
        static const char *const valid[] = {"scale", "rotate", "at", NULL};
        checkOptions(ctx, d, options, valid);
        expectArgs(ctx, d, argc, 2,
                   "mesh <interface> <file.obj> [scale=<s>] [rotate=<rx>,<ry>,<rz>] [at=<x>,<y>,<z>]");
        Interface *interface = lookupInterface(ctx, L, args[1]);
        const char *s = getOption(options, "scale");
        const char *rot = getOption(options, "rotate");
        const char *at = getOption(options, "at");
        Real scale = s ? parseReal(ctx, s, "scale") : 1;
        if (scale <= 0) fail(ctx, "scale must be positive");
        Vector rotation = rot ? parseVector(ctx, rot, "rotate") : (Vector){0, 0, 0};
        Vector position = at ? parseVector(ctx, at, "at") : (Vector){0, 0, 0};

        FILE *check = fopen(args[2], "r"); // newFrame exits without a line number
        if (check == NULL)
            fail(ctx, "cannot open '%s' (paths are relative to the project root)", args[2]);
        fclose(check);
        Frame *frame = newFrame(args[2]);
        const char *problem = frameError(frame);
        if (problem != NULL) fail(ctx, "%s: %s", args[2], problem);

        RegularTransformPara *para =
            newRegularTransformPara(scale, rotation.x, rotation.y, rotation.z, position);
        addObject(L, newGroupFromFrame(frame, regularTransform, para), interface);
        destroyRegulartransformPara(para);
        destroyFrame(frame); // the group keeps its own copy of the vertexes
    }
    else if (!strcmp(d, "light")) {
        static const char *const valid[] = {"blackbody", "scale", NULL};
        checkOptions(ctx, d, options, valid);
        expectArgs(ctx, d, argc, 4, "light <cx> <cy> <cz> <radius> blackbody=<T> [scale=<k>]");
        Point c = {parseReal(ctx, args[1], "cx"), parseReal(ctx, args[2], "cy"),
                   parseReal(ctx, args[3], "cz")};
        Real radius = parseReal(ctx, args[4], "radius");
        if (radius <= 0) fail(ctx, "radius must be positive");
        const char *T = getOption(options, "blackbody");
        if (T == NULL) fail(ctx, "'light' needs blackbody=<temperature in K>");
        Real temperature = parseReal(ctx, T, "blackbody");
        if (temperature <= 0) fail(ctx, "blackbody temperature must be positive");
        const char *k = getOption(options, "scale");
        Real lightScale = k ? parseReal(ctx, k, "scale") : 1;
        if (lightScale <= 0) fail(ctx, "scale must be positive");

        Shape *sphere = newSphere(c, radius);
        pushBack(&L->scene->shapes, sphere, Shape *);
        LightSource *light = malloc(sizeof(*light));
        if (light == NULL) fail(ctx, "out of memory");
        *light = newBlackbodyLightSource(sphere, temperature, lightScale);
        pushBack(&L->scene->sources, light, LightSource *);
    }
    else {
        fail(ctx,
             "unknown directive '%s' (valid: resolution, camera, material, interface, sphere, "
             "triangle, convex, polygon, mesh, light)",
             d);
    }
}

Scene *loadScene(const char *path, int overrideWidth, int overrideHeight) {
    Context ctx = {path, 0};
    FILE *f = fopen(path, "r");
    if (f == NULL) fail(&ctx, "cannot open scene file");

    Scene *scene = calloc(1, sizeof(*scene));
    if (scene == NULL) fail(&ctx, "out of memory");
    scene->objects = newDynamicArray(0, Object *);
    scene->sources = newDynamicArray(0, LightSource *);
    scene->textures = newDynamicArray(0, Texture *);
    scene->interfaces = newDynamicArray(0, Interface *);
    scene->shapes = newDynamicArray(0, Shape *);

    Loader L = {0};
    L.scene = scene;
    L.materials = newDynamicArray(0, NamedItem);
    L.interfaces = newDynamicArray(0, NamedItem);

    char *buffer = NULL;
    size_t bufferSize = 0;
    bool sawHeader = false;
    char **args = newDynamicArray(0, char *);
    Option *options = newDynamicArray(0, Option);

    while (getline(&buffer, &bufferSize, f) != -1) {
        ctx.line++;
        char *comment = strchr(buffer, '#');
        if (comment != NULL) *comment = '\0';

        resize(&args, 0, char *);
        resize(&options, 0, Option);
        char *saveptr = NULL;
        for (char *tok = strtok_r(buffer, " \t\r\n", &saveptr); tok != NULL;
             tok = strtok_r(NULL, " \t\r\n", &saveptr)) {
            char *eq = strchr(tok, '=');
            if (eq == NULL) {
                if (getSize(options) > 0)
                    fail(&ctx, "'%s' comes after an option; put key=value options last", tok);
                pushBack(&args, tok, char *);
            }
            else {
                if (getSize(args) == 0) fail(&ctx, "a line cannot start with an option ('%s')", tok);
                *eq = '\0';
                if (*tok == '\0' || eq[1] == '\0') fail(&ctx, "option needs the form key=value");
                Option option = {tok, eq + 1};
                pushBack(&options, option, Option);
            }
        }
        if (getSize(args) == 0) continue; // empty line or comment only

        if (!sawHeader) {
            if (strcmp(args[0], "pathtracer-scene") != 0 || getSize(args) != 2 ||
                getSize(options) != 0)
                fail(&ctx, "the first line must be 'pathtracer-scene 1'");
            if (strcmp(args[1], "1") != 0)
                fail(&ctx, "unsupported scene format version '%s' (this program reads version 1)",
                     args[1]);
            sawHeader = true;
            continue;
        }
        if (!strcmp(args[0], "pathtracer-scene")) fail(&ctx, "'pathtracer-scene' given twice");
        handleLine(&ctx, &L, args, getSize(args), options);
    }
    free(buffer);
    fclose(f);
    freeDynamicArray(args);
    freeDynamicArray(options);

    ctx.line = 0; // the checks below are about the whole file
    if (!sawHeader) fail(&ctx, "empty scene file (the first line must be 'pathtracer-scene 1')");
    if (!L.haveResolution) fail(&ctx, "missing 'resolution'");
    if (!L.haveCamera) fail(&ctx, "missing 'camera'");
    if (getSize(scene->sources) == 0) fail(&ctx, "the scene needs at least one 'light'");

    scene->width = overrideWidth > 0 ? overrideWidth : L.width;
    scene->height = overrideHeight > 0 ? overrideHeight : L.height;

    // the camera maps the whole image onto the sensor rectangle, so a different aspect ratio
    // stretches the picture
    Real sensorAspect = fabs((L.camera[1] - L.camera[0]) / (L.camera[3] - L.camera[2]));
    Real imageAspect = (Real)scene->width / scene->height;
    if (fabs(sensorAspect - imageAspect) > 1e-3 * sensorAspect)
        fprintf(stderr,
                "warning: %s: image aspect ratio %d:%d (%.4f) differs from the camera sensor "
                "(%.4f); the picture will be stretched\n",
                path, scene->width, scene->height, imageAspect, sensorAspect);

    scene->camera = newRegularCamera(scene->width, scene->height, L.camera[0], L.camera[1],
                                     L.camera[2], L.camera[3], L.camera[4], L.camera[5]);

    freeDynamicArray(L.materials);
    freeDynamicArray(L.interfaces);
    return scene;
}

void destroyScene(Scene *scene) {
    for (int i = 0; i < getSize(scene->objects); i++) destroyObject(scene->objects[i]);
    for (int i = 0; i < getSize(scene->sources); i++) free(scene->sources[i]);
    for (int i = 0; i < getSize(scene->shapes); i++) destroyShape(scene->shapes[i]);
    for (int i = 0; i < getSize(scene->interfaces); i++) destroyInterface(scene->interfaces[i]);
    for (int i = 0; i < getSize(scene->textures); i++) destroyTexture(scene->textures[i]);
    freeDynamicArray(scene->objects);
    freeDynamicArray(scene->sources);
    freeDynamicArray(scene->shapes);
    freeDynamicArray(scene->interfaces);
    freeDynamicArray(scene->textures);
    destroyRegularCamera(scene->camera);
    free(scene);
}
