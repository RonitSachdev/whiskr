/* Oniguruma's build configuration for macOS (arm64 and x86_64), written by hand in place of the one its
   CMake or configure script generates. */
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_STDINT_H 1
#define HAVE_SYS_TIMES_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_INTTYPES_H 1
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOIDP 8
#define PACKAGE "onig"
#define PACKAGE_VERSION "6.9.10"
#define VERSION "6.9.10"

/* Oniguruma is vendored as released: the app's warning settings (64-to-32 conversions and the like) are
   not applied to its code. Every one of its files includes this one first. */
#pragma clang diagnostic ignored "-Weverything"
