#ifndef LIGHTSOURCE_H
#define LIGHTSOURCE_H
#include "base.h"
#include "object.h"
#include "shapes.h"
#include <stdbool.h>

typedef struct {
    Shape *shape;
    // spectrum given as a function; NULL means the blackbody spectrum below is used
    LightIntensity (*intensity)(Real wavelength);
    // blackbody spectrum: scale * B(wavelength, T) / B(555 nm, T), used when intensity is NULL
    Real blackbodyT, blackbodyNorm, blackbodyScale;
} LightSource;

LightSource newLightSource(Shape *shape, LightIntensity (*intensity)(Real));

// light with a blackbody spectrum normalized to `scale` at 555 nm
LightSource newBlackbodyLightSource(Shape *shape, Real T, Real scale);

// spectral intensity of the light at the given wavelength (nm)
LightIntensity getLightIntensity(const LightSource *source, Real wavelength);

typedef struct {
    bool collide;
    Real distance;
    Vector normalVector;
    LightIntensity intensity;
} CollideLightSourceResult;

typedef struct {
    Real X, Y, Z;
} ColorXYZ;

void initLightIntensity();

ColorXYZ wavelengthToXYZ(Real wavelength);

ScreenColor XYZtoRGB(ColorXYZ xyz);

static inline ColorXYZ colorAdd(ColorXYZ a, ColorXYZ b) {
    return (ColorXYZ){a.X + b.X, a.Y + b.Y, a.Z + b.Z};
}

static inline ColorXYZ colorComponent(Real c, ColorXYZ color) {
    return (ColorXYZ){c * color.X, c * color.Y, c * color.Z};
}

CollideLightSourceResult collideLightSource(LightSource *source, ReversedRay *ray);

Real getBlackbodyIntensity(Real wavelength, Real T);

Real tungstenLampBase(Real wavelength);

Real sunlightBase(Real wavelength);

Real whiteLightBase(Real wavelength);

#endif