#ifndef APPLE_AUTH_EXPORT_H
#define APPLE_AUTH_EXPORT_H
#ifdef APPLE_AUTH_STATIC_DEFINE
#  define APPLE_AUTH_EXPORT
#  define APPLE_AUTH_NO_EXPORT
#else
#  define APPLE_AUTH_EXPORT __attribute__((visibility("default")))
#  define APPLE_AUTH_NO_EXPORT __attribute__((visibility("hidden")))
#endif
#ifndef APPLE_AUTH_DEPRECATED
#  define APPLE_AUTH_DEPRECATED __attribute__((__deprecated__))
#endif
#ifndef APPLE_AUTH_DEPRECATED_EXPORT
#  define APPLE_AUTH_DEPRECATED_EXPORT APPLE_AUTH_EXPORT APPLE_AUTH_DEPRECATED
#endif
#ifndef APPLE_AUTH_DEPRECATED_NO_EXPORT
#  define APPLE_AUTH_DEPRECATED_NO_EXPORT APPLE_AUTH_NO_EXPORT APPLE_AUTH_DEPRECATED
#endif
#endif
