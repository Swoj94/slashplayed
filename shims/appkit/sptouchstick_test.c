// Checks sptouchstick.h: cc -std=c99 -Wall -o /tmp/sptouchstick_test shims/appkit/sptouchstick_test.c -lm
// && /tmp/sptouchstick_test

#include "sptouchstick.h"
#include <stdio.h>

static int failures;

static void expect(const char *what, sp_stick_dirs got, int up, int down, int left, int right) {
    if (got.up == up && got.down == down && got.left == left && got.right == right) return;
    failures++;
    printf("FAIL %s: got up=%d down=%d left=%d right=%d\n", what, got.up, got.down, got.left, got.right);
}

static sp_stick_dirs at(float deg, float frac, sp_stick_dirs prev) {
    float r = 60, rad = deg * 3.14159265f / 180;
    // deg 0 is right, 90 is up (screen y is down, so dy is negative for up).
    return sp_stick_eval(cosf(rad) * r * frac, -sinf(rad) * r * frac, r, prev);
}

int main(void) {
    sp_stick_dirs none = {0, 0, 0, 0};
    expect("centre", at(0, 0, none), 0, 0, 0, 0);
    expect("inside dead zone", at(90, 0.2f, none), 0, 0, 0, 0);
    expect("up", at(90, 1, none), 1, 0, 0, 0);
    expect("down", at(270, 1, none), 0, 1, 0, 0);
    expect("left", at(180, 1, none), 0, 0, 1, 0);
    expect("right", at(0, 1, none), 0, 0, 0, 1);
    expect("up-right", at(45, 1, none), 1, 0, 0, 1);
    expect("up-left", at(135, 1, none), 1, 0, 1, 0);
    expect("down-left", at(225, 1, none), 0, 1, 1, 0);
    expect("down-right", at(315, 1, none), 0, 1, 0, 1);
    // Every angle gives one or two keys, never opposite ones, outside the dead zone.
    for (int d = 0; d < 360; d++) {
        sp_stick_dirs s = at((float)d, 0.9f, none);
        int n = s.up + s.down + s.left + s.right;
        if (n < 1 || n > 2 || (s.up && s.down) || (s.left && s.right)) {
            failures++;
            printf("FAIL angle %d: %d keys\n", d, n);
        }
    }
    // Sector edge at 22.5 deg: just under is right only, just over adds up.
    expect("20 deg", at(20, 1, none), 0, 0, 0, 1);
    expect("25 deg", at(25, 1, none), 1, 0, 0, 1);
    // Hysteresis: once up is held at 25 deg, drifting to 19 deg (sin 0.326 > 0.30) keeps it...
    sp_stick_dirs held = at(25, 1, none);
    expect("held at 19 deg", at(19, 1, held), 1, 0, 0, 1);
    // ...and 15 deg (sin 0.259 < 0.30) lets it go.
    expect("released at 15 deg", at(15, 1, held), 0, 0, 0, 1);
    // The dead zone's margin: moving at 0.19 of the radius keeps going, starting there doesn't.
    expect("start at 0.19", at(90, 0.19f, none), 0, 0, 0, 0);
    expect("keep at 0.19", at(90, 0.19f, at(90, 1, none)), 1, 0, 0, 0);
    expect("stop at 0.1", at(90, 0.1f, at(90, 1, none)), 0, 0, 0, 0);
    expect("zero radius", sp_stick_eval(10, 10, 0, none), 0, 0, 0, 0);

    float kx, ky;
    sp_stick_clamp(120, 0, 60, &kx, &ky);
    if (fabsf(kx - 60) > 0.01f || fabsf(ky) > 0.01f) { failures++; printf("FAIL clamp: %f,%f\n", kx, ky); }
    sp_stick_clamp(30, 40, 60, &kx, &ky);
    if (kx != 30 || ky != 40) { failures++; printf("FAIL clamp inside: %f,%f\n", kx, ky); }

    float cx = 100, cy = 100;
    sp_stick_follow(&cx, &cy, 100 + 90, 100, 60, 1.25f);  // 90 > 75: centre moves 15 right
    if (fabsf(cx - 115) > 0.01f || fabsf(cy - 100) > 0.01f) { failures++; printf("FAIL follow: %f,%f\n", cx, cy); }
    sp_stick_follow(&cx, &cy, 115 + 50, 100, 60, 1.25f);  // within: no move
    if (fabsf(cx - 115) > 0.01f) { failures++; printf("FAIL follow within: %f\n", cx); }

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("sptouchstick: all checks passed\n");
    return 0;
}
