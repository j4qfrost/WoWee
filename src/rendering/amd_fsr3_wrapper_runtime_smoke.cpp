#include "rendering/amd_fsr3_wrapper_abi.h"

#include <cstdint>
#include <cstring>
#include <iostream>

#if defined(_WIN32)
#include <windows.h>
using LibHandle = HMODULE;
static LibHandle openLibrary(const char* path) { return LoadLibraryA(path); }
static void* loadSymbol(LibHandle lib, const char* name) {
    return lib ? reinterpret_cast<void*>(GetProcAddress(lib, name)) : nullptr;
}
static void closeLibrary(LibHandle lib) {
    if (lib) FreeLibrary(lib);
}
#else
#include <dlfcn.h>
using LibHandle = void*;
static LibHandle openLibrary(const char* path) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); }
static void* loadSymbol(LibHandle lib, const char* name) { return lib ? dlsym(lib, name) : nullptr; }
static void closeLibrary(LibHandle lib) {
    if (lib) dlclose(lib);
}
#endif

int main(int argc, char** argv) {
    const char* libPath = (argc > 1) ? argv[1]
#if defined(_WIN32)
        : "ffx_fsr3_vk_wrapper.dll";
#elif defined(__APPLE__)
        : "libffx_fsr3_vk_wrapper.dylib";
#else
        : "./build/bin/libffx_fsr3_vk_wrapper.so";
#endif

    LibHandle lib = openLibrary(libPath);
    if (!lib) {
        std::cerr << "smoke: failed to load wrapper library: " << libPath << "\n";
        return 2;
    }

    auto getAbiVersion = reinterpret_cast<uint32_t (*)()>(
        loadSymbol(lib, "wowee_fsr3_wrapper_get_abi_version"));
    auto getName = reinterpret_cast<const char* (*)()>(
        loadSymbol(lib, "wowee_fsr3_wrapper_get_name"));
    auto getBackend = reinterpret_cast<const char* (*)(WoweeFsr3WrapperContext)>(
        loadSymbol(lib, "wowee_fsr3_wrapper_get_backend"));
    auto getCaps = reinterpret_cast<uint32_t (*)(WoweeFsr3WrapperContext)>(
        loadSymbol(lib, "wowee_fsr3_wrapper_get_capabilities"));
    auto initialize = reinterpret_cast<int32_t (*)(const WoweeFsr3WrapperInitDesc*, WoweeFsr3WrapperContext*, char*, uint32_t)>(
        loadSymbol(lib, "wowee_fsr3_wrapper_initialize"));
    auto dispatchUpscale = reinterpret_cast<int32_t (*)(WoweeFsr3WrapperContext, const WoweeFsr3WrapperDispatchDesc*)>(
        loadSymbol(lib, "wowee_fsr3_wrapper_dispatch_upscale"));
    auto shutdown = reinterpret_cast<void (*)(WoweeFsr3WrapperContext)>(
        loadSymbol(lib, "wowee_fsr3_wrapper_shutdown"));

    if (!getAbiVersion || !getName || !getBackend || !getCaps || !initialize || !dispatchUpscale || !shutdown) {
        std::cerr << "smoke: required wrapper ABI symbol(s) missing\n";
        closeLibrary(lib);
        return 3;
    }

    const uint32_t abi = getAbiVersion();
    if (abi != WOWEE_FSR3_WRAPPER_ABI_VERSION) {
        std::cerr << "smoke: ABI mismatch: got " << abi
                  << ", expected " << WOWEE_FSR3_WRAPPER_ABI_VERSION << "\n";
        closeLibrary(lib);
        return 4;
    }

    const char* name = getName();
    if (!name || !*name) {
        std::cerr << "smoke: wrapper name is empty\n";
        closeLibrary(lib);
        return 5;
    }

    const char* backendNull = getBackend(nullptr);
    if (!backendNull || !*backendNull) {
        std::cerr << "smoke: get_backend(null) returned empty\n";
        closeLibrary(lib);
        return 6;
    }

    const uint32_t capsNull = getCaps(nullptr);
    if (capsNull != 0u) {
        std::cerr << "smoke: expected get_capabilities(null)=0, got " << capsNull << "\n";
        closeLibrary(lib);
        return 7;
    }

    char errorBuf[128] = {};
    WoweeFsr3WrapperContext ctx = nullptr;
    const int32_t initRes = initialize(nullptr, &ctx, errorBuf, static_cast<uint32_t>(sizeof(errorBuf)));
    if (initRes == 0) {
        std::cerr << "smoke: initialize(nullptr, ...) unexpectedly succeeded\n";
        shutdown(ctx);
        closeLibrary(lib);
        return 8;
    }

    std::cout << "smoke: OK abi=" << abi << " name=" << name
              << " backend(null)=" << backendNull << "\n";
    closeLibrary(lib);
    return 0;
}
