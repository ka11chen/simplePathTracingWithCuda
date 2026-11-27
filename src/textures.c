#include "textures.h"
#include "base.h"
#include "random.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/*
 * @author: seaofvoices
 * @date: 2026/08/10 20:56
 * @brief: this file provides definition and example of textures, where refractive data mainly from
 * https://refractiveindex.info and lerped by lerp.py. Some data of gems comes from
 * http://minerals.gps.caltech.edu/FILES/Index.html
 */

/*
 * 1st bit: metallic
 * 2nd bit: transparent
 * 3rd bit: opaque
 */
typedef enum {
    DIELETRIC = 0x0U,
    METALLIC = 0x1U,
    FULLY_TRANSPARENT = 0x2U,
    OPAQUE = 0x4U,
    HALF_TRANSPARENT = 0x6U
} TextureAttributes;

typedef struct Texture {
    Complex (*refractiveIndex)(Texture *self, Real lambda);
    TextureAttributes tags;
    void *data; // for those data that are not common for all textures
} Texture;

typedef struct Interface {
    Texture *in, *out;
    Real roughness;
} Interface;

static void mallocFailed() {
    fprintf(stderr, "malloc tex failed\n");
    exit(1);
}

// to make sure the data of diffrent textures won't confuse anyone we have to seperate the original
// "newTexture" into different functions
Texture *newOpaqueDieletric(Complex (*refractiveIndex)(Texture *, Real), Real (*baseColor)(Real)) {
    Texture *tex = malloc(sizeof(*tex));
    if (tex == NULL) {
        mallocFailed();
    }

    *tex = (Texture){refractiveIndex, DIELETRIC | OPAQUE, baseColor};
    return tex;
}

Texture *newTransparentDieletric(Complex (*refractiveIndex)(Texture *, Real), Real concentration) {
    Texture *tex = malloc(sizeof(*tex));
    if (tex == NULL) {
        mallocFailed();
    }

    *tex = (Texture){refractiveIndex, DIELETRIC | FULLY_TRANSPARENT};
    tex->data = malloc(sizeof(Real));
    if (tex->data == NULL) {
        mallocFailed();
    }
    *(Real *)(tex->data) = concentration;
    return tex;
}

Texture *newMetal(Complex (*refractiveIndex)(Texture *, Real)) {
    Texture *tex = malloc(sizeof(*tex));
    if (tex == NULL) {
        mallocFailed();
    }
    *tex = (Texture){refractiveIndex, METALLIC | OPAQUE, NULL};
    return tex;
}

typedef struct {
    Real (*sigmaS)(Real);
    Vector (*sampleNextDirection)(Vector,
                                  MT19937 *); // sample next direction through phase function
} HalfTransparentTextureData;

Texture *newHalfTransparentDieletric(Complex (*refractiveIndex)(Texture *, Real),
                                     Real (*sigmaS)(Real),
                                     Vector (*sampleNextDirection)(Vector, MT19937 *)) {
    Texture *tex = malloc(sizeof(*tex));
    if (tex == NULL) mallocFailed();
    HalfTransparentTextureData *data = malloc(sizeof(*data));
    if (data == NULL) mallocFailed();
    data->sampleNextDirection = sampleNextDirection;
    data->sigmaS = sigmaS;
    *tex = (Texture){refractiveIndex, DIELETRIC | HALF_TRANSPARENT, data};
    return tex;
}

Vector sampleHenyeyGreenstein(Vector input, MT19937 *mt, Real g) {
    Real u = randomReal(mt), v = randomReal(mt);
    Real theta = 2 * M_PI * u;

    Real cosPhi;
    if (rabs(g) < error) {
        cosPhi = 1 - 2 * v;
    }
    else {
        Real g2 = g * g;
        Real temp = (1 - g2) / (1 + g - 2 * g * v);
        cosPhi = (1 + g2 - temp * temp) / (2 * g);
    }
    Real sinPhi = rsqrt_(rmax(1 - cosPhi * cosPhi, 0.0));
    Vector local = {rcos(theta) * sinPhi, rsin(theta) * sinPhi, cosPhi};

    return toWorld(local, input);
}

Vector sampleRayleighScatteringNextDirection(Vector input, MT19937 *mt) {
    Real v = 2 - 4 * randomReal(mt);
    Real t = rcbrt(v + rsqrt_(v * v + 1));
    Real cosPhi = t - (1 / t);
    Real sinPhi = rsqrt_(rmax(1 - cosPhi * cosPhi, 0));

    Real theta = 2 * M_PI * randomReal(mt);

    Vector local = {rcos(theta) * sinPhi, rsin(theta) * sinPhi, cosPhi};

    return toWorld(local, input);
}

typedef struct {
    Complex *eta;
    int n;
    const char *pathN;
    const char *pathK;
    const Real lambdaStep;
} RefIndex;

static RefIndex Ag = {
    .pathN = "src/static/ag_n.csv",
    .pathK = "src/static/ag_k.csv",
    .lambdaStep = 1
};

static RefIndex Au = {
    .pathN = "src/static/au_n.csv",
    .pathK = "src/static/au_k.csv",
    .lambdaStep = 10
};

static RefIndex Cu = {
    .pathN = "src/static/cu_n.csv",
    .pathK = "src/static/cu_k.csv",
    .lambdaStep = 10
};

static RefIndex Fe = {
    .pathN = "src/static/fe_n.csv",
    .pathK = "src/static/fe_k.csv",
    .lambdaStep = 10
};
static RefIndex Glass = {
    .pathN = "src/static/glass_n.csv",
    .pathK = "src/static/glass_k.csv",
    .lambdaStep = 10
};

static const Real startLambda = 390;

static void dataFileError(const char *path, const char *reason) {
    fprintf(stderr, "Failed to read %s: %s (run the program from the project root)\n", path,
            reason);
    exit(1);
}

static FILE *openDataFile(const char *path, int *lineCount) {
    FILE *f = fopen(path, "r");
    if (f == NULL) dataFileError(path, "cannot open file");
    if (fscanf(f, "%d", lineCount) != 1) dataFileError(path, "missing line count");
    return f;
}

static void readFile(RefIndex *src) {
    if (src->eta != NULL) return;

    int lineCount;
    FILE *fN = openDataFile(src->pathN, &lineCount);
    src->n = lineCount;
    src->eta = malloc(lineCount * sizeof(*src->eta));
    if (src->eta == NULL) {
        mallocFailed();
    }

    for (int i = 0; i < lineCount; i++) {
        Real lambda = 0;
        if (fscanf(fN, REAL_FMT "," REAL_FMT, &lambda, &src->eta[i].R) != 2)
            dataFileError(src->pathN, "malformed line");
    }
    fclose(fN);

    int lineCountK;
    FILE *fK = openDataFile(src->pathK, &lineCountK);
    if (lineCount != lineCountK) {
        fprintf(stderr, "Files %s and %s have unmatched line counts", src->pathN, src->pathK);
        exit(1);
    }

    for (int i = 0; i < lineCount; i++) {
        Real lambda = 0;
        if (fscanf(fK, REAL_FMT "," REAL_FMT, &lambda, &src->eta[i].I) != 2) {
            dataFileError(src->pathK, "malformed line");
        }
    }
    fclose(fK);
    return;
}

// let real part of EC be E perp C and the imaginary part be E para C since I want to reuse the code
// of "getRefractivity" function
static Complex *EC;
static int SAPPHIRE_LINE_COUNT;
static const char SAPPHIRE_PATH[] = "src/static/sapphire_epsilon.csv";
static const Real SAPPHIRE_STEP = 10;

// since no direct k can be directly used by sapphire, we need a different way to read the epsilon
static void readSapphireEpsilon() {
    if (EC != NULL) return;

    int lineCount = 0;
    FILE *f = openDataFile(SAPPHIRE_PATH, &lineCount);
    SAPPHIRE_LINE_COUNT = lineCount;
    EC = malloc(lineCount * sizeof(*EC));
    if (EC == NULL) {
        mallocFailed();
    }

    for (int i = 0; i < lineCount; i++) {
        Real lambda;
        if (fscanf(f, REAL_FMT "," REAL_FMT "," REAL_FMT, &lambda, &EC[i].R, &EC[i].I) != 3)
            dataFileError(SAPPHIRE_PATH, "malformed line");
    }

    fclose(f);
    return;
}

void initTexture() {
    readFile(&Ag);
    readFile(&Au);
    readFile(&Cu);
    readFile(&Fe);
    readFile(&Glass);
    readSapphireEpsilon();
}

Real pureWhite(Real _) { return 0.8; }

Real pureBlack(Real _) { return 0; }

Real red(Real lambda) { return 0.05 + 0.75 / (1 + rexp(-0.06 * (lambda - 650))); }

Complex getPlasticRefractivity(Texture *__, Real _) { return (Complex){1.5, 0.0}; }

Complex getAirRefractivity(Texture *__, Real _) { return (Complex){1.0, 0}; };

Complex getAerogelRefractivity(Texture *__, Real _) { return (Complex){1.01, 1e-7}; };

Complex getMarbleRefractivity(Texture *_, Real lambda) {
    lambda /= 1000;
    Real lambda2 = lambda * lambda;

    static const Real a = 0.73358749;
    static const Real b = 0.96464345;
    static const Real c = 1.94325203e-2;
    static const Real d = 1.82831454;
    static const Real e = 120;

    Real n = rsqrt_(a + ((b * lambda2) / (lambda2 - c)) + ((d * lambda2) / (lambda2 - e)));
    static const Real k = 6e-6;

    return (Complex){n, k};
}

// Mie scattering
Vector sampleMarbleNextDirection(Vector input, MT19937 *mt) {
    return sampleHenyeyGreenstein(input, mt, 0.9);
}

static inline Real getPinkMarbleK(Real lambda) {
    if (lambda < 470.0) {
        return 6e-6;
    }
    else if (lambda < 530.0) {
        Real t = (lambda - 470.0) / (530.0 - 470.0);
        return lerp(6e-6, 8.0e-6, t);
    }
    else if (lambda < 650.0) {
        Real t = (lambda - 530.0) / (650.0 - 530.0);
        return lerp(8.0e-6, 2.0e-6, t);
    }
    else {
        return 2.0e-6;
    }
}

static Real getMarbleSigmaS(Real lambda) { return 0.2; }

static Real getAerogelSigmaS(Real lambda) {
    static const Real sigma550 = 4e-3;
    static const Real lambda0 = 550;

    Real rLambda = lambda0 / lambda;
    Real rLambda2 = rLambda * rLambda;
    Real rLambda4 = rLambda2 * rLambda2;

    return sigma550 * rLambda4;
}

Complex getPinkMarbleRefractivity(Texture *_, Real lambda) {
    Real k = getPinkMarbleK(lambda);

    lambda /= 1000;
    Real lambda2 = lambda * lambda;

    static const Real a = 0.73358749;
    static const Real b = 0.96464345;
    static const Real c = 1.94325203e-2;
    static const Real d = 1.82831454;
    static const Real e = 120;

    Real n = rsqrt_(a + ((b * lambda2) / (lambda2 - c)) + ((d * lambda2) / (lambda2 - e)));

    return (Complex){n, k};
}

// get refractivity from tables above
Complex getRefractivity(Real lambda, Complex eta[], Real lambdaStep, int lineCount) {
    if (lambda < startLambda) return (Complex){0, 0};
    if (lambda > startLambda + lineCount * lambdaStep) return (Complex){0, 0};
    int slot = (lambda - startLambda) / lambdaStep;
    if (slot < 0) return (Complex){0, 0};
    if (slot + 1 >= lineCount) return (Complex){0, 0};
    int preLambda = startLambda + lambdaStep * slot;
    int nxtLambda = startLambda + lambdaStep * (slot + 1);
    return (Complex){lerpInterval(preLambda, nxtLambda, lambda, eta[slot].R, eta[slot + 1].R),
                     lerpInterval(preLambda, nxtLambda, lambda, eta[slot].I, eta[slot + 1].I)};
}

Complex getSilverRefractivity(Texture *_, Real lambda) {
    return getRefractivity(lambda, Ag.eta, Ag.lambdaStep, Ag.n);
}

Complex getGoldRefractivity(Texture *_, Real lambda) {
    return getRefractivity(lambda, Au.eta, Au.lambdaStep, Au.n);
}

Complex getCopperRefractivity(Texture *_, Real lambda) {
    return getRefractivity(lambda, Cu.eta, Cu.lambdaStep, Cu.n);
}

Complex getIronRefractivity(Texture *_, Real lambda) {
    return getRefractivity(lambda, Fe.eta, Fe.lambdaStep, Fe.n);
}

Complex getGlassRefractivity(Texture *_, Real lambda) {
    return getRefractivity(lambda, Glass.eta, Glass.lambdaStep, Glass.n);
}

Complex getDiamondRefractivity(Texture *_, Real x) {
    x /= 1000;
    return (Complex){
        rsqrt_(1 + 0.3306 / (1 - pow(0.1750 / x, 2)) + 4.3356 / (1 - pow(0.1060 / x, 2))), 0};
}

Complex getSapphireRefractivity(Texture *self, Real lambda) {
    // little trick: let function getRefractivity lerp and edge check for me
    Complex eCombined = getRefractivity(lambda, EC, SAPPHIRE_STEP, SAPPHIRE_LINE_COUNT);

    lambda /= 1000; // convert lambda from nanometer to micrometer
    // calculate the n part
    static const Real a = 1.5039759;
    static const Real b = 0.0740288;
    static const Real c = 0.55069141;
    static const Real d = 0.1216529;
    static const Real e = 6.5927379;
    static const Real f = 20.072248;
    Real lambda2 = lambda * lambda;
    Real nterm1 = a * lambda2 / (lambda2 - b * b);
    Real nterm2 = c * lambda2 / (lambda2 - d * d);
    Real nterm3 = e * lambda2 / (lambda2 - f * f);
    Real n = rsqrt_(1 + nterm1 + nterm2 + nterm3);
    // calcuate the k part
    Real EperpC = eCombined.R;
    Real EparaC = eCombined.I;

    Real epsilon = (EperpC + EparaC) / 2;
    Real concentration = *(Real *)self->data;
    Real alpha = rlog(10) * epsilon * concentration * 1e-4; // convert alpha to micrometer^(-1)
    Real k = alpha * lambda / (4 * M_PI);

    return (Complex){n, k};
}

// texture examples
Texture *newAir() { return newTransparentDieletric(getAirRefractivity, 0); }

Texture *newWhitePlastic() {
    return newOpaqueDieletric(getPlasticRefractivity, pureWhite);
}

Texture *newSapphire(Real concentration) {
    return newTransparentDieletric(getSapphireRefractivity, concentration);
}

Texture *newGold() { return newMetal(getGoldRefractivity); }

Texture *newSilver() { return newMetal(getSilverRefractivity); }

Texture *newCopper() { return newMetal(getCopperRefractivity); }

Texture *newIron() { return newMetal(getIronRefractivity); }

Texture *newGlass() {
    // for glass we don't care about its color (it has a fixed extinction coefficient), so
    // concentration remains 0
    return newTransparentDieletric(getGlassRefractivity, 0);
}

Texture *newDiamond() {
    // for the same reason as glass, so concentration remains 0
    return newTransparentDieletric(getDiamondRefractivity, 0);
}

Texture *newMarble() {
    return newHalfTransparentDieletric(getMarbleRefractivity, getMarbleSigmaS,
                                       sampleMarbleNextDirection);
}

Real getPinkMarbleSigmaS(Real lambda) {
    if (lambda < 470.0) {
        return 0.21;
    }
    else if (lambda < 530.0) {
        Real t = (lambda - 470.0) / (530.0 - 470.0);
        return lerp(0.21, 0.22, t);
    }
    else if (lambda < 650.0) {
        Real t = (lambda - 530.0) / (650.0 - 530.0);
        return lerp(0.22, 0.20, t);
    }
    else {
        return 0.20;
    }
}

Texture *newPinkMarble() {
    return newHalfTransparentDieletric(getPinkMarbleRefractivity, getPinkMarbleSigmaS,
                                       sampleMarbleNextDirection);
}

Texture *newAerogel() {
    return newHalfTransparentDieletric(getAerogelRefractivity, getAerogelSigmaS,
                                       sampleRayleighScatteringNextDirection);
}

// Wrappers
static inline Real getTextureBaseColor(Texture *texture, Real lambda) {
    Real (*baseColor)(Real) = texture->data;
    return baseColor(lambda);
}

Real getInterfaceInsideBaseColor(Interface *interface, Real lambda) {
    return getTextureBaseColor(interface->in, lambda);
}

Real getInterfaceOutsideBaseColor(Interface *interface, Real lambda) {
    return getTextureBaseColor(interface->out, lambda);
}

static inline Real getTextureSigmaS(Texture *texture, Real lambda) {
    HalfTransparentTextureData *data = texture->data;
    return data->sigmaS(lambda);
}

Real getInterfaceInsideSigmaS(Interface *interface, Real lambda) {
    return getTextureSigmaS(interface->in, lambda);
}

Real getInterfaceOutsideSigmaS(Interface *interface, Real lambda) {
    return getTextureSigmaS(interface->out, lambda);
}

static inline Vector sampleTextureNextDirection(Texture *texture, Vector currentDirection,
                                                MT19937 *mt) {
    HalfTransparentTextureData *data = texture->data;
    return data->sampleNextDirection(currentDirection, mt);
}

Vector sampleInterfaceInsideNextDirection(Interface *interface, Vector currentDirection,
                                          MT19937 *mt) {
    return sampleTextureNextDirection(interface->in, currentDirection, mt);
}

Vector sampleInterfaceOutsideNextDirection(Interface *interface, Vector currentDirection,
                                           MT19937 *mt) {
    return sampleTextureNextDirection(interface->out, currentDirection, mt);
}

static inline Complex getTextureRefractiveIndex(Texture *texture, Real lambda) {
    return texture->refractiveIndex(texture, lambda);
}

Complex getInterfaceInsideRefractiveIndex(Interface *interface, Real lambda) {
    return getTextureRefractiveIndex(interface->in, lambda);
}

Complex getInterfaceOutsideRefractiveIndex(Interface *interface, Real lambda) {
    return getTextureRefractiveIndex(interface->out, lambda);
}

static inline bool isTextureMetallic(Texture *texture) { return texture->tags & METALLIC; }

bool isInterfaceInsideMetallic(Interface *interface) { return isTextureMetallic(interface->in); }

bool isInterfaceOutsideMetallic(Interface *interface) { return isTextureMetallic(interface->out); }

static inline bool isTextureTransparent(Texture *texture) {
    return texture->tags & FULLY_TRANSPARENT;
}

bool isInterfaceInsideTransparent(Interface *interface) {
    return isTextureTransparent(interface->in);
}

bool isInterfaceOutsideTransparent(Interface *interface) {
    return isTextureTransparent(interface->out);
}

static inline bool isTextureFullyTransparent(Texture *texture) {
    static const uint32_t transparent_mask = HALF_TRANSPARENT;
    return (texture->tags & transparent_mask) == FULLY_TRANSPARENT;
}

bool isInterfaceInsideFullyTransparent(Interface *interface) {
    return isTextureFullyTransparent(interface->in);
}

bool isInterfaceOutsideFullyTransparent(Interface *interface) {
    return isTextureFullyTransparent(interface->out);
}

static inline bool isTextureHalfTransparent(Texture *texture) {
    return (texture->tags & HALF_TRANSPARENT) == HALF_TRANSPARENT;
}

bool isInterfaceInsideHalfTransparent(Interface *interface) {
    return isTextureHalfTransparent(interface->in);
}

bool isInterfaceOutsideHalfTransparent(Interface *interface) {
    return isTextureHalfTransparent(interface->out);
}

Real getInterfaceRoughness(Interface *interface) { return interface->roughness; }

void destroyTexture(Texture *tex) {
    if (isTextureFullyTransparent(tex) || isTextureHalfTransparent(tex)) {
        // for opaque materials, data is a function
        // they shall not be freed
        free(tex->data);
    }
    free(tex);
}

Interface *newInterface(Texture *in, Texture *out, Real roughness) {
    Interface *interface = malloc(sizeof(*interface));
    *interface = (Interface){in, out, roughness};
    return interface;
}

void destroyInterface(Interface *interface) {
    // users should manage the texture themselves since they might reuse the textures like air
    free(interface);
}

#undef AG_LINE_COUNT
#undef AU_LINE_COUNT
#undef CU_LINE_COUNT
#undef FE_LINE_COUNT
#undef GLASS_LINE_COUNT
#undef SAPPHIRE_LINE_COUNT
