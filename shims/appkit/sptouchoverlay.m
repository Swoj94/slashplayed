// Touch controls (iPhone and iPad): a thumbstick, a camera drag, taps, and a few buttons over the game, so
// it plays without a keyboard or mouse. #included at the end of the generated libspAppKit.m (gen_stubs.py
// EXTRA_INCLUDES), after spevent.m, whose event queue and mouse it drives, sploading.m, whose first-frame
// flag it waits for, and spkeyboard.m, whose focused-box state and keyboard it uses. spevent.m's
// SPInputView installs it (sp_overlay_install) and the client's event pump ticks it (sp_overlay_tick).
//
// What it sends is what a Mac keyboard and mouse would, through the same paths a hardware keyboard, an
// AssistiveTouch mouse, and finger chords already use, so the client sees nothing new:
//
// - **Thumbstick** (the lower left of the game): held W, A, S, and D (or Q and E for the sides, with
//   NSUserDefaults "sp_touch_stick_strafe"), up to two at once for the diagonals. The stick floats: it
//   centres where the thumb lands and follows a thumb that runs past its ring (sptouchstick.h has the
//   math). Keys, not a virtual gamepad: they work in every game with no setting, where a gamepad needs
//   the game's controller mode on (Classic Era's GamePadEnable) and changes how its UI behaves.
// - **Camera** (the right half): a drag holds the right button and moves the mouse, which is how the game
//   turns the character and camera (mouselook: the client freezes the cursor and reads deltas, spevent.m).
//   A quick tap is a left click where it landed (target, press a button); a still hold is a right click
//   (talk, loot, attack), since a touch screen has no other way to right-click with one thumb.
// - **Buttons** (the right edge): Jump (Space, held as long as the finger is, so swimming up works),
//   Target (Tab), Menu (Escape), Keyboard (the on-screen keyboard, spkeyboard.m), and UI Mode, which hands the
//   whole screen back to plain touches (spevent.m's chords) for dragging spells and items: the stick goes too,
//   since the spellbook, bags, and talent and character panels open over its corner of the screen.
//
// Coordinates: the client's window is in points, the same points UIKit's touches have; the client scales
// them to its drawable by its own backing scale (spwindow.m, Settings > Display), so a touch converts with
// spevent.m's sp_from_uikit and nothing more. Scaling by the screen's scale here would put every click
// twice as far from the window's corner.
//
// Typing safety: the stick and the Space and Tab buttons send letters and a space, which a focused text box
// would take as typing. They're shown only in game with no box focused (the SPKeyboard addon's strip,
// spkeyboard.m's sp_kb_focus_known and sp_kb_focus), so never on the login screen, where a stray W would
// go into the password, and they let go the moment a box takes focus. Menu and Keyboard stay everywhere.
//
// Hidden: before the client's first frame, under a launcher screen, while the on-screen keyboard is up,
// with a gamepad connected (it has sticks of its own), and when turned off (NSUserDefaults
// "sp_touch_controls_off", or SP_TOUCH_CONTROLS=0 for a run). Hiding lets go of everything held, and so
// does the scene going inactive (a swipe home, a call, Control Center), so no key stays down while the
// client is away and none is down when it comes back.

#include "sptouchstick.h"

#if TARGET_OS_VISION
static void sp_overlay_install(UIView *host) {}
static void sp_overlay_tick(void) {}
static BOOL sp_overlay_drop_click(void) { return NO; }
#else

// Its own lines, "[sp:AppKit] touch controls: …", like sptouchpad.m's. Never a key's letter: only what
// the controls did (shown, hidden, a mode), so the log says nothing about what was typed.
static void sp_overlay_say(NSString *s) {
    os_log(OS_LOG_DEFAULT, "[sp:AppKit] touch controls: %{public}s", s.UTF8String);
    fprintf(stderr, "[sp:AppKit] touch controls: %s\n", s.UTF8String);
}

// ---- tuning (points, seconds)

static const CGFloat sp_ov_slop = 10;            // a tap that moves more is a drag
static const NSTimeInterval sp_ov_hold = 0.45;   // a still touch this long is a right click
static const NSTimeInterval sp_ov_min_key = 0.05; // a key's up never comes sooner (sptouchpad.m: a game that
                                                  // reads key state once a frame could miss a shorter press)
static const CGFloat sp_ov_follow = 1.25;        // the stick's centre follows past this many radii

// The zones, as fractions of the game rect (origin top left, UIKit): the stick's lower left, below the
// player and target frames; the camera's right half. Between them, and above the stick's, touches go to
// spevent.m's own handling (finger chords), so the chat tabs and frames there stay tappable.
static const CGFloat sp_ov_stick_right = 0.42, sp_ov_stick_top = 0.30, sp_ov_look_left = 0.50;

static CGFloat sp_ov_radius(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 72 : 56;
}

// The camera's speed: a finger's points to the mouse's. NSUserDefaults "sp_touch_look_speed" (0.25 to 4).
static CGFloat sp_ov_look_speed(void) {
    double s = [NSUserDefaults.standardUserDefaults doubleForKey:@"sp_touch_look_speed"];
    return s >= 0.25 && s <= 4 ? s : 1.0;
}

static BOOL sp_ov_enabled(void) {
    const char *env = getenv("SP_TOUCH_CONTROLS");
    if (env) return strcmp(env, "0") != 0;
    return ![NSUserDefaults.standardUserDefaults boolForKey:@"sp_touch_controls_off"];
}

// ---- keys
//
// Mac virtual key codes (kVK_ANSI_*), with the characters an unshifted US key types.

enum { SP_KEY_A = 0x00, SP_KEY_S = 0x01, SP_KEY_D = 0x02, SP_KEY_Q = 0x0C, SP_KEY_W = 0x0D,
       SP_KEY_E = 0x0E, SP_KEY_TAB = 0x30, SP_KEY_SPACE = 0x31, SP_KEY_ESCAPE = 0x35 };

static NSString *sp_ov_chars(unsigned short mac) {
    unichar fc = sp_function_char(mac);  // Tab, Escape
    if (fc) return [NSString stringWithCharacters:&fc length:1];
    switch (mac) {
    case SP_KEY_A: return @"a";
    case SP_KEY_S: return @"s";
    case SP_KEY_D: return @"d";
    case SP_KEY_Q: return @"q";
    case SP_KEY_W: return @"w";
    case SP_KEY_E: return @"e";
    case SP_KEY_SPACE: return @" ";
    }
    return @"";
}

static void sp_ov_post_key(unsigned short mac, BOOL down) {
    SPEvent *e = sp_event(down ? SPKeyDown : SPKeyUp);
    e->keyCode = mac;
    NSString *chars = sp_ov_chars(mac);
    e->charactersIgnoringModifiers = chars;
    // A Shift held on a hardware keyboard shifts the characters, as it would the key's own.
    e->characters = sp_mod_flags & SPShift ? chars.uppercaseString : chars;
    sp_post(e);  // letters and space go unlogged there, like a hardware keyboard's
}

// What the controls hold, per key code. An up comes at least sp_ov_min_key after its down (a quick tap of
// Target would otherwise land both in one pump); a down while that up is still pending takes it back, so the
// key just stays down, rather than going down twice with no up between.
static BOOL sp_ov_held[128], sp_ov_up_pending[128];
static NSTimeInterval sp_ov_down_at[128];
static unsigned sp_ov_gen[128];

static void sp_ov_key(unsigned short mac, BOOL down) {
    if (mac >= 128 || sp_ov_held[mac] == down) return;
    sp_ov_held[mac] = down;
    unsigned gen = ++sp_ov_gen[mac];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (down) {
        if (sp_ov_up_pending[mac]) {
            sp_ov_up_pending[mac] = NO;  // still down, as far as the client knows
            return;
        }
        sp_ov_down_at[mac] = now;
        sp_ov_post_key(mac, YES);
        return;
    }
    NSTimeInterval wait = sp_ov_down_at[mac] + sp_ov_min_key - now;
    if (wait <= 0) {
        sp_ov_post_key(mac, NO);
        return;
    }
    sp_ov_up_pending[mac] = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!sp_ov_up_pending[mac] || sp_ov_gen[mac] != gen) return;
        sp_ov_up_pending[mac] = NO;
        sp_ov_post_key(mac, NO);
    });
}

static void sp_ov_release_keys(void) {
    for (unsigned short mac = 0; mac < 128; mac++)
        if (sp_ov_held[mac]) sp_ov_key(mac, NO);
}

// ---- a button

@interface SPTouchButton : UIView
@property (nonatomic) unsigned short key;          // held while pressed; 0 for none
@property (nonatomic, copy) void (^action)(void);  // on a lift inside it
@property (nonatomic) BOOL inGameOnly;             // shown only when the stick is (it types)
@property (nonatomic) BOOL lit;                    // a toggle's on state
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol;
- (void)sp_set_title:(NSString *)title symbol:(NSString *)symbol;
- (void)sp_cancel;
@end

@implementation SPTouchButton {
    UITouch *_touch;
    UILabel *_label;
    UIImageView *_icon;
}

- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.multipleTouchEnabled = NO;
    self.layer.borderWidth = 1.5;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = title;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    if (symbol) {
        _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        _icon.tintColor = UIColor.whiteColor;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_icon];
    } else {
        _label = [[UILabel alloc] init];
        _label.text = title;
        _label.textColor = UIColor.whiteColor;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.6;
        [self addSubview:_label];
    }
    [self sp_style:NO];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.layer.cornerRadius = b.size.width / 2;
    _label.frame = CGRectInset(b, 4, 0);
    _label.font = [UIFont systemFontOfSize:b.size.width * 0.26 weight:UIFontWeightSemibold];
    _icon.frame = CGRectInset(b, b.size.width * 0.27, b.size.width * 0.27);
}

// A toggle's look for its state: the icon says what the button is now, not what a tap would do.
- (void)sp_set_title:(NSString *)title symbol:(NSString *)symbol {
    self.accessibilityLabel = title;
    _icon.image = [UIImage systemImageNamed:symbol];
    _label.text = title;
}

- (void)setLit:(BOOL)lit {
    _lit = lit;
    [self sp_style:_touch != nil];
}

- (void)sp_style:(BOOL)pressed {
    // Lit (a toggle that's on) is blue, not just brighter: it has to read at a glance in the middle of play.
    self.backgroundColor = pressed ? [UIColor colorWithWhite:1 alpha:0.42]
                         : _lit ? [UIColor.systemBlueColor colorWithAlphaComponent:0.6]
                                : [UIColor colorWithWhite:0.1 alpha:0.14];
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:_lit || pressed ? 0.7 : 0.35].CGColor;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch) return;
    _touch = touches.anyObject;
    [self sp_style:YES];
    if (_key) sp_ov_key(_key, YES);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}

- (void)sp_lift:(NSSet<UITouch *> *)touches inside:(BOOL)inside {
    if (!_touch || ![touches containsObject:_touch]) return;
    CGPoint p = [_touch locationInView:self];
    _touch = nil;
    [self sp_style:NO];
    if (_key) sp_ov_key(_key, NO);
    // A thumb rolls: a lift a little outside still counts.
    if (inside && _action && CGRectContainsPoint(CGRectInset(self.bounds, -16, -16), p)) _action();
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sp_lift:touches inside:YES];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sp_lift:touches inside:NO];
}

// Hidden mid-press, or the scene going inactive: lets go without the action.
- (void)sp_cancel {
    if (!_touch) return;
    [self sp_lift:[NSSet setWithObject:_touch] inside:NO];
}
@end

// ---- the overlay

typedef enum { SP_LOOK_NONE, SP_LOOK_PENDING, SP_LOOK_DRAG, SP_LOOK_DONE } sp_look_state;

@interface SPTouchOverlay : UIView
- (void)sp_reset:(const char *)why;
- (void)sp_show:(BOOL)show stick:(BOOL)stick;
@end

static SPTouchOverlay *sp_overlay;
static BOOL sp_ov_ui_mode;  // UI Mode: no stick or camera, plain touches everywhere (the toggle)

@implementation SPTouchOverlay {
    BOOL _shown, _stick_shown;
    CGRect _laid_out;                 // the game rect last laid out for

    UIView *_ring, *_knob;
    UITouch *_stick_touch;
    CGPoint _stick_centre;            // UIKit, in this view
    CGPoint _stick_rest;              // where the idle ring sits
    sp_stick_dirs _dirs;

    UITouch *_look_touch;
    sp_look_state _look;
    CGPoint _look_start, _look_last;  // UIKit
    CGPoint _look_mouse;              // AppKit: where the camera drag has taken the mouse
    unsigned _look_gen;               // bumped per touch, so a stale hold timer does nothing

    SPTouchButton *_jump, *_target, *_menu, *_keyboard, *_mode;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.hidden = YES;  // until the client's first frame (sp_overlay_tick)

    _ring = [[UIView alloc] init];
    _ring.userInteractionEnabled = NO;
    _ring.layer.borderWidth = 2;
    _ring.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
    _ring.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
    [self addSubview:_ring];
    _knob = [[UIView alloc] init];
    _knob.userInteractionEnabled = NO;
    _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5];
    [self addSubview:_knob];

    _jump = [[SPTouchButton alloc] initWithTitle:@"Jump" symbol:@"arrow.up"];
    _jump.key = SP_KEY_SPACE;
    _jump.inGameOnly = YES;
    _target = [[SPTouchButton alloc] initWithTitle:@"Target" symbol:@"scope"];
    _target.key = SP_KEY_TAB;
    _target.inGameOnly = YES;
    _menu = [[SPTouchButton alloc] initWithTitle:@"Menu" symbol:@"line.3.horizontal"];
    _menu.key = SP_KEY_ESCAPE;
    _keyboard = [[SPTouchButton alloc] initWithTitle:@"Keyboard" symbol:@"keyboard"];
    _keyboard.action = ^{
        if (sp_keyboard_up()) {
            [sp_kb_view resignFirstResponder];
            return;
        }
        // In game: the focused box's keyboard, or Return to open chat (spkeyboard.m's sp_keyboard_menu). On the
        // login and character screens, where addons don't run, the keyboard at this point, which types into
        // whatever box the game has focused (an authenticator code's); on an iPhone it zooms around the point,
        // so it's where the login screen's boxes are.
        CGRect g = sp_game_rect();
        sp_keyboard_menu(CGPointMake(CGRectGetMidX(g), g.origin.y + g.size.height * 0.45));
    };
    _mode = [[SPTouchButton alloc] initWithTitle:@"UI Mode" symbol:@"hand.tap"];
    __weak SPTouchOverlay *weak = self;
    _mode.action = ^{
        SPTouchOverlay *me = weak;
        if (!me) return;
        sp_ov_ui_mode = !sp_ov_ui_mode;
        if (sp_ov_ui_mode) {
            [me sp_end_look];
            if (me->_stick_touch) [me sp_stick_ended];
        }
        [me sp_mode_changed];
        sp_overlay_say(sp_ov_ui_mode ? @"UI Mode: plain touches everywhere" : @"stick and camera back");
    };
    [self sp_mode_changed];
    for (SPTouchButton *b in @[_jump, _target, _menu, _keyboard, _mode]) [self addSubview:b];

    // The scene going inactive: let go of everything, so nothing's held while the client is away (it keeps
    // running ~26 s in the background, spuikit.m) or when it comes back.
    for (NSNotificationName name in @[UISceneWillDeactivateNotification, UIApplicationWillResignActiveNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) {
            [weak sp_reset:"the scene went inactive"];
        }];
    return self;
}

// ---- layout

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect g = sp_game_rect();
    _laid_out = g;
    CGFloat r = sp_ov_radius();
    _stick_rest = CGPointMake(g.origin.x + MAX(r + 28, g.size.width * 0.16),
                              CGRectGetMaxY(g) - MAX(r + 28, g.size.height * 0.27));
    if (!_stick_touch) [self sp_place_stick:_stick_rest knob:CGPointZero active:NO];

    // The buttons: Jump in the corner, Target beside it, a column above for the rest. Sizes in points,
    // larger on an iPad, inside the game rect (not the strip beside an iPhone's island).
    BOOL pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    CGFloat big = pad ? 84 : 68, mid = pad ? 66 : 54, small = pad ? 50 : 42, gap = pad ? 14 : 10, inset = pad ? 28 : 18;
    CGFloat right = CGRectGetMaxX(g) - inset, bottom = CGRectGetMaxY(g) - inset;
    _jump.frame = CGRectMake(right - big, bottom - big, big, big);
    _target.frame = CGRectMake(right - big - gap - mid, bottom - mid, mid, mid);
    CGFloat x = right - small, y = bottom - big - gap * 2;
    for (SPTouchButton *b in @[_mode, _keyboard, _menu]) {
        y -= small;
        b.frame = CGRectMake(x, y, small, small);
        y -= gap;
    }
}

// centre: UIKit; knob: the knob's offset from it.
- (void)sp_place_stick:(CGPoint)centre knob:(CGPoint)knob active:(BOOL)active {
    CGFloat r = sp_ov_radius(), k = r * 0.48;
    _ring.frame = CGRectMake(centre.x - r, centre.y - r, r * 2, r * 2);
    _ring.layer.cornerRadius = r;
    _knob.frame = CGRectMake(centre.x + knob.x - k, centre.y + knob.y - k, k * 2, k * 2);
    _knob.layer.cornerRadius = k;
    _ring.alpha = _knob.alpha = active ? 1 : 0.45;
}

// ---- zones

- (BOOL)sp_in_stick_zone:(CGPoint)p {
    if (!_stick_shown || sp_ov_ui_mode) return NO;
    CGRect g = sp_game_rect();
    return CGRectContainsPoint(CGRectMake(g.origin.x, g.origin.y + g.size.height * sp_ov_stick_top,
                                          g.size.width * sp_ov_stick_right, g.size.height * (1 - sp_ov_stick_top)), p);
}

- (BOOL)sp_in_look_zone:(CGPoint)p {
    if (sp_ov_ui_mode) return NO;
    CGRect g = sp_game_rect();
    return CGRectContainsPoint(CGRectMake(g.origin.x + g.size.width * sp_ov_look_left, g.origin.y,
                                          g.size.width * (1 - sp_ov_look_left), g.size.height), p);
}

// The buttons, then the zones; anything else falls through to spevent.m's SPInputView underneath (finger
// chords, the edit menu), as if this view weren't there. A zone already in use passes a second finger
// through too, so a two-finger chord still works beside a held stick.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled) return nil;
    UIView *v = [super hitTest:point withEvent:event];
    if (v != self) return v;  // a button, or nil
    if (!_stick_touch && [self sp_in_stick_zone:point]) return self;
    if (!_look_touch && [self sp_in_look_zone:point]) return self;
    return nil;
}

// ---- touches

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    sp_keyboard_forget();  // as SPInputView does: the box typed in may have lost focus
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (!_stick_touch && [self sp_in_stick_zone:p]) [self sp_stick_began:t at:p];
        else if (!_look_touch && [self sp_in_look_zone:p]) [self sp_look_began:t at:p];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_stick_touch && [touches containsObject:_stick_touch]) [self sp_stick_moved];
    if (_look_touch && [touches containsObject:_look_touch]) [self sp_look_moved];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_stick_touch && [touches containsObject:_stick_touch]) [self sp_stick_ended];
    if (_look_touch && [touches containsObject:_look_touch]) [self sp_look_ended:YES];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_stick_touch && [touches containsObject:_stick_touch]) [self sp_stick_ended];
    if (_look_touch && [touches containsObject:_look_touch]) [self sp_look_ended:NO];
}

// ---- the stick

- (void)sp_stick_began:(UITouch *)t at:(CGPoint)p {
    _stick_touch = t;
    // Centred where the thumb lands, but with its whole ring inside the game.
    CGFloat r = sp_ov_radius();
    CGRect g = CGRectInset(sp_game_rect(), r, r);
    _stick_centre = CGPointMake(MIN(MAX(p.x, CGRectGetMinX(g)), CGRectGetMaxX(g)),
                                MIN(MAX(p.y, CGRectGetMinY(g)), CGRectGetMaxY(g)));
    [self sp_stick_moved];
}

- (void)sp_stick_moved {
    CGPoint p = [_stick_touch locationInView:self];
    CGFloat r = sp_ov_radius();
    float cx = _stick_centre.x, cy = _stick_centre.y;
    sp_stick_follow(&cx, &cy, p.x, p.y, r, sp_ov_follow);
    _stick_centre = CGPointMake(cx, cy);
    float dx = p.x - cx, dy = p.y - cy, kx, ky;
    sp_stick_clamp(dx, dy, r, &kx, &ky);
    [self sp_place_stick:_stick_centre knob:CGPointMake(kx, ky) active:YES];
    [self sp_stick_set:sp_stick_eval(dx, dy, r, _dirs)];
}

- (void)sp_stick_ended {
    _stick_touch = nil;
    [self sp_stick_set:(sp_stick_dirs){false, false, false, false}];
    [self sp_place_stick:_stick_rest knob:CGPointZero active:NO];
}

// Ups before downs, so a turn from W+D to W+A never has three keys down at once.
- (void)sp_stick_set:(sp_stick_dirs)d {
    BOOL strafe = [NSUserDefaults.standardUserDefaults boolForKey:@"sp_touch_stick_strafe"];
    unsigned short left = strafe ? SP_KEY_Q : SP_KEY_A, right = strafe ? SP_KEY_E : SP_KEY_D;
    // A strafe setting changed mid-hold: the other pair may be down.
    unsigned short other_left = strafe ? SP_KEY_A : SP_KEY_Q, other_right = strafe ? SP_KEY_D : SP_KEY_E;
    if (sp_ov_held[other_left]) sp_ov_key(other_left, NO);
    if (sp_ov_held[other_right]) sp_ov_key(other_right, NO);
    if (!d.up) sp_ov_key(SP_KEY_W, NO);
    if (!d.down) sp_ov_key(SP_KEY_S, NO);
    if (!d.left) sp_ov_key(left, NO);
    if (!d.right) sp_ov_key(right, NO);
    if (d.up) sp_ov_key(SP_KEY_W, YES);
    if (d.down) sp_ov_key(SP_KEY_S, YES);
    if (d.left) sp_ov_key(left, YES);
    if (d.right) sp_ov_key(right, YES);
    _dirs = d;
}

// ---- the camera, taps, and holds
//
// A touch presses nothing until it's known which it is, since a press can't be taken back: a move past the
// slop is a camera drag (the right button goes down where the touch began, and the mouse follows the
// finger from there), a lift before the hold time is a left click where it began, and a still hold is a
// right click there. Clicks go through spevent.m's sp_mouse_button, which moves the mouse to the point
// first and counts double clicks, as for a finger chord.

- (void)sp_look_began:(UITouch *)t at:(CGPoint)p {
    _look_touch = t;
    _look = SP_LOOK_PENDING;
    _look_start = _look_last = p;
    unsigned gen = ++_look_gen;
    __weak SPTouchOverlay *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sp_ov_hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPTouchOverlay *me = weak;
        if (!me || me->_look_gen != gen || me->_look != SP_LOOK_PENDING) return;
        me->_look = SP_LOOK_DONE;
        CGPoint at = sp_from_uikit(me->_look_start);
        sp_mouse_button(1, YES, at);
        sp_mouse_button(1, NO, at);
    });
}

- (void)sp_look_moved {
    CGPoint p = [_look_touch locationInView:self];
    if (_look == SP_LOOK_PENDING) {
        if (hypot(p.x - _look_start.x, p.y - _look_start.y) <= sp_ov_slop) return;
        _look = SP_LOOK_DRAG;
        _look_mouse = sp_from_uikit(_look_start);
        sp_mouse_button(1, YES, _look_mouse);
        _look_last = _look_start;  // the slop's movement turns too, so the drag doesn't lag the finger
    }
    if (_look != SP_LOOK_DRAG) return;
    // The mouse follows the finger at the look speed. While the client has the cursor frozen (mouselook)
    // sp_mouse_moved_to posts the deltas and leaves the cursor where it was; before it does, the cursor
    // moves with them, as a Mac's would for the moment before the client hides it. AppKit's y is up.
    CGFloat k = sp_ov_look_speed();
    _look_mouse.x += (p.x - _look_last.x) * k;
    _look_mouse.y -= (p.y - _look_last.y) * k;
    _look_last = p;
    sp_mouse_moved_to(_look_mouse, sp_motion_type(), NO);
}

// ended: a lift, not a cancel (a cancelled touch never clicks).
- (void)sp_look_ended:(BOOL)ended {
    sp_look_state was = _look;
    CGPoint start = _look_start;
    _look_touch = nil;
    _look = SP_LOOK_NONE;
    _look_gen++;
    if (was == SP_LOOK_DRAG) {
        sp_mouse_button(1, NO, sp_pointer);  // where the mouse is: no last move to jump the camera
    } else if (was == SP_LOOK_PENDING && ended) {
        CGPoint at = sp_from_uikit(start);
        sp_mouse_button(0, YES, at);
        sp_mouse_button(0, NO, at);
    }
}

- (void)sp_end_look {
    if (_look_touch) [self sp_look_ended:NO];
}

// ---- showing and hiding

// Lets go of everything the controls hold. Touches still down are forgotten: their later moves and lifts
// find no stick or look touch, and do nothing.
- (void)sp_reset:(const char *)why {
    BOOL held = _stick_touch || _look_touch;
    for (unsigned short mac = 0; mac < 128 && !held; mac++) held = sp_ov_held[mac];
    if (_stick_touch) [self sp_stick_ended];
    [self sp_end_look];
    for (SPTouchButton *b in @[_jump, _target, _menu, _keyboard, _mode]) [b sp_cancel];
    sp_ov_release_keys();
    if (held) sp_overlay_say([NSString stringWithFormat:@"let go of everything held (%s)", why]);
}

- (void)sp_show:(BOOL)show stick:(BOOL)stick {
    if (!show) stick = NO;
    if (show == _shown && stick == _stick_shown) return;
    if (!stick && _stick_shown) {
        if (_stick_touch) [self sp_stick_ended];
        [_jump sp_cancel];
        [_target sp_cancel];
    }
    if (!show && _shown) [self sp_reset:"hidden"];
    sp_overlay_say([NSString stringWithFormat:@"%s%s", show ? "shown" : "hidden",
                    show ? (stick ? ", with the stick" : ", without the stick (not in game, or a box has focus)") : ""]);
    _shown = show;
    _stick_shown = stick;
    self.hidden = !show;
    _ring.hidden = _knob.hidden = !stick || sp_ov_ui_mode;
    _jump.hidden = _target.hidden = !stick;
}

// UI Mode's button lit, with a pointing hand, while it's on (the stick hidden, so it's plain that the screen
// is in another mode); off, the camera icon of what the right half does.
- (void)sp_mode_changed {
    _mode.lit = sp_ov_ui_mode;
    [_mode sp_set_title:sp_ov_ui_mode ? @"UI Mode" : @"Camera"
                 symbol:sp_ov_ui_mode ? @"hand.tap.fill" : @"arrow.triangle.2.circlepath.camera"];
    _ring.hidden = _knob.hidden = !_stick_shown || sp_ov_ui_mode;
}

- (BOOL)sp_needs_layout {
    return !CGRectEqualToRect(_laid_out, sp_game_rect());
}
@end

// ---- for spevent.m

// SPInputView's init: over the client's layer and the look highlights, under the cursor (zPosition 2000),
// filling the root view as SPInputView does; the zones and buttons are placed in the game rect.
static void sp_overlay_install(UIView *host) {
    if (sp_overlay) return;
    sp_overlay = [[SPTouchOverlay alloc] initWithFrame:host.bounds];
    sp_overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sp_overlay.layer.zPosition = 1800;
    [host addSubview:sp_overlay];
    sp_overlay_say(sp_ov_enabled() ? @"installed" : @"installed, turned off");
}

// spevent.m's finger drags: in UI Mode, a drag's end clicks where it ended too, so a spell dragged from the
// spellbook onto one of Forever's controller-style bar slots is placed (they take it on a click, not a drop).
static BOOL sp_overlay_drop_click(void) {
    return sp_overlay && !sp_overlay.hidden && sp_ov_ui_mode;
}

// The client's event pump, every call: cheap reads, and UIKit work only when something changed.
static void sp_overlay_tick(void) {
    if (!sp_overlay) return;
    BOOL show = sp_ov_enabled() && sp_loading_presented && !sp_window.rootViewController.presentedViewController &&
                !sp_gamepad_connected() && !sp_keyboard_up();
    // In game with the UI showing (the SPKeyboard addon's strip) and no text box focused: letters are safe.
    BOOL stick = sp_kb_focus_known && CGRectIsNull(sp_kb_focus);
    [sp_overlay sp_show:show stick:stick];
    if (show && [sp_overlay sp_needs_layout]) [sp_overlay setNeedsLayout];
}

#endif
