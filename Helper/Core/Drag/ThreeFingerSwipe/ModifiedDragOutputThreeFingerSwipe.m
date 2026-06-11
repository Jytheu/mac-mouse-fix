//
// --------------------------------------------------------------------------
// ModifiedDragOutputThreeFingerDrag.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import "ModifiedDragOutputThreeFingerSwipe.h"
#import "CGSSpace.h"
#import "TouchSimulator.h"
@import Cocoa;
@import QuartzCore;
#import "PointerFreeze.h"
#import "SymbolicHotKeys.h"
#import "Config.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"

@implementation ModifiedDragOutputThreeFingerSwipe

/// Vars

static ModifiedDragState *_drag;

static int16_t _nOfSpaces = 1;

/// On macOS 26 (Tahoe) and later, the WindowServer drops synthetic dockSwipe gesture events (`CGXSenderCanSynthesizeEvents()` compares the sender PID against the WindowServer's – not bypassable through code signing or TCC grants). So instead of the smooth dockSwipe gesture we accumulate the drag and trigger the corresponding SymbolicHotKeys at fixed thresholds. Trade-off: discrete jumps instead of following the pointer.
static BOOL useSymbolicHotKeyFallback(void) {
    if (@available(macOS 26.0, *)) return YES;
    return NO;
}

static double _accumulatedDelta = 0;
static double _smoothedVelocity = 0;              /// Exponential moving average of drag speed along the usage axis (px/s)
static CFTimeInterval _lastInputTime = 0;
static CGSSymbolicHotKey _lastVerticalSHK = -1;   /// The SHK we last opened an overlay with – tells us which SHK closes it again. -1: none
static CFTimeInterval _lastVerticalPostTime = 0;
static CFTimeInterval _lastHorizontalPostTime = 0;

static double _thresholdHorizontal = 220.0;       /// Pixels of drag per space-switch. Overridable via config.
static double _thresholdVertical = 150.0;         /// Pixels of drag to trigger Mission Control / App Exposé. Overridable via config.
static const double _flickMinDistance = 50.0;     /// Minimum drag distance for a flick to count on release
static const double _flickMinVelocity = 600.0;    /// px/s – release faster than this fires even below the distance threshold
static const double _flickMaxIdleTime = 0.08;     /// s – if the pointer rested longer than this before release, it's not a flick
static const double _verticalCooldown = 0.4;      /// s – between vertical SHK posts, so a continuing drag doesn't re-toggle while the overlay is still animating in
static const double _horizontalCooldown = 0.35;   /// s – between space-switches, roughly the slide-animation duration. One hard swipe moves exactly one space (like the real gesture); only sustained dragging chains, paced to the animation.

/// On macOS 26+, Mission Control / App Exposé are rendered by the WindowManager process. While such an overlay is open,
/// WindowManager owns onscreen windows at layers 16-19 (determined empirically on macOS 27.0); checking owner and layer
/// is available without the Screen Recording permission.
/// Querying the real state (instead of remembering what we posted) keeps us in sync when the user closes the overlay
/// some other way, e.g. with Esc or a click.
static BOOL exposeOverlayIsOpen(void) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in windows) {
        if (![w[(__bridge NSString *)kCGWindowOwnerName] isEqualToString:@"WindowManager"]) continue;
        int layer = [w[(__bridge NSString *)kCGWindowLayer] intValue];
        if (1 <= layer && layer <= 19) return YES;
    }
    return NO;
}

/// Open or close Mission Control / App Exposé for a vertical drag. Returns whether an SHK was posted.
///     Closing only happens in the natural direction (down closes Mission Control, up closes App Exposé), like the real gesture.
static BOOL triggerVerticalSHK(BOOL draggedUp, CFTimeInterval now) {

    if (!exposeOverlayIsOpen()) {
        CGSSymbolicHotKey shk = draggedUp ? kCGSHotKeyExposeAllWindows : kCGSHotKeyExposeApplicationWindows;
        [SymbolicHotKeys post:shk];
        _lastVerticalSHK = shk;
        _lastVerticalPostTime = now;
        return YES;
    }

    /// Overlay is open – the SHK that opened it toggles it closed
    CGSSymbolicHotKey opener = _lastVerticalSHK;
    if (opener == (CGSSymbolicHotKey)-1) { /// Opened externally (trackpad/keyboard) – infer from the drag direction
        opener = draggedUp ? kCGSHotKeyExposeApplicationWindows : kCGSHotKeyExposeAllWindows;
    }
    BOOL closes = (opener == kCGSHotKeyExposeAllWindows) ? !draggedUp : draggedUp;
    if (!closes) return NO;

    [SymbolicHotKeys post:opener];
    _lastVerticalSHK = -1;
    _lastVerticalPostTime = now;
    return YES;
}

/// Interface funcs

+ (void)initializeWithDragState:(ModifiedDragState *)dragStateRef {
    _drag = dragStateRef;
}

+ (void)handleBecameInUse {
    /// Get number of spaces
    CFArrayRef spaces = CGSCopySpaces(CGSMainConnectionID(), CGSSpaceIncludesUser | CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent);

    if (spaces != NULL) {
        /// Full screen spaces appear twice for some reason so we need to filter duplicates
        NSSet *uniqueSpaces = [NSSet setWithArray:(__bridge NSArray *)spaces];
        _nOfSpaces = MAX((int16_t)1, (int16_t)uniqueSpaces.count);
        CFRelease(spaces);
    } else {
        _nOfSpaces = 1;
    }

    /// Reset state for the symbolic-hotkey fallback
    ///     Note: `_lastVerticalSHK` is deliberately NOT reset – if a previous drag opened Mission Control, the next drag (down) should close it again, like the real gesture.
    _accumulatedDelta = 0;
    _smoothedVelocity = 0;
    _lastInputTime = CACurrentMediaTime();
    _lastHorizontalPostTime = 0;

    /// Optional config overrides for the thresholds
    NSNumber *configThresholdH = (NSNumber *)config(@"Other.threeFingerSwipeSHKThresholdHorizontal");
    NSNumber *configThresholdV = (NSNumber *)config(@"Other.threeFingerSwipeSHKThresholdVertical");
    _thresholdHorizontal = [configThresholdH isKindOfClass:NSNumber.class] && configThresholdH.doubleValue > 0 ? configThresholdH.doubleValue : 220.0;
    _thresholdVertical   = [configThresholdV isKindOfClass:NSNumber.class] && configThresholdV.doubleValue > 0 ? configThresholdV.doubleValue : 150.0;

    /// Freeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze freezePointerAtPosition:_drag->usageOrigin];
    }
}

+ (void)handleMouseInputWhileInUseWithDeltaX:(double)deltaX deltaY:(double)deltaY event:(CGEventRef)event {

    if (useSymbolicHotKeyFallback()) {
        /// The deltas are already inverted according to `naturalDirection` by ModifiedDrag before they reach this plugin.

        /// Track drag velocity (EMA), for flick detection on release
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval dt = now - _lastInputTime;
        _lastInputTime = now;
        double axisDelta = (_drag->usageAxis == kMFAxisHorizontal) ? deltaX : deltaY;
        if (dt > 0 && dt < 0.5) {
            _smoothedVelocity = 0.7 * _smoothedVelocity + 0.3 * (axisDelta / dt);
        }

        if (_drag->usageAxis == kMFAxisHorizontal) {
            if ((now - _lastHorizontalPostTime) < _horizontalCooldown) {
                _accumulatedDelta = 0;
            } else {
                _accumulatedDelta += deltaX;
                if (fabs(_accumulatedDelta) >= _thresholdHorizontal) {
                    [SymbolicHotKeys post:(_accumulatedDelta > 0 ? kCGSHotKeySpaceLeft : kCGSHotKeySpaceRight)];
                    _accumulatedDelta = 0;
                    _lastHorizontalPostTime = now;
                }
            }
        } else if (_drag->usageAxis == kMFAxisVertical) {
            _accumulatedDelta += deltaY;
            if ((now - _lastVerticalPostTime) >= _verticalCooldown && fabs(_accumulatedDelta) >= _thresholdVertical) {
                triggerVerticalSHK(_accumulatedDelta < 0, now);
                _accumulatedDelta = 0;
            }
        }
        return;
    }

    /**
     Horizontal dockSwipe scaling
     This makes horizontal dockSwipes (switch between spaces) follow the pointer exactly
     I arrived at these value through testing documented in the NotePlan note "MMF - Scraps - Testing DockSwipe scaling"
     TODO: Test this on a vertical screen
     */
    CGSize screenSize = NSScreen.mainScreen.frame.size;
    double originOffsetForOneSpace = _nOfSpaces == 1 ? 2.0 : 1.0 + (1.0 / (_nOfSpaces-1));
    double spaceSeparatorWidth = 63;
    double threeFingerScaleH = originOffsetForOneSpace / (screenSize.width + spaceSeparatorWidth);

    /// Vertical dockSwipe scaling
    double threeFingerScaleV = 1.0 / screenSize.height;

    /// Get phase
    IOHIDEventPhaseBits eventPhase = _drag->firstCallback ? kIOHIDEventPhaseBegan : kIOHIDEventPhaseChanged;

    /// Send events
    if (_drag->usageAxis == kMFAxisHorizontal) {
        double delta = -deltaX * threeFingerScaleH;
        [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeHorizontal phase:eventPhase invertedFromDevice:_drag->naturalDirection];
    } else if (_drag->usageAxis == kMFAxisVertical) {
        double delta = deltaY * threeFingerScaleV;
        [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeVertical phase:eventPhase invertedFromDevice:_drag->naturalDirection];
    }
}

+ (void)handleDeactivationWhileInUseWithCancel:(BOOL)cancel {

    if (useSymbolicHotKeyFallback()) {

        /// Flick detection on release
        CFTimeInterval now = CACurrentMediaTime();
        BOOL stillMoving = (now - _lastInputTime) <= _flickMaxIdleTime;
        if (!cancel
            && stillMoving
            && fabs(_accumulatedDelta) >= _flickMinDistance
            && fabs(_smoothedVelocity) >= _flickMinVelocity
            && (_smoothedVelocity > 0) == (_accumulatedDelta > 0)) {

            if (_drag->usageAxis == kMFAxisHorizontal) {
                if ((now - _lastHorizontalPostTime) >= _horizontalCooldown) {
                    [SymbolicHotKeys post:(_accumulatedDelta > 0 ? kCGSHotKeySpaceLeft : kCGSHotKeySpaceRight)];
                    _lastHorizontalPostTime = now;
                }
            } else if (_drag->usageAxis == kMFAxisVertical) {
                if ((now - _lastVerticalPostTime) >= _verticalCooldown) {
                    triggerVerticalSHK(_accumulatedDelta < 0, now);
                }
            }
        }
        _accumulatedDelta = 0;

        if (GeneralConfig.freezePointerDuringModifiedDrag) {
            [PointerFreeze unfreeze];
        }
        return;
    }

    MFDockSwipeType type;
    IOHIDEventPhaseBits phase;

    if (_drag->usageAxis == kMFAxisHorizontal) {
        type = kMFDockSwipeTypeHorizontal;
    } else if (_drag->usageAxis == kMFAxisVertical) {
        type = kMFDockSwipeTypeVertical;
    } else {
        assert(false);
    }

    phase = cancel ? kIOHIDEventPhaseCancelled : kIOHIDEventPhaseEnded;

    [TouchSimulator postDockSwipeEventWithDelta:0.0 type:type phase:phase invertedFromDevice:_drag->naturalDirection];

    /// Unfreeze pointer
    if (GeneralConfig.freezePointerDuringModifiedDrag) {
        [PointerFreeze unfreeze];
    }
}

+ (void)suspend {}
+ (void)unsuspend {}

@end
