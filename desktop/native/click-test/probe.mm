// Test-only probe: describe a window's view tree and post synthetic clicks.
#import <AppKit/AppKit.h>
#include <node_api.h>
#include <string>
static NSView *Content(napi_env env, napi_value v) { void *d; size_t n; napi_get_buffer_info(env, v, &d, &n); return (__bridge NSView *)(*(void **)d); }
static double Num(napi_env env, napi_value v) { double x = 0; napi_get_value_double(env, v, &x); return x; }
static NSPoint WindowPoint(NSView *content, double x, double y) {
  NSPoint p = content.isFlipped ? NSMakePoint(x, y) : NSMakePoint(x, content.bounds.size.height - y);
  return [content convertPoint:p toView:nil];
}
static napi_value Describe(napi_env env, napi_callback_info info) {
  size_t argc = 3; napi_value a[3]; napi_get_cb_info(env, info, &argc, a, nullptr, nullptr);
  NSView *content = Content(env, a[0]); NSWindow *w = content.window;
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"window %@ movableBg=%d movable=%d\n", w.className, w.isMovableByWindowBackground, w.isMovable];
  [s appendFormat:@"content %@ flipped=%d frame=%@\n", content.className, content.isFlipped, NSStringFromRect(content.frame)];
  for (NSView *v in content.subviews) [s appendFormat:@"  sub %@ hidden=%d frame=%@ subs=%lu\n", v.className, v.isHidden, NSStringFromRect(v.frame), (unsigned long)v.subviews.count];
  NSPoint wp = WindowPoint(content, Num(env, a[1]), Num(env, a[2]));
  NSView *hit = [content.superview hitTest:[content.superview convertPoint:wp fromView:nil]];
  [s appendString:@"hit chain:"];
  for (NSView *v = hit; v; v = v.superview) [s appendFormat:@" %@(canMove=%d)", v.className, v.mouseDownCanMoveWindow];
  napi_value out; napi_create_string_utf8(env, s.UTF8String, NAPI_AUTO_LENGTH, &out); return out;
}
static napi_value AddPlain(napi_env env, napi_callback_info info) {
  size_t argc = 1; napi_value a[1]; napi_get_cb_info(env, info, &argc, a, nullptr, nullptr);
  NSView *content = Content(env, a[0]);
  NSView *v = [[NSView alloc] initWithFrame:content.bounds]; v.hidden = YES; v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:v positioned:NSWindowAbove relativeTo:nil]; return nullptr;
}
static napi_value PostClick(napi_env env, napi_callback_info info) {
  size_t argc = 3; napi_value a[3]; napi_get_cb_info(env, info, &argc, a, nullptr, nullptr);
  NSView *content = Content(env, a[0]); NSWindow *w = content.window;
  NSPoint wp = WindowPoint(content, Num(env, a[1]), Num(env, a[2]));
  NSTimeInterval t = [[NSProcessInfo processInfo] systemUptime];
  for (NSEventType type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
    NSEvent *e = [NSEvent mouseEventWithType:type location:wp modifierFlags:0 timestamp:t windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [NSApp postEvent:e atStart:NO];
  }
  return nullptr;
}
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor p[] = {
    {"describe", nullptr, Describe, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"addPlain", nullptr, AddPlain, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"postClick", nullptr, PostClick, nullptr, nullptr, nullptr, napi_default, nullptr}};
  napi_define_properties(env, exports, 3, p); return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
