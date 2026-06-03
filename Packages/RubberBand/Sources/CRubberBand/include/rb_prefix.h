#ifndef CRUBBERBAND_PREFIX_H
#define CRUBBERBAND_PREFIX_H

// Force-included before every translation unit of the Rubber Band build.
// Several Rubber Band headers (mathmisc.h, etc.) use bare `size_t` and other
// std-namespace types without `std::` prefix or an explicit `<cstddef>`
// include. The upstream meson build only gets away with it via transitive
// inclusion side-effects that don't fire in some SwiftPM compile orders, so
// the same source fails here with "Unknown type name 'size_t'".
//
// Pull the relevant types into the global namespace once, up front.

#ifdef __cplusplus
#include <cstddef>
#include <cstdint>
using std::size_t;
using std::ptrdiff_t;
#endif

#endif
