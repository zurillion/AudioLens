#ifndef CRUBBERBAND_SHIM_H
#define CRUBBERBAND_SHIM_H

// Rubber Band's public C API. The header lives in the vendored submodule;
// reach it via relative include so we don't depend on header-search-path
// configuration leaking from cxxSettings into the publicHeaders module.
#include "../../../rubberband/rubberband/rubberband-c.h"

#endif
