#include <TargetConditionals.h>
#include "Cafe/HW/Latte/Renderer/Metal/MetalVoidVertexPipeline.h"

MetalVoidVertexPipeline::MetalVoidVertexPipeline(class MetalRenderer* mtlRenderer, MTL::Library* library, const std::string& vertexFunctionName)
{
    // Render pipeline state
    NS_STACK_SCOPED MTL::Function* vertexFunction = library->newFunction(ToNSString(vertexFunctionName));

    NS_STACK_SCOPED MTL::RenderPipelineDescriptor* renderPipelineDescriptor = MTL::RenderPipelineDescriptor::alloc()->init();
    renderPipelineDescriptor->setVertexFunction(vertexFunction);
    renderPipelineDescriptor->setRasterizationEnabled(false);
#if TARGET_OS_IPHONE
    // Iridia Wii U app: iOS Metal validation wants a pixel format even with rasterization off (nothing is drawn).
    renderPipelineDescriptor->colorAttachments()->object(0)->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
#endif

    NS::Error* error = nullptr;
    m_renderPipelineState = mtlRenderer->GetDevice()->newRenderPipelineState(renderPipelineDescriptor, &error);
    if (error)
    {
        cemuLog_log(LogType::Force, "error creating hybrid render pipeline state: {}", error->localizedDescription()->utf8String());
    }
}

MetalVoidVertexPipeline::~MetalVoidVertexPipeline()
{
    m_renderPipelineState->release();
}
