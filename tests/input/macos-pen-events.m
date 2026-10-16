// SPDX-License-Identifier: GPL-3.0-or-later
// Construction/authorization-boundary tests. Never posts OS input.
#import "input-events.h"
#import <AppKit/AppKit.h>
#include "plank_transport_input.h"
#include <math.h>
#include <unistd.h>
static unsigned checks;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "pen failure line%d: %s\n", __LINE__, #x); exit(1); } ++checks; } while (0)
static NSData *pen(unsigned action, unsigned tool, float x, float y, float pressure) {
    uint8_t p[32]; plank_transport_input_encode_pen(p, action, tool, 0, 255, 65535, x, y, pressure, 0, 0);
    return [NSData dataWithBytes:p length:sizeof(p)];
}
static uint64_t penTime = 1000000000;
static uint64_t nextPenTime(void) { return penTime += 1000000; }
static NSArray *sendPen(PLANKMacInputEvents *mapper, NSData *payload, PLANKMacInputResult result) {
    uint64_t time = nextPenTime();
    NSMutableArray *events = [NSMutableArray array];
    PLANKMacInputResult got = [mapper consumeType:7 payload:payload time:time accept:^BOOL(CGEventRef event) {
        [events addObject:(__bridge id)event]; return YES;
    }];
    if (got != result) {
        const uint8_t *p = payload.bytes;
        fprintf(stderr, "pen failure sendPen: action=%u tool=%u expected=%d got=%d events=%lu time=%llu\n",
                payload.length ? p[0] : 99, payload.length > 1 ? p[1] : 99,
                (int)result, (int)got, (unsigned long)events.count, (unsigned long long)time);
        exit(1);
    }
    ++checks;
    return events;
}
static CGEventRef event(NSArray *events, unsigned index) { CHECK(index < events.count); return (__bridge CGEventRef)events[index]; }
static void checkProximity(CGEventRef e, BOOL entering, NSUInteger tool) {
    CHECK(CGEventGetType(e) == kCGEventTabletProximity);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventCapabilityMask) == 0x447);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventDeviceID) == 1);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventPointerID) == 0);
    CHECK(CGEventGetIntegerValueField(e, kCGTabletProximityEventEnterProximity) == entering);
    // Verify what an AppKit consumer actually sees, not just CG field storage.
    NSEvent *native = [NSEvent eventWithCGEvent:e]; CHECK(native);
    CHECK(native.type == NSEventTypeTabletProximity);
    CHECK(native.capabilityMask == 0x447); // identity, X/Y, buttons, pressure ONLY
    CHECK(native.deviceID == 1 && native.pointingDeviceID == 0);
    CHECK(native.pointingDeviceType == tool && native.isEnteringProximity == entering);
    CHECK(native.vendorID == 0 && native.uniqueID == 0); // no claimed Wacom identity
}
static PLANKMacInputEvents *make(CGEventSourceRef source, CGRect bounds, CGSize pixels) {
    return [[PLANKMacInputEvents alloc] initWithSource:source bounds:bounds pixels:pixels
        initialPosition:bounds.origin doubleClickInterval:.5];
}
int main(void) {
    alarm(20);
    @autoreleasepool {
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate); CHECK(source);
        CGRect bounds[] = {CGRectMake(0, 0, 1920, 1080), CGRectMake(-1920, 90, 1920, 1080), CGRectMake(0, 0, 5120, 2160)};
        CGSize pixels[] = {CGSizeMake(3840,2160), CGSizeMake(1920,1080), CGSizeMake(5120,2160)};
        for (unsigned g = 0; g < 3; ++g) {
            PLANKMacInputEvents *mapper = make(source, bounds[g], pixels[g]); CHECK(mapper);
            NSArray *hover = sendPen(mapper, pen(0,1,0,0,1), PLANKMacInputEvent);
            CHECK(hover.count == 1 && CGEventGetType(event(hover,0)) == kCGEventMouseMoved);
            CHECK(CGEventGetIntegerValueField(event(hover,0), kCGMouseEventSubtype) == 0);
            NSArray *events = sendPen(mapper, pen(1,1,0,0,0), PLANKMacInputEvent);
            CHECK(events.count == 2 && CGEventGetType(event(events,0)) == kCGEventTabletProximity);
            CHECK(CGEventGetIntegerValueField(event(events,0), kCGTabletProximityEventEnterProximity) == 1);
            checkProximity(event(events,0), YES, NSPointingDeviceTypePen);
            CHECK(CGEventGetType(event(events,1)) == kCGEventLeftMouseDown);
            CHECK(CGEventGetDoubleValueField(event(events,1), kCGTabletEventPointPressure) == 0);
            for (unsigned i = 1; i <= 20; ++i) {
                float p = i / 20.0f;
                events = sendPen(mapper, pen(3,1,p,p,p), PLANKMacInputEvent);
                CHECK(events.count == 1);
                CGEventRef e = event(events,0);
                CHECK(CGEventGetType(e) == kCGEventLeftMouseDragged);
                CHECK(fabs(CGEventGetDoubleValueField(e,kCGTabletEventPointPressure) - p) < .0001);
                CHECK(CGEventGetIntegerValueField(e,kCGMouseEventSubtype) == kCGEventMouseSubtypeTabletPoint);
                NSEvent *native = [NSEvent eventWithCGEvent:e]; CHECK(native);
                CHECK(native.subtype == NSEventSubtypeTabletPoint && native.deviceID == 1);
                // AppKit may expose the mouse-compatible pressure field with
                // 8-bit quantization; the exact CG tablet value is checked above.
                CHECK(fabs(native.pressure - p) <= 1.0 / 255.0);
                CGPoint pos = CGEventGetLocation(e);
                CHECK(fabs(pos.x - (bounds[g].origin.x + p * (bounds[g].size.width - bounds[g].size.width / pixels[g].width))) < .001);
                CHECK(fabs(pos.y - (bounds[g].origin.y + p * (bounds[g].size.height - bounds[g].size.height / pixels[g].height))) < .001);
            }
            events = sendPen(mapper, pen(2,1,1,1,0), PLANKMacInputEvent);
            CHECK(events.count == 2 && CGEventGetType(event(events,0)) == kCGEventLeftMouseUp);
            checkProximity(event(events,1), NO, NSPointingDeviceTypePen);
            NSArray *eraserHover = sendPen(mapper, pen(0,2,.5,.5,0), PLANKMacInputEvent);
            CHECK(eraserHover.count == 1 && CGEventGetType(event(eraserHover,0)) == kCGEventMouseMoved);
            CHECK(CGEventGetIntegerValueField(event(eraserHover,0), kCGMouseEventSubtype) == 0);
            events = sendPen(mapper, pen(1,2,.5,.5,.5), PLANKMacInputEvent);
            CHECK(events.count == 2);
            checkProximity(event(events,0), YES, NSPointingDeviceTypeEraser);
            CHECK(CGEventGetIntegerValueField(event(events,0), kCGTabletProximityEventPointerType) == 3);
            CHECK(CGEventGetType(event(events,1)) == kCGEventLeftMouseDown);
            events = sendPen(mapper, pen(7,0,0,0,0), PLANKMacInputEvent);
            CHECK(events.count == 2 && CGEventGetType(event(events,0)) == kCGEventLeftMouseUp);
            CHECK(CGEventGetIntegerValueField(event(events,1), kCGTabletProximityEventEnterProximity) == 0);
            checkProximity(event(events,1), NO, NSPointingDeviceTypeEraser);
            CHECK(sendPen(mapper,pen(7,0,0,0,0),PLANKMacInputNoEvent).count == 0);
            CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        }
        for (unsigned denied = 0; denied < 2; ++denied) {
            PLANKMacInputEvents *mapper = make(source,bounds[0],pixels[0]);
            __block unsigned calls = 0;
            CHECK([mapper consumeType:7 payload:pen(1,1,.5,.5,.75) time:1 accept:^BOOL(CGEventRef e) {
                CHECK(e); return calls++ < denied;
            }] == PLANKMacInputDenied);
            CHECK(calls == denied + 1);
            NSArray *cleanup = [mapper stopAndCopyReleaseEvents];
            CHECK(cleanup.count == denied); // only accepted proximity, never rejected tip
            if (denied) checkProximity(event(cleanup,0), NO, NSPointingDeviceTypePen);
            CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        }
        PLANKMacInputEvents *mapper = make(source,bounds[0],pixels[0]);
        sendPen(mapper,pen(1,1,.5,.5,.5),PLANKMacInputEvent);
        for (unsigned bit = 1; bit <= 4; bit <<= 1) {
            NSMutableData *p = [pen(5,1,NAN,NAN,NAN) mutableCopy]; ((uint8_t *)p.mutableBytes)[2] = bit;
            NSArray *events = sendPen(mapper,p,PLANKMacInputEvent);
            CHECK(events.count == 1);
            CHECK(CGEventGetType(event(events,0)) == (bit == 1 ? kCGEventRightMouseDown : kCGEventOtherMouseDown));
            CHECK(CGEventGetIntegerValueField(event(events,0),kCGMouseEventButtonNumber) == (bit == 1 ? 2 : bit == 2 ? 1 : 3));
            CHECK(sendPen(mapper,p,PLANKMacInputNoEvent).count == 0);
            ((uint8_t *)p.mutableBytes)[2] = 0;
            events = sendPen(mapper,p,PLANKMacInputEvent);
            CHECK(CGEventGetType(event(events,0)) == (bit == 1 ? kCGEventRightMouseUp : kCGEventOtherMouseUp));
        }
        sendPen(mapper,pen(2,1,.5,.5,0),PLANKMacInputEvent);
        mapper = make(source,bounds[0],pixels[0]);
        for (unsigned click = 1; click <= 3; ++click) {
            NSArray *events = sendPen(mapper,pen(1,1,.5,.5,.5),PLANKMacInputEvent);
            CHECK(CGEventGetIntegerValueField(event(events, events.count - 1),kCGMouseEventClickState) == click);
            sendPen(mapper,pen(2,1,.5,.5,0),PLANKMacInputEvent);
        }
        CHECK(sendPen(mapper,pen(7,0,0,0,0),PLANKMacInputNoEvent).count == 0);
        NSArray *events = sendPen(mapper,pen(1,1,.5,.5,.5),PLANKMacInputEvent);
        CHECK(events.count == 2);
        uint8_t mouse[8];
        plank_transport_input_encode_absolute_mouse(mouse, 5, 5, 10, 10);
        NSMutableArray *mouseEvents = [NSMutableArray array];
        CHECK([mapper consumeType:1 payload:[NSData dataWithBytes:mouse length:8] time:nextPenTime()
            accept:^BOOL(CGEventRef event) { [mouseEvents addObject:(__bridge id)event]; return YES; }] == PLANKMacInputEvent);
        CHECK(mouseEvents.count >= 2);
        CHECK(CGEventGetType(event(mouseEvents,0)) == kCGEventLeftMouseUp);
        checkProximity(event(mouseEvents, mouseEvents.count - 2), NO, NSPointingDeviceTypePen);
        CHECK(CGEventGetType(event(mouseEvents, mouseEvents.count - 1)) == kCGEventMouseMoved);
        sendPen(mapper,pen(1,1,.5,.5,.5),PLANKMacInputEvent);
        NSMutableArray *buttonEvents = [NSMutableArray array];
        uint8_t button[2] = {1, 1};
        CHECK([mapper consumeType:2 payload:[NSData dataWithBytes:button length:2] time:nextPenTime()
            accept:^BOOL(CGEventRef event) { [buttonEvents addObject:(__bridge id)event]; return YES; }] == PLANKMacInputEvent);
        CHECK(buttonEvents.count >= 2);
        checkProximity(event(buttonEvents, buttonEvents.count - 2), NO, NSPointingDeviceTypePen);
        uint8_t buttonUp[2] = {1, 0};
        CHECK([mapper consumeType:2 payload:[NSData dataWithBytes:buttonUp length:2] time:nextPenTime()
            accept:^BOOL(CGEventRef event) { (void)event; return YES; }] == PLANKMacInputEvent);
        for (unsigned length = 0; length < 34; ++length) if (length != 32)
            CHECK(sendPen(mapper,[NSMutableData dataWithLength:length],PLANKMacInputMalformed).count == 0);
        for (unsigned offset = 8; offset <= 24; offset += 4) for (NSNumber *bad in @[@(NAN), @(INFINITY), @(-.1), @1.1]) {
            NSMutableData *p = [pen(1,1,.5,.5,.5) mutableCopy];
            plank_transport_input_write_float((uint8_t *)p.mutableBytes + offset,bad.floatValue);
            CHECK(sendPen(mapper,p,PLANKMacInputMalformed).count == 0);
        }
        for (unsigned offset = 6; offset < 32; ++offset) if (offset < 8 || offset >= 28) {
            NSMutableData *p = [pen(1,1,.5,.5,.5) mutableCopy]; ((uint8_t *)p.mutableBytes)[offset] = 1;
            CHECK(sendPen(mapper,p,PLANKMacInputMalformed).count == 0);
        }
        sendPen(mapper,pen(1,1,.5,.5,.75),PLANKMacInputEvent);
        NSArray *cleanup = [mapper stopAndCopyReleaseEvents];
        CHECK(cleanup.count == 2 && CGEventGetType(event(cleanup,0)) == kCGEventLeftMouseUp);
        CHECK(CGEventGetDoubleValueField(event(cleanup,0),kCGTabletEventPointPressure) == 0);
        checkProximity(event(cleanup,1), NO, NSPointingDeviceTypePen);
        CHECK([mapper stopAndCopyReleaseEvents].count == 0);
        CHECK(sendPen(mapper,pen(0,1,0,0,0),PLANKMacInputStopped).count == 0);
        CFRelease(source);
        printf("macos_pen_events_pass checks=%u posted=0\n",checks);
    }
}
