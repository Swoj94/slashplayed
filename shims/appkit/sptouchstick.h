// The touch overlay's thumbstick math (sptouchoverlay.m): a finger's offset from the stick's centre to the
// movement keys it holds. Plain C, so sptouchstick_test.c checks it on any machine with a C compiler.
//
// Eight directions, 45 degrees each, from the offset's unit vector: a key is on when its axis's component
// is past sin 22.5 degrees (0.383), the line halfway between a straight direction and a diagonal. Each key
// keeps a margin to come off (0.30), and the stick as a whole a margin below its dead zone, so a thumb
// resting on a sector's edge doesn't flicker W, W+D, W, which the game would take as taps.
//
// The finger's offset is in UIKit points, y down; up on the screen is forward (W).

#include <math.h>
#include <stdbool.h>

typedef struct { bool up, down, left, right; } sp_stick_dirs;

#define SP_STICK_ON 0.3827f        // sin(22.5 deg): a sector's edge
#define SP_STICK_OFF 0.30f         // a held key lets go only below this
#define SP_STICK_DEAD 0.22f        // of the radius: no keys inside
#define SP_STICK_DEAD_OFF 0.16f    // a stick already moving stops only inside this

static inline bool sp_stick_any(sp_stick_dirs d) {
    return d.up || d.down || d.left || d.right;
}

// dx, dy: the finger from the stick's centre, points, y down. radius: the stick's, points (> 0).
// prev: what the stick held before, for the margins.
static inline sp_stick_dirs sp_stick_eval(float dx, float dy, float radius, sp_stick_dirs prev) {
    sp_stick_dirs none = {false, false, false, false};
    if (!(radius > 0)) return none;
    float nx = dx / radius, ny = -dy / radius;  // y up
    float mag = sqrtf(nx * nx + ny * ny);
    float dead = sp_stick_any(prev) ? SP_STICK_DEAD_OFF : SP_STICK_DEAD;
    if (!(mag > dead)) return none;  // also NaN
    float ux = nx / mag, uy = ny / mag;
    sp_stick_dirs d;
    d.up = uy > (prev.up ? SP_STICK_OFF : SP_STICK_ON);
    d.down = uy < -(prev.down ? SP_STICK_OFF : SP_STICK_ON);
    d.right = ux > (prev.right ? SP_STICK_OFF : SP_STICK_ON);
    d.left = ux < -(prev.left ? SP_STICK_OFF : SP_STICK_ON);
    return d;
}

// The knob's offset, clamped to the ring: points, same axes as dx, dy.
static inline void sp_stick_clamp(float dx, float dy, float radius, float *kx, float *ky) {
    float len = sqrtf(dx * dx + dy * dy);
    float k = len > radius && len > 0 ? radius / len : 1;
    *kx = dx * k;
    *ky = dy * k;
}

// A floating stick follows a thumb that runs past its ring: the centre is dragged along so the thumb stays
// on the ring's edge, and pulling back reverses at once instead of first crossing the old centre.
// (cx, cy) is updated in place; (fx, fy) is the finger; follow is how far past the ring (a multiple of
// the radius) the finger may go before the centre moves.
static inline void sp_stick_follow(float *cx, float *cy, float fx, float fy, float radius, float follow) {
    float dx = fx - *cx, dy = fy - *cy;
    float len = sqrtf(dx * dx + dy * dy), limit = radius * follow;
    if (!(len > limit)) return;
    float k = (len - limit) / len;
    *cx += dx * k;
    *cy += dy * k;
}
