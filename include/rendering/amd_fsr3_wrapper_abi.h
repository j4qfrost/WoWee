#pragma once

#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WOWEE_FSR3_WRAPPER_ABI_VERSION 1u

typedef void* WoweeFsr3WrapperContext;

typedef struct WoweeFsr3WrapperInitDesc {
    uint32_t structSize;
    uint32_t abiVersion;
    VkPhysicalDevice physicalDevice;
    VkDevice device;
    PFN_vkGetDeviceProcAddr getDeviceProcAddr;
    uint32_t maxRenderWidth;
    uint32_t maxRenderHeight;
    uint32_t displayWidth;
    uint32_t displayHeight;
    VkFormat colorFormat;
    uint32_t enableFlags;
} WoweeFsr3WrapperInitDesc;

typedef struct WoweeFsr3WrapperDispatchDesc {
    uint32_t structSize;
    VkCommandBuffer commandBuffer;
    VkImage colorImage;
    VkImage depthImage;
    VkImage motionVectorImage;
    VkImage outputImage;
    VkImage frameGenOutputImage;
    uint32_t renderWidth;
    uint32_t renderHeight;
    uint32_t outputWidth;
    uint32_t outputHeight;
    VkFormat colorFormat;
    VkFormat depthFormat;
    VkFormat motionVectorFormat;
    VkFormat outputFormat;
    float jitterX;
    float jitterY;
    float motionScaleX;
    float motionScaleY;
    float frameTimeDeltaMs;
    float cameraNear;
    float cameraFar;
    float cameraFovYRadians;
    uint32_t reset;
} WoweeFsr3WrapperDispatchDesc;

enum {
    WOWEE_FSR3_WRAPPER_ENABLE_HDR_INPUT = 1u << 0,
    WOWEE_FSR3_WRAPPER_ENABLE_DEPTH_INVERTED = 1u << 1,
    WOWEE_FSR3_WRAPPER_ENABLE_FRAME_GENERATION = 1u << 2
};

uint32_t wowee_fsr3_wrapper_get_abi_version(void);
const char* wowee_fsr3_wrapper_get_name(void);
int32_t wowee_fsr3_wrapper_initialize(const WoweeFsr3WrapperInitDesc* initDesc,
                                      WoweeFsr3WrapperContext* outContext,
                                      char* outErrorText,
                                      uint32_t outErrorTextCapacity);
int32_t wowee_fsr3_wrapper_dispatch_upscale(WoweeFsr3WrapperContext context,
                                            const WoweeFsr3WrapperDispatchDesc* dispatchDesc);
int32_t wowee_fsr3_wrapper_dispatch_framegen(WoweeFsr3WrapperContext context,
                                             const WoweeFsr3WrapperDispatchDesc* dispatchDesc);
void wowee_fsr3_wrapper_shutdown(WoweeFsr3WrapperContext context);

#ifdef __cplusplus
}
#endif
