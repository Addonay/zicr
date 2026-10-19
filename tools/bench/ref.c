/* C sokol baseline. Keep workload and validation settings equal to main.zig. */
#define SOKOL_GFX_IMPL
#if defined(ZICR_BENCH_D3D11)
#define COBJMACROS
#define SOKOL_D3D11
#elif defined(ZICR_BENCH_METAL)
#define SOKOL_METAL
#elif defined(ZICR_BENCH_WGPU)
#define SOKOL_WGPU
#elif defined(ZICR_BENCH_VULKAN)
#define SOKOL_VULKAN
#else
#define GL_GLEXT_PROTOTYPES
#define SOKOL_GLCORE
#endif
#define SOKOL_TRACE_HOOKS
#include "ref.h"
#include <string.h>
static sg_buffer vertices[2], upload;
static sg_image image;
static sg_view attachment;
static sg_shader shader;
static sg_pipeline pipeline;
#if defined(SOKOL_GLCORE)
static GLuint read_fbo;
#endif

static void begin(void) {
    sg_pass pass = {0};
    pass.attachments.colors[0] = attachment;
    pass.action.colors[0].load_action = SG_LOADACTION_CLEAR;
    pass.action.colors[0].clear_value.a = 1.0f;
    sg_begin_pass(&pass);
}

bool bench_ref_setup(const sg_desc *desc, const sg_shader_desc *shader_desc, const float *positions,
                     size_t bytes) {
    sg_setup(desc);
    if (!sg_isvalid())
        return false;
    sg_disable_stats();
    sg_buffer_desc vb = {0};
    vb.usage.vertex_buffer = true;
    vb.data = (sg_range){positions, 6 * sizeof(float)};
    vertices[0] = sg_make_buffer(&vb);
    vertices[1] = sg_make_buffer(&vb);
    sg_buffer_desc ub = {0};
    ub.size = bytes;
    ub.usage.vertex_buffer = true;
    ub.usage.copy_src = true;
    ub.usage.write_transient = true;
    upload = sg_make_buffer(&ub);
    sg_image_desc target = {0};
    target.width = 1;
    target.height = 1;
    target.pixel_format = SG_PIXELFORMAT_RGBA8;
    target.usage.color_attachment = true;
    target.usage.copy_src = true;
#if defined(SOKOL_WGPU)
    /* This pinned upstream does not add COPY_SRC to image usage. Inject the
     * equivalent native target via its public API for out-of-timing readback;
     * do not patch the C backend being measured. */
    WGPUTextureDescriptor native_target = WGPU_TEXTURE_DESCRIPTOR_INIT;
    native_target.usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_RenderAttachment |
                          WGPUTextureUsage_CopySrc;
    native_target.dimension = WGPUTextureDimension_2D;
    native_target.size = (WGPUExtent3D){1, 1, 1};
    native_target.format = WGPUTextureFormat_RGBA8Unorm;
    native_target.mipLevelCount = 1;
    native_target.sampleCount = 1;
    WGPUTexture read_texture =
        wgpuDeviceCreateTexture((WGPUDevice)desc->environment.wgpu.device, &native_target);
    if (!read_texture) {
        sg_shutdown();
        return false;
    }
    target.wgpu_texture = read_texture;
#endif
    image = sg_make_image(&target);
#if defined(SOKOL_WGPU)
    wgpuTextureRelease(read_texture); /* sg_make_image retained its own reference */
#endif
    sg_view_desc view = {0};
    view.color_attachment.image = image;
    attachment = sg_make_view(&view);
    shader = sg_make_shader(shader_desc);
    sg_pipeline_desc pip = {0};
    pip.shader = shader;
    pip.layout.attrs[0].format = SG_VERTEXFORMAT_FLOAT2;
    pip.colors[0].pixel_format = SG_PIXELFORMAT_RGBA8;
    pip.depth.pixel_format = SG_PIXELFORMAT_NONE;
    pipeline = sg_make_pipeline(&pip);
    bool valid = sg_query_buffer_state(vertices[0]) == SG_RESOURCESTATE_VALID &&
                 sg_query_buffer_state(vertices[1]) == SG_RESOURCESTATE_VALID &&
                 sg_query_buffer_state(upload) == SG_RESOURCESTATE_VALID &&
                 sg_query_image_state(image) == SG_RESOURCESTATE_VALID &&
                 sg_query_view_state(attachment) == SG_RESOURCESTATE_VALID &&
                 sg_query_pipeline_state(pipeline) == SG_RESOURCESTATE_VALID;
    if (!valid) {
        sg_shutdown();
        return false;
    }
#if defined(SOKOL_GLCORE)
    glGenFramebuffers(1, &read_fbo);
#endif
    return true;
}
void bench_ref_shutdown(void) {
    bench_ref_drain();
#if defined(SOKOL_GLCORE)
    glDeleteFramebuffers(1, &read_fbo);
#endif
    sg_shutdown();
}
void bench_ref_draws(int count, const float *colors) {
    begin();
    sg_apply_pipeline(pipeline);
    for (int i = 0; i < count; ++i) {
        sg_bindings bindings = {0};
        bindings.vertex_buffers[0] = vertices[i & 1];
        sg_apply_bindings(&bindings);
        sg_range uniform = {colors + (i & 1) * 4, 4 * sizeof(float)};
        sg_apply_uniforms(0, &uniform);
        sg_draw(0, 3, 1);
    }
    sg_end_pass();
    sg_commit();
}
bool bench_ref_churn(int count) {
    for (int i = 0; i < count; ++i) {
        sg_buffer_desc desc = {0};
        desc.size = 4096;
        desc.usage.vertex_buffer = true;
        desc.usage.write_transient = true;
        sg_buffer buffer = sg_make_buffer(&desc);
        if (sg_query_buffer_state(buffer) != SG_RESOURCESTATE_VALID)
            return false;
        sg_destroy_buffer(buffer);
        if ((i & 63) == 63 || i + 1 == count) {
            begin();
            sg_end_pass();
            sg_commit();
        }
    }
    return true;
}
void bench_ref_upload(const void *data, size_t bytes) {
    sg_write_buffer_desc write = {0};
    write.src.data = (sg_range){data, bytes};
    write.dst.buffer = upload;
    sg_write_buffer_transient(&write);
    sg_commit();
}
#if defined(SOKOL_GLCORE)
bool bench_ref_read(void *data, size_t bytes) {
    sg_gl_buffer_info buffer = sg_gl_query_buffer_info(upload);
    glBindBuffer(GL_COPY_READ_BUFFER, buffer.buf[buffer.active_slot]);
    glGetBufferSubData(GL_COPY_READ_BUFFER, 0, (GLsizeiptr)bytes, data);
    glBindBuffer(GL_COPY_READ_BUFFER, 0);
    return glGetError() == GL_NO_ERROR;
}
bool bench_ref_pixel(unsigned char *rgba) {
    sg_gl_image_info texture = sg_gl_query_image_info(image);
    GLint saved = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);
    glBindFramebuffer(GL_FRAMEBUFFER, read_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, texture.tex_target,
                           texture.tex[texture.active_slot], 0);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
    return glGetError() == GL_NO_ERROR;
}
#elif defined(SOKOL_VULKAN)
/* Upstream exposes no readback API. These benchmark-only native copies use the
 * C implementation's own resources and command helpers, never zicr internals. */
static bool native_read(void *output, size_t bytes, bool image_read) {
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkBufferCreateInfo info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                               .size = bytes,
                               .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    if (vkCreateBuffer(_sg.vk.dev, &info, NULL, &buffer) != VK_SUCCESS)
        return false;
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(_sg.vk.dev, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(_sg.vk.phys_dev, &properties);
    const VkMemoryPropertyFlags required =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t selected = UINT32_MAX, fallback = UINT32_MAX;
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        const VkMemoryPropertyFlags flags = properties.memoryTypes[i].propertyFlags;
        if (!(requirements.memoryTypeBits & (1u << i)) || (flags & required) != required)
            continue;
        if (fallback == UINT32_MAX)
            fallback = i;
        if (flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) {
            selected = i;
            break;
        }
    }
    if (selected == UINT32_MAX)
        selected = fallback;
    if (selected == UINT32_MAX)
        goto fail;
    VkMemoryAllocateInfo allocation = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                       .allocationSize = requirements.size,
                                       .memoryTypeIndex = selected};
    if (vkAllocateMemory(_sg.vk.dev, &allocation, NULL, &memory) != VK_SUCCESS)
        goto fail;
    if (!memory || vkBindBufferMemory(_sg.vk.dev, buffer, memory, 0) != VK_SUCCESS)
        goto fail;
    VkCommandBuffer cmd = _sg_vk_staging_copy_begin();
    if (image_read) {
        _sg_image_t *source = _sg_lookup_image(image.id);
        const _sg_vk_access_t previous = source->vk.cur_access;
        _sg_vk_image_barrier(cmd, source, _SG_VK_ACCESS_COPY_SRC);
        VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                  .imageExtent = {1, 1, 1}};
        vkCmdCopyImageToBuffer(cmd, source->vk.img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1,
                               &copy);
        _sg_vk_image_barrier(cmd, source, previous);
    } else {
        _sg_buffer_t *source = _sg_lookup_buffer(upload.id);
        const _sg_vk_access_t previous = source->vk.cur_access;
        _sg_vk_buffer_barrier(cmd, source, _SG_VK_ACCESS_COPY_SRC);
        VkBufferCopy copy = {.size = bytes};
        vkCmdCopyBuffer(cmd, source->vk.buf, buffer, 1, &copy);
        _sg_vk_buffer_barrier(cmd, source, previous);
    }
    VkBufferMemoryBarrier2 host = {.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
                                   .srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
                                   .srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
                                   .dstStageMask = VK_PIPELINE_STAGE_2_HOST_BIT,
                                   .dstAccessMask = VK_ACCESS_2_HOST_READ_BIT,
                                   .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                   .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                   .buffer = buffer,
                                   .size = bytes};
    VkDependencyInfo dependency = {.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                                   .bufferMemoryBarrierCount = 1,
                                   .pBufferMemoryBarriers = &host};
    vkCmdPipelineBarrier2(cmd, &dependency);
    _sg_vk_staging_copy_end(cmd, _sg.vk.queue);
    void *mapped = NULL;
    if (vkMapMemory(_sg.vk.dev, memory, 0, bytes, 0, &mapped) != VK_SUCCESS)
        goto fail;
    /* Both preferred and fallback memory are coherent; no invalidation is needed. */
    memcpy(output, mapped, bytes);
    vkUnmapMemory(_sg.vk.dev, memory);
    vkDestroyBuffer(_sg.vk.dev, buffer, NULL);
    _sg_vk_mem_free_device_memory(memory);
    return true;
fail:
    vkDestroyBuffer(_sg.vk.dev, buffer, NULL);
    if (memory)
        _sg_vk_mem_free_device_memory(memory);
    return false;
}
bool bench_ref_read(void *data, size_t bytes) { return native_read(data, bytes, false); }
bool bench_ref_pixel(unsigned char *rgba) { return native_read(rgba, 4, true); }
#elif defined(SOKOL_WGPU)
extern unsigned int bench_host_wait(uint64_t future);
static void mapped_done(WGPUMapAsyncStatus status, WGPUStringView message, void *user,
                        void *ignored) {
    (void)message;
    (void)ignored;
    *(unsigned int *)user = (unsigned int)status;
}
static void submitted_done(WGPUQueueWorkDoneStatus status, WGPUStringView message, void *user,
                           void *ignored) {
    (void)message;
    (void)ignored;
    *(unsigned int *)user = (unsigned int)status;
}
static bool native_read(void *output, size_t bytes, bool image_read) {
    WGPUBufferDescriptor desc = WGPU_BUFFER_DESCRIPTOR_INIT;
    desc.size = image_read ? 256 : bytes;
    desc.usage = WGPUBufferUsage_CopyDst | WGPUBufferUsage_MapRead;
    WGPUBuffer buffer = wgpuDeviceCreateBuffer(_sg.wgpu.dev, &desc);
    if (!buffer)
        return false;
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(_sg.wgpu.dev, NULL);
    if (!encoder) {
        wgpuBufferRelease(buffer);
        return false;
    }
    if (image_read) {
        WGPUTexelCopyTextureInfo source = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        source.texture = (WGPUTexture)sg_wgpu_query_image_info(image).tex;
        WGPUTexelCopyBufferInfo target = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
        target.buffer = buffer;
        target.layout.bytesPerRow = 256;
        target.layout.rowsPerImage = 1;
        WGPUExtent3D extent = {1, 1, 1};
        wgpuCommandEncoderCopyTextureToBuffer(encoder, &source, &target, &extent);
    } else {
        WGPUBuffer source = (WGPUBuffer)sg_wgpu_query_buffer_info(upload).buf;
        wgpuCommandEncoderCopyBufferToBuffer(encoder, source, 0, buffer, 0, bytes);
    }
    WGPUCommandBuffer command = wgpuCommandEncoderFinish(encoder, NULL);
    wgpuCommandEncoderRelease(encoder);
    if (!command) {
        wgpuBufferRelease(buffer);
        return false;
    }
    wgpuQueueSubmit(_sg.wgpu.queue, 1, &command);
    wgpuCommandBufferRelease(command);
    unsigned int status = 0;
    WGPUBufferMapCallbackInfo callback = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    callback.mode = WGPUCallbackMode_WaitAnyOnly;
    callback.callback = mapped_done;
    callback.userdata1 = &status;
    WGPUFuture future = wgpuBufferMapAsync(buffer, WGPUMapMode_Read, 0, bytes, callback);
    /* A failed blocking host cannot safely return with stack callback data live. */
    if (!bench_host_wait(future.id) || status == 0)
        abort();
    bool valid = status == WGPUMapAsyncStatus_Success;
    const void *mapped = valid ? wgpuBufferGetConstMappedRange(buffer, 0, bytes) : NULL;
    if (mapped)
        memcpy(output, mapped, bytes);
    else
        valid = false;
    if (status == WGPUMapAsyncStatus_Success)
        wgpuBufferUnmap(buffer);
    wgpuBufferRelease(buffer);
    return valid;
}
bool bench_ref_read(void *data, size_t bytes) { return native_read(data, bytes, false); }
bool bench_ref_pixel(unsigned char *rgba) { return native_read(rgba, 4, true); }

#elif defined(SOKOL_D3D11)
static bool native_read(void *output, size_t bytes, bool image_read) {
    ID3D11Device *device = (ID3D11Device *)sg_d3d11_device();
    ID3D11DeviceContext *context = (ID3D11DeviceContext *)sg_d3d11_device_context();
    ID3D11Resource *staging = NULL;
    ID3D11Resource *source = NULL;
    HRESULT status;
    if (image_read) {
        D3D11_TEXTURE2D_DESC desc = {0};
        desc.Width = 1;
        desc.Height = 1;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ID3D11Texture2D *texture = NULL;
        status = ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture);
        staging = (ID3D11Resource *)texture;
        source = (ID3D11Resource *)sg_d3d11_query_image_info(image).res;
    } else {
        D3D11_BUFFER_DESC desc = {0};
        desc.ByteWidth = (UINT)bytes;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ID3D11Buffer *buffer = NULL;
        status = ID3D11Device_CreateBuffer(device, &desc, NULL, &buffer);
        staging = (ID3D11Resource *)buffer;
        source = (ID3D11Resource *)sg_d3d11_query_buffer_info(upload).buf;
    }
    if (FAILED(status) || !staging)
        return false;
    D3D11_BOX box = {0, 0, 0, image_read ? 1 : (UINT)bytes, 1, 1};
    ID3D11DeviceContext_CopySubresourceRegion(context, staging, 0, 0, 0, 0, source, 0, &box);
    D3D11_MAPPED_SUBRESOURCE mapped = {0};
    status = ID3D11DeviceContext_Map(context, staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (SUCCEEDED(status)) {
        memcpy(output, mapped.pData, bytes);
        ID3D11DeviceContext_Unmap(context, staging, 0);
    }
    ID3D11Resource_Release(staging);
    return SUCCEEDED(status);
}
bool bench_ref_read(void *data, size_t bytes) { return native_read(data, bytes, false); }
bool bench_ref_pixel(unsigned char *rgba) { return native_read(rgba, 4, true); }
#elif defined(SOKOL_METAL)
static bool native_read(void *output, size_t bytes, bool image_read) {
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)sg_mtl_device();
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)sg_mtl_command_queue();
        id<MTLBuffer> buffer = [device newBufferWithLength:(image_read ? 256 : bytes)
                                                   options:MTLResourceStorageModeShared];
        if (!buffer)
            return false;
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
        if (!command || !encoder)
            return false;
        if (image_read) {
            sg_mtl_image_info info = sg_mtl_query_image_info(image);
            id<MTLTexture> texture = (__bridge id<MTLTexture>)info.tex[info.active_slot];
            [encoder copyFromTexture:texture
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(1, 1, 1)
                                toBuffer:buffer
                       destinationOffset:0
                  destinationBytesPerRow:256
                destinationBytesPerImage:0];
        } else {
            sg_mtl_buffer_info info = sg_mtl_query_buffer_info(upload);
            id<MTLBuffer> source = (__bridge id<MTLBuffer>)info.buf[info.active_slot];
            [encoder copyFromBuffer:source
                       sourceOffset:0
                           toBuffer:buffer
                  destinationOffset:0
                               size:bytes];
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            return false;
        memcpy(output, buffer.contents, bytes);
        return true;
    }
}
bool bench_ref_read(void *data, size_t bytes) { return native_read(data, bytes, false); }
bool bench_ref_pixel(unsigned char *rgba) { return native_read(rgba, 4, true); }

#endif
void bench_ref_drain(void) {
#if defined(SOKOL_GLCORE)
    glFinish();
#elif defined(SOKOL_VULKAN)
    if (vkQueueWaitIdle(_sg.vk.queue) != VK_SUCCESS)
        abort();
#elif defined(SOKOL_WGPU)
    unsigned int status = 0;
    WGPUQueueWorkDoneCallbackInfo callback = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
    callback.mode = WGPUCallbackMode_WaitAnyOnly;
    callback.callback = submitted_done;
    callback.userdata1 = &status;
    WGPUFuture future = wgpuQueueOnSubmittedWorkDone(_sg.wgpu.queue, callback);
    if (!bench_host_wait(future.id) || status != WGPUQueueWorkDoneStatus_Success)
        abort();
#elif defined(SOKOL_D3D11)
    ID3D11Device *device = (ID3D11Device *)sg_d3d11_device();
    ID3D11DeviceContext *context = (ID3D11DeviceContext *)sg_d3d11_device_context();
    D3D11_QUERY_DESC desc = {D3D11_QUERY_EVENT, 0};
    ID3D11Query *query = NULL;
    if (FAILED(ID3D11Device_CreateQuery(device, &desc, &query)))
        abort();
    ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)query);
    ID3D11DeviceContext_Flush(context);
    BOOL ready = FALSE;
    HRESULT result;
    do {
        result = ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)query, &ready,
                                             sizeof(ready), 0);
    } while (result == S_FALSE);
    ID3D11Query_Release(query);
    if (FAILED(result) || !ready)
        abort();
#elif defined(SOKOL_METAL)
    @autoreleasepool {
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)sg_mtl_command_queue();
        id<MTLCommandBuffer> command = [queue commandBuffer];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            abort();
    }
#endif
}
const char *bench_ref_compiler(void) { return __VERSION__; }
