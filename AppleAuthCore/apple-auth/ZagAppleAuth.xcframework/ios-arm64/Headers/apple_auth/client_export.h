#ifndef APPLE_AUTH_CLIENT_EXPORT_H
#define APPLE_AUTH_CLIENT_EXPORT_H
#ifdef APPLE_AUTH_CLIENT_STATIC_DEFINE
#  define APPLE_AUTH_CLIENT_EXPORT
#  define APPLE_AUTH_CLIENT_NO_EXPORT
#else
#  define APPLE_AUTH_CLIENT_EXPORT __attribute__((visibility("default")))
#  define APPLE_AUTH_CLIENT_NO_EXPORT __attribute__((visibility("hidden")))
#endif
#endif
