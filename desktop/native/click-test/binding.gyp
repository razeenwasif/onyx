{ "targets": [ { "target_name": "probe", "sources": ["probe.mm"], "defines": ["NAPI_VERSION=8"],
  "xcode_settings": { "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_CXX_LANGUAGE_STANDARD": "c++17", "MACOSX_DEPLOYMENT_TARGET": "12.0", "OTHER_LDFLAGS": ["-framework", "AppKit"] } } ] }
