// scribe-bridge: puts Scribe's native view inside Electron's window (macOS).
//
// Scribe's interface is SwiftUI/AppKit, built as libScribeEmbed.dylib from
// ../../scribe. This addon loads that library, asks it for its NSView, and
// adds the view over the BrowserWindow's web contents. Switching apps just
// shows or hides it. N-API keeps the addon ABI-stable, so the same build
// loads in any Electron (and plain Node, for tests).
//
// All calls arrive on the main thread: Electron's main-process JS runs there.

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <node_api.h>

#include <string>

typedef void *(*CreateViewFn)(const char *, const char *, const char *);
typedef void (*SetActiveFn)(bool);
typedef bool (*PerformFn)(const char *);
typedef const char *(*MenuJsonFn)(void);
typedef void (*SetSwitchHandlerFn)(void (*)(void));
typedef char *(*SearchFn)(const char *);
typedef void (*FreeFn)(char *);
typedef void (*OpenFn)(const char *);
typedef char *(*LinkIndexFn)(void);
typedef void (*SetHandlerFn)(void (*)(void));
typedef void (*OpenLinkFn)(const char *, double, double, double, double);
typedef void (*SetVaultFn)(const char *);
typedef void (*SetOpenNoteHandlerFn)(void (*)(const char *));
typedef void (*CardFn)(const char *, double, double, double, double, int32_t, void *, void (*)(void *, const char *));

static void *library = nullptr;
static CreateViewFn createView = nullptr;
static SetActiveFn setActive = nullptr;
static PerformFn performAction = nullptr;
static MenuJsonFn menuJson = nullptr;
static SetSwitchHandlerFn setSwitchHandler = nullptr;
static SearchFn searchPages = nullptr;
static FreeFn freeString = nullptr;
static OpenFn openPage = nullptr;
static LinkIndexFn linkIndex = nullptr;
static SetHandlerFn setLinksChangedHandler = nullptr;
static OpenLinkFn openLink = nullptr;
static SetVaultFn setVault = nullptr;
static SetOpenNoteHandlerFn setOpenNoteHandler = nullptr;
static CardFn drawCard = nullptr;

static NSView *scribeView = nil;
static napi_threadsafe_function switchCallback = nullptr;
static napi_threadsafe_function linksCallback = nullptr;
static napi_threadsafe_function openNoteCallback = nullptr;

// ---------------------------------------------------------------- helpers

static napi_value Fail(napi_env env, const char *message) {
  napi_throw_error(env, nullptr, message);
  return nullptr;
}

static bool Args(napi_env env, napi_callback_info info, size_t want, napi_value *argv) {
  size_t argc = want;
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < want) {
    napi_throw_type_error(env, nullptr, "missing arguments");
    return false;
  }
  return true;
}

static std::string ToStdString(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return "";
  std::string out(length, '\0');
  napi_get_value_string_utf8(env, value, out.data(), length + 1, &length);
  return out;
}

static napi_value ToJsBool(napi_env env, bool value) {
  napi_value out;
  napi_get_boolean(env, value, &out);
  return out;
}

static bool Ready(napi_env env) {
  if (library && scribeView) return true;
  napi_throw_error(env, nullptr, "Scribe isn't attached to a window yet");
  return false;
}

// -------------------------------------------------------------------- API

/** load(dylibPath): open libScribeEmbed and resolve its entry points. */
static napi_value Load(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv)) return nullptr;
  if (library) return nullptr;

  std::string path = ToStdString(env, argv[0]);
  void *handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!handle) return Fail(env, dlerror());

  createView = (CreateViewFn)dlsym(handle, "scribe_embed_create_view");
  setActive = (SetActiveFn)dlsym(handle, "scribe_embed_set_active");
  performAction = (PerformFn)dlsym(handle, "scribe_embed_perform");
  menuJson = (MenuJsonFn)dlsym(handle, "scribe_embed_menu_json");
  setSwitchHandler = (SetSwitchHandlerFn)dlsym(handle, "scribe_embed_set_switch_handler");
  searchPages = (SearchFn)dlsym(handle, "scribe_embed_search");
  freeString = (FreeFn)dlsym(handle, "scribe_embed_free");
  openPage = (OpenFn)dlsym(handle, "scribe_embed_open");
  linkIndex = (LinkIndexFn)dlsym(handle, "scribe_embed_link_index");
  setLinksChangedHandler = (SetHandlerFn)dlsym(handle, "scribe_embed_set_links_changed_handler");
  openLink = (OpenLinkFn)dlsym(handle, "scribe_embed_open_link");
  setVault = (SetVaultFn)dlsym(handle, "scribe_embed_set_vault");
  setOpenNoteHandler = (SetOpenNoteHandlerFn)dlsym(handle, "scribe_embed_set_open_note_handler");
  // Optional: a library without cards still loads; card() then finds nothing.
  drawCard = (CardFn)dlsym(handle, "scribe_embed_card");
  if (!createView || !setActive || !performAction || !menuJson || !setSwitchHandler || !searchPages ||
      !freeString || !openPage || !linkIndex || !setLinksChangedHandler || !openLink || !setVault ||
      !setOpenNoteHandler) {
    dlclose(handle);
    return Fail(env, "libScribeEmbed is missing an entry point; rebuild it with scripts/build-scribe.sh");
  }
  library = handle;
  return nullptr;
}

/**
 * attach(nativeWindowHandle, hostName, hostIconPath, scribeIconPath): add
 * Scribe's view, hidden, over the window's content. The handle is
 * `BrowserWindow.getNativeWindowHandle()`, an NSView * on macOS. Attaching to
 * a new window (macOS re-creates it after the last one closes) moves the view.
 */
static napi_value Attach(napi_env env, napi_callback_info info) {
  napi_value argv[4];
  if (!Args(env, info, 4, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");

  void *data = nullptr;
  size_t length = 0;
  if (napi_get_buffer_info(env, argv[0], &data, &length) != napi_ok || length < sizeof(void *)) {
    return Fail(env, "expected the window's native handle");
  }
  NSView *content = (__bridge NSView *)(*(void **)data);
  if (![content isKindOfClass:NSView.class]) return Fail(env, "the native handle isn't an NSView");

  if (!scribeView) {
    std::string name = ToStdString(env, argv[1]);
    std::string hostIcon = ToStdString(env, argv[2]);
    std::string scribeIcon = ToStdString(env, argv[3]);
    scribeView = (__bridge_transfer NSView *)createView(name.c_str(), hostIcon.c_str(), scribeIcon.c_str());
  }
  [scribeView removeFromSuperview];
  scribeView.frame = content.bounds;
  scribeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scribeView.hidden = YES;
  [content addSubview:scribeView positioned:NSWindowAbove relativeTo:nil];
  return nullptr;
}

/**
 * setVisible(visible): show Scribe and give it the keyboard, or hide it and
 * hand focus back (the caller then focuses the web contents). Scribe saves
 * whenever it's hidden. What's hidden is the plain container Scribe returns,
 * which is what stops a hidden Scribe from catching clicks (see
 * scribe_embed_create_view).
 */
static napi_value SetVisible(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv) || !Ready(env)) return nullptr;
  bool visible = false;
  napi_get_value_bool(env, argv[0], &visible);

  NSWindow *window = scribeView.window;
  if (visible) {
    scribeView.hidden = NO;
    setActive(true);
    // scribeView is a plain container; the keyboard goes to the SwiftUI
    // hosting view inside it.
    [window makeFirstResponder:scribeView.subviews.firstObject ?: scribeView];
  } else {
    NSResponder *responder = window.firstResponder;
    if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:scribeView]) {
      [window makeFirstResponder:nil];
    }
    scribeView.hidden = YES;
    setActive(false);
  }
  return nullptr;
}

/** perform(actionId): run one of Scribe's menu actions; false if unknown. */
static napi_value Perform(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv) || !Ready(env)) return nullptr;
  std::string id = ToStdString(env, argv[0]);
  return ToJsBool(env, performAction(id.c_str()));
}

/** search(query): Scribe's pages matching `query`, as a JSON string. */
static napi_value Search(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");
  std::string query = ToStdString(env, argv[0]);
  char *json = searchPages(query.c_str());
  napi_value out;
  napi_create_string_utf8(env, json ? json : "[]", NAPI_AUTO_LENGTH, &out);
  freeString(json);
  return out;
}

/** open(pagePath): open one of Scribe's pages (the caller then shows Scribe). */
static napi_value Open(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv) || !Ready(env)) return nullptr;
  std::string path = ToStdString(env, argv[0]);
  openPage(path.c_str());
  return nullptr;
}

/** menu(): Scribe's menus as JSON, for the application menu. */
static napi_value Menu(napi_env env, napi_callback_info info) {
  if (!library) return Fail(env, "call load() first");
  napi_value out;
  napi_create_string_utf8(env, menuJson(), NAPI_AUTO_LENGTH, &out);
  return out;
}

static void CallSwitch(napi_env env, napi_value callback, void *, void *) {
  if (!env || !callback) return;
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  napi_call_function(env, undefined, callback, 0, nullptr, nullptr);
}

static void SwitchRequested(void) {
  if (switchCallback) napi_call_threadsafe_function(switchCallback, nullptr, napi_tsfn_nonblocking);
}

/** onSwitch(callback): called when the host's icon in Scribe's switcher is clicked. */
static napi_value OnSwitch(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");
  if (switchCallback) napi_release_threadsafe_function(switchCallback, napi_tsfn_release);

  napi_value name;
  napi_create_string_utf8(env, "scribe-switch", NAPI_AUTO_LENGTH, &name);
  napi_create_threadsafe_function(env, argv[0], nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallSwitch,
                                  &switchCallback);
  // Don't keep the process alive just because Scribe might call back.
  napi_unref_threadsafe_function(env, switchCallback);
  setSwitchHandler(SwitchRequested);
  return nullptr;
}

/** links(): every Scribe page with its id and the links typed on it, as a JSON string. */
static napi_value Links(napi_env env, napi_callback_info info) {
  if (!library) return Fail(env, "call load() first");
  char *json = linkIndex();
  napi_value out;
  napi_create_string_utf8(env, json ? json : "[]", NAPI_AUTO_LENGTH, &out);
  freeString(json);
  return out;
}

static void LinksChanged(void) {
  if (linksCallback) napi_call_threadsafe_function(linksCallback, nullptr, napi_tsfn_nonblocking);
}

/** onLinksChanged(callback): Scribe's link index changed; call links() again. */
static napi_value OnLinksChanged(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");
  if (linksCallback) napi_release_threadsafe_function(linksCallback, napi_tsfn_release);
  napi_value name;
  napi_create_string_utf8(env, "scribe-links", NAPI_AUTO_LENGTH, &name);
  napi_create_threadsafe_function(env, argv[0], nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallSwitch,
                                  &linksCallback);
  napi_unref_threadsafe_function(env, linksCallback);
  setLinksChangedHandler(LinksChanged);
  return nullptr;
}

/** openLink(pageId, x, y, width, height): open a page; a positive size also shows that area. */
static napi_value OpenLink(napi_env env, napi_callback_info info) {
  napi_value argv[5];
  if (!Args(env, info, 5, argv) || !Ready(env)) return nullptr;
  std::string id = ToStdString(env, argv[0]);
  double area[4] = {0, 0, 0, 0};
  for (int i = 0; i < 4; i++) napi_get_value_double(env, argv[i + 1], &area[i]);
  openLink(id.c_str(), area[0], area[1], area[2], area[3]);
  return nullptr;
}

// One card() call in flight: the promise it returns, settled back on the JS
// thread once Scribe has drawn (or failed to draw) the card.
struct CardRequest {
  napi_deferred deferred;
  napi_threadsafe_function done;
  std::string path;
};

static void SettleCard(napi_env env, napi_value, void *, void *data) {
  CardRequest *request = static_cast<CardRequest *>(data);
  if (env) {
    napi_value path;
    napi_create_string_utf8(env, request->path.c_str(), NAPI_AUTO_LENGTH, &path);
    napi_resolve_deferred(env, request->deferred, path);
  }
  napi_release_threadsafe_function(request->done, napi_tsfn_release);
  delete request;
}

static void CardDrawn(void *context, const char *path) {
  CardRequest *request = static_cast<CardRequest *>(context);
  request->path = path ? path : "";
  napi_call_threadsafe_function(request->done, request, napi_tsfn_blocking);
}

/**
 * card(pageId, x, y, width, height, pixels): a promise of the path of a PNG
 * showing the page (or, with a positive size, that area of it), `pixels`
 * wide; "" when the page isn't there.
 */
static napi_value Card(napi_env env, napi_callback_info info) {
  napi_value argv[6];
  if (!Args(env, info, 6, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");
  std::string id = ToStdString(env, argv[0]);
  double area[4] = {0, 0, 0, 0};
  for (int i = 0; i < 4; i++) napi_get_value_double(env, argv[i + 1], &area[i]);
  int32_t pixels = 0;
  napi_get_value_int32(env, argv[5], &pixels);

  napi_value promise;
  auto *request = new CardRequest();
  napi_create_promise(env, &request->deferred, &promise);
  if (!drawCard) {
    napi_value empty;
    napi_create_string_utf8(env, "", 0, &empty);
    napi_resolve_deferred(env, request->deferred, empty);
    delete request;
    return promise;
  }
  napi_value name;
  napi_create_string_utf8(env, "scribe-card", NAPI_AUTO_LENGTH, &name);
  napi_create_threadsafe_function(env, nullptr, nullptr, name, 0, 1, nullptr, nullptr, nullptr, SettleCard,
                                  &request->done);
  drawCard(id.c_str(), area[0], area[1], area[2], area[3], pixels, request, CardDrawn);
  return promise;
}

/** setVault(path): the Markdown vault, so Scribe can list notes linking to a page. */
static napi_value SetVault(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");
  std::string path = ToStdString(env, argv[0]);
  setVault(path.c_str());
  return nullptr;
}

static void CallOpenNote(napi_env env, napi_value callback, void *, void *data) {
  std::string *path = static_cast<std::string *>(data);
  if (env && callback) {
    napi_value undefined, arg;
    napi_get_undefined(env, &undefined);
    napi_create_string_utf8(env, path->c_str(), NAPI_AUTO_LENGTH, &arg);
    napi_call_function(env, undefined, callback, 1, &arg, nullptr);
  }
  delete path;
}

static void OpenNoteRequested(const char *path) {
  if (!openNoteCallback) return;
  auto *copy = new std::string(path);
  if (napi_call_threadsafe_function(openNoteCallback, copy, napi_tsfn_nonblocking) != napi_ok) delete copy;
}

/** onOpenNote(callback): called with a vault-relative path when a page's "Linked from" note is picked. */
static napi_value OnOpenNote(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv)) return nullptr;
  if (!library) return Fail(env, "call load() first");
  if (openNoteCallback) napi_release_threadsafe_function(openNoteCallback, napi_tsfn_release);
  napi_value name;
  napi_create_string_utf8(env, "scribe-open-note", NAPI_AUTO_LENGTH, &name);
  napi_create_threadsafe_function(env, argv[0], nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallOpenNote,
                                  &openNoteCallback);
  napi_unref_threadsafe_function(env, openNoteCallback);
  setOpenNoteHandler(OpenNoteRequested);
  return nullptr;
}

/**
 * snapshot(pngPath): render Scribe's view to a PNG. For screenshots while
 * it's showing (webContents.capturePage only sees the web layer under it).
 */
static napi_value Snapshot(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!Args(env, info, 1, argv) || !Ready(env)) return nullptr;
  std::string path = ToStdString(env, argv[0]);
  NSRect bounds = scribeView.bounds;
  NSBitmapImageRep *rep = [scribeView bitmapImageRepForCachingDisplayInRect:bounds];
  if (!rep) return ToJsBool(env, false);
  [scribeView cacheDisplayInRect:bounds toBitmapImageRep:rep];
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return ToJsBool(env, [png writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES]);
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor props[] = {
      {"load", nullptr, Load, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"attach", nullptr, Attach, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setVisible", nullptr, SetVisible, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"perform", nullptr, Perform, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"menu", nullptr, Menu, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"search", nullptr, Search, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"open", nullptr, Open, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"onSwitch", nullptr, OnSwitch, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"snapshot", nullptr, Snapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"links", nullptr, Links, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"onLinksChanged", nullptr, OnLinksChanged, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"openLink", nullptr, OpenLink, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setVault", nullptr, SetVault, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"onOpenNote", nullptr, OnOpenNote, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"card", nullptr, Card, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
