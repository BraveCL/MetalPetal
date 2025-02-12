//
//  MTIMultilayerRenderPipelineKernel.m
//  MetalPetal
//
//  Created by YuAo on 27/09/2017.
//

#import "MTIMultilayerCompositeKernel.h"
#import "MTIContext.h"
#import "MTIFunctionDescriptor.h"
#import "MTIImage.h"
#import "MTIImagePromise.h"
#import "MTIVertex.h"
#import "MTIImageRenderingContext.h"
#import "MTITextureDescriptor.h"
#import "MTIRenderPipeline.h"
#import "MTIImage+Promise.h"
#import "MTIFilter.h"
#import "MTIDefer.h"
#import "MTITransform.h"
#import "MTILayer.h"
#import "MTIImagePromiseDebug.h"
#import "MTIContext+Internal.h"
#import "MTIError.h"
#import "MTIMask.h"
#import "MTIPixelFormat.h"
#import "MTIHasher.h"

__attribute__((objc_subclassing_restricted))
@interface MTIMultilayerCompositeKernelConfiguration: NSObject <MTIKernelConfiguration>

@property (nonatomic,readonly) MTLPixelFormat outputPixelFormat;
@property (nonatomic,readonly) NSUInteger rasterSampleCount;

@end

@implementation MTIMultilayerCompositeKernelConfiguration

- (instancetype)initWithOutputPixelFormat:(MTLPixelFormat)pixelFormat rasterSampleCount:(NSUInteger)rasterSampleCount {
    if (self = [super init]) {
        _outputPixelFormat = pixelFormat;
        _rasterSampleCount = rasterSampleCount;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (id<NSCopying>)identifier {
    return self;
}

- (NSUInteger)hash {
    MTIHasher hasher = MTIHasherMake(0);
    MTIHasherCombine(&hasher, _outputPixelFormat);
    MTIHasherCombine(&hasher, _rasterSampleCount);
    return MTIHasherFinalize(&hasher);
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    MTIMultilayerCompositeKernelConfiguration *obj = object;
    if ([obj isKindOfClass:MTIMultilayerCompositeKernelConfiguration.class] && obj -> _outputPixelFormat == _outputPixelFormat && obj -> _rasterSampleCount == _rasterSampleCount) {
        return YES;
    } else {
        return NO;
    }
}

@end

__attribute__((objc_subclassing_restricted))
@interface MTIMultilayerCompositeKernelState: NSObject

@property (nonatomic,copy,readonly) NSDictionary<MTIBlendMode, MTIRenderPipeline *> *pipelines;

@property (nonatomic,copy,readonly) MTIRenderPipeline *passthroughRenderPipeline;

@property (nonatomic,copy,readonly) MTIRenderPipeline *unpremultiplyAlphaRenderPipeline;

@property (nonatomic,copy,readonly) MTIRenderPipeline *passthroughToColorAttachmentOneRenderPipeline;

@property (nonatomic,copy,readonly) MTIRenderPipeline *unpremultiplyAlphaToColorAttachmentOneRenderPipeline;

@property (nonatomic,copy,readonly) MTIRenderPipeline *premultiplyAlphaInPlaceRenderPipeline;
@property (nonatomic,copy,readonly) MTIRenderPipeline *alphaToOneInPlaceRenderPipeline;

@end

@implementation MTIMultilayerCompositeKernelState

+ (MTIRenderPipeline *)renderPipelineWithFragmentFunctionName:(NSString *)fragmentFunctionName colorAttachmentDescriptor:(MTLRenderPipelineColorAttachmentDescriptor *)colorAttachmentDescriptor rasterSampleCount:(NSUInteger)rasterSampleCount context:(MTIContext *)context error:(NSError * __autoreleasing *)inOutError {
    MTLRenderPipelineDescriptor *renderPipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    
    BOOL useProgrammableBlending = context.defaultLibrarySupportsProgrammableBlending && context.isProgrammableBlendingSupported;

    NSError *error;
    id<MTLFunction> vertextFunction = [context functionWithDescriptor:[[MTIFunctionDescriptor alloc] initWithName:MTIFilterPassthroughVertexFunctionName] error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    id<MTLFunction> fragmentFunction = [context functionWithDescriptor:[[MTIFunctionDescriptor alloc] initWithName:fragmentFunctionName] error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    renderPipelineDescriptor.vertexFunction = vertextFunction;
    renderPipelineDescriptor.fragmentFunction = fragmentFunction;
    
    renderPipelineDescriptor.colorAttachments[0] = colorAttachmentDescriptor;
    if (useProgrammableBlending) {
        renderPipelineDescriptor.colorAttachments[1] = colorAttachmentDescriptor;
    }
    renderPipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
    renderPipelineDescriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
    
    if (@available(iOS 11.0, macOS 10.13, *)) {
        renderPipelineDescriptor.rasterSampleCount = rasterSampleCount;
    } else {
        renderPipelineDescriptor.sampleCount = rasterSampleCount;
    }

    return [context renderPipelineWithDescriptor:renderPipelineDescriptor error:inOutError];
}

- (instancetype)initWithContext:(MTIContext *)context
      colorAttachmentDescriptor:(MTLRenderPipelineColorAttachmentDescriptor *)colorAttachmentDescriptor
              rasterSampleCount:(NSUInteger)rasterSampleCount
                          error:(NSError * __autoreleasing *)inOutError {
    if (self = [super init]) {
        NSError *error;
        
        _passthroughRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:MTIFilterPassthroughFragmentFunctionName colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        
        _unpremultiplyAlphaRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:MTIFilterUnpremultiplyAlphaFragmentFunctionName colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        
        _passthroughToColorAttachmentOneRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:@"passthroughToColorAttachmentOne" colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        
        _unpremultiplyAlphaToColorAttachmentOneRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:@"unpremultiplyAlphaToColorAttachmentOne" colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        
        BOOL useProgrammableBlending = context.defaultLibrarySupportsProgrammableBlending && context.isProgrammableBlendingSupported;
        
        if (useProgrammableBlending) {
            _premultiplyAlphaInPlaceRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:@"premultiplyAlphaInPlace" colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
            _alphaToOneInPlaceRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:@"alphaToOneInPlace" colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
        } else {
            _premultiplyAlphaInPlaceRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:@"premultiplyAlpha" colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
            _alphaToOneInPlaceRenderPipeline = [MTIMultilayerCompositeKernelState renderPipelineWithFragmentFunctionName:@"alphaToOne" colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:rasterSampleCount context:context error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
        }
        
        NSMutableDictionary *pipelines = [NSMutableDictionary dictionary];
        for (MTIBlendMode mode in MTIBlendModes.allModes) {
            MTLRenderPipelineDescriptor *renderPipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
            
            NSError *error = nil;
            id<MTLFunction> vertextFunction = [context functionWithDescriptor:[[MTIFunctionDescriptor alloc] initWithName:@"multilayerCompositeVertexShader"] error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
            
            MTIFunctionDescriptor *fragmentFunctionDescriptorForBlending;
            if (useProgrammableBlending) {
                fragmentFunctionDescriptorForBlending = [MTIBlendModes functionDescriptorsForBlendMode:mode].fragmentFunctionDescriptorForMultilayerCompositingFilterWithProgrammableBlending;
            } else {
                fragmentFunctionDescriptorForBlending = [MTIBlendModes functionDescriptorsForBlendMode:mode].fragmentFunctionDescriptorForMultilayerCompositingFilterWithoutProgrammableBlending;
            }
            
            if (fragmentFunctionDescriptorForBlending == nil) {
                if (inOutError) {
                    NSDictionary *info = @{@"blendMode": mode, @"programmableBlending": @(useProgrammableBlending)};
                    *inOutError = MTIErrorCreate(MTIErrorBlendFunctionNotFound, info);
                }
                return nil;
            }
            
            id<MTLFunction> fragmentFunction = [context functionWithDescriptor:fragmentFunctionDescriptorForBlending error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
            
            renderPipelineDescriptor.vertexFunction = vertextFunction;
            renderPipelineDescriptor.fragmentFunction = fragmentFunction;
            
            renderPipelineDescriptor.colorAttachments[0] = colorAttachmentDescriptor;
            if (useProgrammableBlending) {
                renderPipelineDescriptor.colorAttachments[1] = colorAttachmentDescriptor;
            }
            renderPipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
            renderPipelineDescriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
            
            if (@available(iOS 11.0, macOS 10.13, *)) {
                renderPipelineDescriptor.rasterSampleCount = rasterSampleCount;
            } else {
                renderPipelineDescriptor.sampleCount = rasterSampleCount;
            }
            
            MTIRenderPipeline *pipeline = [context renderPipelineWithDescriptor:renderPipelineDescriptor error:&error];
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                return nil;
            }
            
            pipelines[mode] = pipeline;
        }
        _pipelines = [pipelines copy];
    }
    return self;
}

- (MTIRenderPipeline *)pipelineWithBlendMode:(MTIBlendMode)blendMode {
    return self.pipelines[blendMode];
}

@end

__attribute__((objc_subclassing_restricted))
@interface MTIMultilayerCompositingRecipe : NSObject <MTIImagePromise>

@property (nonatomic,copy,readonly) MTIImage *backgroundImage;

@property (nonatomic,strong,readonly) MTIMultilayerCompositeKernel *kernel;

@property (nonatomic,copy,readonly) NSArray<MTILayer *> *layers;

@property (nonatomic,readonly) MTLPixelFormat outputPixelFormat;

@property (nonatomic,readonly) NSUInteger rasterSampleCount;

@end

@implementation MTIMultilayerCompositingRecipe
@synthesize dimensions = _dimensions;
@synthesize dependencies = _dependencies;
@synthesize alphaType = _alphaType;

- (MTIVertices *)verticesForRect:(CGRect)rect contentRegion:(CGRect)contentRegion flipOptions:(MTILayerFlipOptions)flipOptions {
    CGFloat l = CGRectGetMinX(rect);
    CGFloat r = CGRectGetMaxX(rect);
    CGFloat t = CGRectGetMinY(rect);
    CGFloat b = CGRectGetMaxY(rect);
    
    CGFloat contentL = CGRectGetMinX(contentRegion);
    CGFloat contentR = CGRectGetMaxX(contentRegion);
    CGFloat contentT = CGRectGetMaxY(contentRegion);
    CGFloat contentB = CGRectGetMinY(contentRegion);
    
    if (flipOptions & MTILayerFlipOptionsFlipVertically) {
        CGFloat temp = contentT;
        contentT = contentB;
        contentB = temp;
    }
    if (flipOptions & MTILayerFlipOptionsFlipHorizontally) {
        CGFloat temp = contentL;
        contentL = contentR;
        contentR = temp;
    }
    return [[MTIVertices alloc] initWithVertices:(MTIVertex []){
        { .position = {l, t, 0, 1} , .textureCoordinate = { contentL, contentT } },
        { .position = {r, t, 0, 1} , .textureCoordinate = { contentR, contentT } },
        { .position = {l, b, 0, 1} , .textureCoordinate = { contentL, contentB } },
        { .position = {r, b, 0, 1} , .textureCoordinate = { contentR, contentB } }
    } count:4 primitiveType:MTLPrimitiveTypeTriangleStrip];
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext error:(NSError *__autoreleasing  _Nullable *)error {
    BOOL useProgrammableBlending = renderingContext.context.defaultLibrarySupportsProgrammableBlending && renderingContext.context.isProgrammableBlendingSupported;
    if (useProgrammableBlending) {
        return [self resolveWithContext_programmableBlending:renderingContext error:error];
    } else {
        return [self resolveWithContext_no_programmableBlending:renderingContext error:error];
    }
}

- (MTIImagePromiseRenderTarget *)resolveWithContext_programmableBlending:(MTIImageRenderingContext *)renderingContext error:(NSError * __autoreleasing *)inOutError {
    
    NSError *error = nil;
    
    MTLPixelFormat pixelFormat = (_outputPixelFormat == MTIPixelFormatUnspecified) ? renderingContext.context.workingPixelFormat : _outputPixelFormat;

    MTIMultilayerCompositeKernelState *kernelState = [renderingContext.context kernelStateForKernel:_kernel configuration:[[MTIMultilayerCompositeKernelConfiguration alloc] initWithOutputPixelFormat:pixelFormat rasterSampleCount:_rasterSampleCount] error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    MTITextureDescriptor *textureDescriptor = [MTITextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat width:_dimensions.width height:_dimensions.height mipmapped:NO usage:MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead resourceOptions:MTLResourceStorageModePrivate];
    MTIImagePromiseRenderTarget *renderTarget = [renderingContext.context newRenderTargetWithReusableTextureDescriptor:textureDescriptor error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    if (_rasterSampleCount > 1) {
        MTLTextureDescriptor *tempTextureDescriptor = [textureDescriptor newMTLTextureDescriptor];
        tempTextureDescriptor.textureType = MTLTextureType2DMultisample;
        tempTextureDescriptor.usage = MTLTextureUsageRenderTarget;
        if (@available(macCatalyst 14.0, macOS 11.0, *)) {
            tempTextureDescriptor.storageMode = MTLStorageModeMemoryless;
        } else {
            NSAssert(NO, @"");
        }
        tempTextureDescriptor.sampleCount = _rasterSampleCount;
        id<MTLTexture> msaaTexture = [renderingContext.context.device newTextureWithDescriptor:tempTextureDescriptor];
        if (!msaaTexture) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToCreateTexture, nil);
            }
            return nil;
        }
        renderPassDescriptor.colorAttachments[0].texture = msaaTexture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        renderPassDescriptor.colorAttachments[0].resolveTexture = renderTarget.texture;
    } else {
        renderPassDescriptor.colorAttachments[0].texture = renderTarget.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    
    //Set up color attachment 1 for compositing mask
    if (_rasterSampleCount > 1) {
        MTLTextureDescriptor *tempTextureDescriptor = [textureDescriptor newMTLTextureDescriptor];
        tempTextureDescriptor.textureType = MTLTextureType2DMultisample;
        tempTextureDescriptor.usage = MTLTextureUsageRenderTarget;
        if (@available(macCatalyst 14.0, macOS 11.0, *)) {
            tempTextureDescriptor.storageMode = MTLStorageModeMemoryless;
        } else {
            NSAssert(NO, @"");
        }
        tempTextureDescriptor.sampleCount = _rasterSampleCount;
        id<MTLTexture> compositingMaskTexture = [renderingContext.context.device newTextureWithDescriptor:tempTextureDescriptor];
        if (!compositingMaskTexture) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToCreateTexture, nil);
            }
            return nil;
        }
        renderPassDescriptor.colorAttachments[1].texture = compositingMaskTexture;
        renderPassDescriptor.colorAttachments[1].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[1].storeAction = MTLStoreActionDontCare;
    } else {
        MTLTextureDescriptor *tempTextureDescriptor = [textureDescriptor newMTLTextureDescriptor];
        if (@available(macCatalyst 14.0, macOS 11.0, *)) {
            tempTextureDescriptor.storageMode = MTLStorageModeMemoryless;
        } else {
            NSAssert(NO, @"");
        }
        tempTextureDescriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> compositingMaskTexture = [renderingContext.context.device newTextureWithDescriptor:tempTextureDescriptor];
        if (!compositingMaskTexture) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToCreateTexture, nil);
            }
            return nil;
        }
        renderPassDescriptor.colorAttachments[1].texture = compositingMaskTexture;
        renderPassDescriptor.colorAttachments[1].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[1].storeAction = MTLStoreActionDontCare;
    }
    
    //render background
    MTIVertices *vertices = [self verticesForRect:CGRectMake(-1, -1, 2, 2) contentRegion:CGRectMake(0, 0, 1, 1) flipOptions:MTILayerFlipOptionsDonotFlip];
    __auto_type commandEncoder = [renderingContext.commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    if (!commandEncoder) {
        if (inOutError) {
            *inOutError = MTIErrorCreate(MTIErrorFailedToCreateCommandEncoder, nil);
        }
        return nil;
    }
    
    NSParameterAssert(self.backgroundImage.alphaType != MTIAlphaTypeUnknown);
    
    MTIRenderPipeline *renderPipeline;
    if (self.backgroundImage.alphaType == MTIAlphaTypePremultiplied) {
        renderPipeline = [kernelState unpremultiplyAlphaRenderPipeline];
    } else {
        renderPipeline = [kernelState passthroughRenderPipeline];
    }
    
    [commandEncoder setRenderPipelineState:renderPipeline.state];

    [commandEncoder setFragmentTexture:[renderingContext resolvedTextureForImage:self.backgroundImage] atIndex:0];
    [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:self.backgroundImage] atIndex:0];
    
    [vertices encodeDrawCallWithCommandEncoder:commandEncoder context:renderPipeline];
    
    //render layers
    for (NSUInteger index = 0; index < self.layers.count; index += 1) {
        MTILayer *layer = self.layers[index];
        
        if (layer.compositingMask) {
            NSParameterAssert(layer.compositingMask.content.alphaType != MTIAlphaTypeUnknown);
            
            MTIRenderPipeline *renderPipeline;
            if (layer.compositingMask.content.alphaType == MTIAlphaTypePremultiplied) {
                renderPipeline = [kernelState unpremultiplyAlphaToColorAttachmentOneRenderPipeline];
            } else {
                renderPipeline = [kernelState passthroughToColorAttachmentOneRenderPipeline];
            }
            [commandEncoder setRenderPipelineState:renderPipeline.state];
            
            [commandEncoder setFragmentTexture:[renderingContext resolvedTextureForImage:layer.compositingMask.content] atIndex:0];
            [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:layer.compositingMask.content] atIndex:0];
            
            [vertices encodeDrawCallWithCommandEncoder:commandEncoder context:renderPipeline];
        }
        
        NSParameterAssert(layer.content.alphaType != MTIAlphaTypeUnknown);
        
        CGSize layerPixelSize = [layer sizeInPixelForBackgroundSize:self.backgroundImage.size];
        CGPoint layerPixelPosition = [layer positionInPixelForBackgroundSize:self.backgroundImage.size];
        
        MTIVertices *vertices = [self verticesForRect:CGRectMake(-layerPixelSize.width/2.0, -layerPixelSize.height/2.0, layerPixelSize.width, layerPixelSize.height)
                                        contentRegion:CGRectMake(layer.contentRegion.origin.x/layer.content.size.width, layer.contentRegion.origin.y/layer.content.size.height, layer.contentRegion.size.width/layer.content.size.width, layer.contentRegion.size.height/layer.content.size.height)
                                          flipOptions:layer.contentFlipOptions];
        
        MTIRenderPipeline *renderPipeline = [kernelState pipelineWithBlendMode:layer.blendMode];
        if (!renderPipeline) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToFetchBlendRenderPipelineForMultilayerCompositing, nil);
            }
            [commandEncoder endEncoding];
            return nil;
        }
        
        [commandEncoder setRenderPipelineState:renderPipeline.state];
        
        //transformMatrix
        CATransform3D transform = CATransform3DIdentity;
        transform = CATransform3DTranslate(transform, layerPixelPosition.x - self.backgroundImage.size.width/2.0, -(layerPixelPosition.y - self.backgroundImage.size.height/2.0), 0);
        transform = CATransform3DRotate(transform, -layer.rotation, 0, 0, 1);
        simd_float4x4 transformMatrix = MTIMakeTransformMatrixFromCATransform3D(transform);
        [commandEncoder setVertexBytes:&transformMatrix length:sizeof(transformMatrix) atIndex:1];
        
        //orthographicMatrix
        simd_float4x4 orthographicMatrix = MTIMakeOrthographicMatrix(-self.backgroundImage.size.width/2.0, self.backgroundImage.size.width/2.0, -self.backgroundImage.size.height/2.0, self.backgroundImage.size.height/2.0, -1, 1);
        [commandEncoder setVertexBytes:&orthographicMatrix length:sizeof(orthographicMatrix) atIndex:2];
        
        [commandEncoder setFragmentTexture:[renderingContext resolvedTextureForImage:layer.content] atIndex:0];
        [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:layer.content] atIndex:0];
        
        //parameters
        MTIMultilayerCompositingLayerShadingParameters parameters;
        parameters.opacity = layer.opacity;
        parameters.contentHasPremultipliedAlpha = (layer.content.alphaType == MTIAlphaTypePremultiplied);
        parameters.hasCompositingMask = !(layer.compositingMask == nil);
        parameters.compositingMaskComponent = (int)layer.compositingMask.component;
        parameters.usesOneMinusMaskValue = (layer.compositingMask.mode == MTIMaskModeOneMinusMaskValue);
        parameters.tintColor = MTIColorToFloat4(layer.tintColor);
        [commandEncoder setFragmentBytes:&parameters length:sizeof(parameters) atIndex:0];
        
        [vertices encodeDrawCallWithCommandEncoder:commandEncoder context:renderPipeline];
    }
    
    
    MTIRenderPipeline *outputAlphaTypeRenderPipeline = nil;
    switch (_alphaType) {
        case MTIAlphaTypeNonPremultiplied:
            break;
        case MTIAlphaTypeAlphaIsOne: {
            outputAlphaTypeRenderPipeline = kernelState.alphaToOneInPlaceRenderPipeline;
        } break;
        case MTIAlphaTypePremultiplied: {
            outputAlphaTypeRenderPipeline = kernelState.premultiplyAlphaInPlaceRenderPipeline;
        } break;
        default:
            NSAssert(NO, @"Unknown output alpha type.");
            break;
    }
    
    if (outputAlphaTypeRenderPipeline != nil) {
        [commandEncoder setRenderPipelineState:outputAlphaTypeRenderPipeline.state];
        [MTIVertices.fullViewportSquareVertices encodeDrawCallWithCommandEncoder:commandEncoder context:outputAlphaTypeRenderPipeline];
    }
    
    //end encoding
    [commandEncoder endEncoding];
    
    return renderTarget;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext_no_programmableBlending:(MTIImageRenderingContext *)renderingContext error:(NSError * __autoreleasing *)inOutError {
    
    NSError *error = nil;
    
    MTLPixelFormat pixelFormat = (self.outputPixelFormat == MTIPixelFormatUnspecified) ? renderingContext.context.workingPixelFormat : self.outputPixelFormat;
    
    MTIMultilayerCompositeKernelState *kernelState = [renderingContext.context kernelStateForKernel:self.kernel configuration:[[MTIMultilayerCompositeKernelConfiguration alloc] initWithOutputPixelFormat:pixelFormat rasterSampleCount:_rasterSampleCount] error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    MTITextureDescriptor *textureDescriptor = [MTITextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat width:_dimensions.width height:_dimensions.height mipmapped:NO usage:MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead resourceOptions:MTLResourceStorageModePrivate];
    MTIImagePromiseRenderTarget *renderTarget = [renderingContext.context newRenderTargetWithReusableTextureDescriptor:textureDescriptor error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    if (_rasterSampleCount > 1) {
        MTLTextureDescriptor *tempTextureDescriptor = [textureDescriptor newMTLTextureDescriptor];
        tempTextureDescriptor.textureType = MTLTextureType2DMultisample;
        tempTextureDescriptor.usage = MTLTextureUsageRenderTarget;
        tempTextureDescriptor.sampleCount = _rasterSampleCount;
        MTIImagePromiseRenderTarget *msaaTarget = [renderingContext.context newRenderTargetWithReusableTextureDescriptor:[tempTextureDescriptor newMTITextureDescriptor] error:&error];
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        renderPassDescriptor.colorAttachments[0].texture = msaaTarget.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        renderPassDescriptor.colorAttachments[0].resolveTexture = renderTarget.texture;
        [msaaTarget releaseTexture];
    } else {
        renderPassDescriptor.colorAttachments[0].texture = renderTarget.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    
    //render background
    MTIVertices *vertices = [self verticesForRect:CGRectMake(-1, -1, 2, 2) contentRegion:CGRectMake(0, 0, 1, 1) flipOptions:MTILayerFlipOptionsDonotFlip];
    __auto_type __block commandEncoder = [renderingContext.commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    if (!commandEncoder) {
        if (inOutError) {
            *inOutError = MTIErrorCreate(MTIErrorFailedToCreateCommandEncoder, nil);
        }
        return nil;
    }
    
    NSParameterAssert(self.backgroundImage.alphaType != MTIAlphaTypeUnknown);
    
    MTIRenderPipeline *renderPipeline;
    if (self.backgroundImage.alphaType == MTIAlphaTypePremultiplied) {
        renderPipeline = [kernelState unpremultiplyAlphaRenderPipeline];
    } else {
        renderPipeline = [kernelState passthroughRenderPipeline];
    }
    [commandEncoder setRenderPipelineState:renderPipeline.state];
    [commandEncoder setFragmentTexture:[renderingContext resolvedTextureForImage:self.backgroundImage] atIndex:0];
    [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:self.backgroundImage] atIndex:0];
    [vertices encodeDrawCallWithCommandEncoder:commandEncoder context:renderPipeline];
    
    __auto_type rasterSampleCount = _rasterSampleCount;
    void (^prepareCommandEncoderForNextDraw)(void) = ^(void) {
        if (rasterSampleCount > 1) {
            //end current commend encoder then create a new one.
            [commandEncoder endEncoding];
            renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
            commandEncoder = [renderingContext.commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        } else {
            #if TARGET_OS_IOS || TARGET_OS_SIMULATOR || TARGET_OS_MACCATALYST || TARGET_OS_TV
                //we are on simulator/ios/macCatalyst, no texture barrier available, end current commend encoder then create a new one.
                [commandEncoder endEncoding];
                renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
                commandEncoder = [renderingContext.commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            #else
                //we are on macOS, use textureBarrier.
                #if TARGET_OS_OSX
                    [commandEncoder textureBarrier];
                #else
                    #error Unsupported OS
                #endif
            #endif
        }
    };
    
    //render layers
    for (NSUInteger index = 0; index < self.layers.count; index += 1) {
        prepareCommandEncoderForNextDraw();
        if (!commandEncoder) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToCreateCommandEncoder, nil);
            }
            return nil;
        }
        
        MTILayer *layer = self.layers[index];
        
        if (layer.compositingMask) {
            NSParameterAssert(layer.compositingMask.content.alphaType != MTIAlphaTypeUnknown);
            //Configuration not supported on macOS currently.
            NSParameterAssert(!(layer.compositingMask.content.alphaType == MTIAlphaTypePremultiplied && layer.compositingMask.component != MTIColorComponentAlpha));
            [commandEncoder setFragmentTexture:[renderingContext resolvedTextureForImage:layer.compositingMask.content] atIndex:2];
            [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:layer.compositingMask.content] atIndex:2];
        }
        
        NSParameterAssert(layer.content.alphaType != MTIAlphaTypeUnknown);
        
        CGSize layerPixelSize = [layer sizeInPixelForBackgroundSize:self.backgroundImage.size];
        CGPoint layerPixelPosition = [layer positionInPixelForBackgroundSize:self.backgroundImage.size];
        
        MTIVertices *vertices = [self verticesForRect:CGRectMake(-layerPixelSize.width/2.0, -layerPixelSize.height/2.0, layerPixelSize.width, layerPixelSize.height)
                                        contentRegion:CGRectMake(layer.contentRegion.origin.x/layer.content.size.width, layer.contentRegion.origin.y/layer.content.size.height, layer.contentRegion.size.width/layer.content.size.width, layer.contentRegion.size.height/layer.content.size.height)
                                          flipOptions:layer.contentFlipOptions];
        
        MTIRenderPipeline *renderPipeline = [kernelState pipelineWithBlendMode:layer.blendMode];
        if (!renderPipeline) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToFetchBlendRenderPipelineForMultilayerCompositing, nil);
            }
            [commandEncoder endEncoding];
            return nil;
        }
        [commandEncoder setRenderPipelineState:renderPipeline.state];
        
        //transformMatrix
        CATransform3D transform = CATransform3DIdentity;
        transform = CATransform3DTranslate(transform, layerPixelPosition.x - self.backgroundImage.size.width/2.0, -(layerPixelPosition.y - self.backgroundImage.size.height/2.0), 0);
        transform = CATransform3DRotate(transform, -layer.rotation, 0, 0, 1);
        simd_float4x4 transformMatrix = MTIMakeTransformMatrixFromCATransform3D(transform);
        [commandEncoder setVertexBytes:&transformMatrix length:sizeof(transformMatrix) atIndex:1];
        
        //orthographicMatrix
        simd_float4x4 orthographicMatrix = MTIMakeOrthographicMatrix(-self.backgroundImage.size.width/2.0, self.backgroundImage.size.width/2.0, -self.backgroundImage.size.height/2.0, self.backgroundImage.size.height/2.0, -1, 1);
        [commandEncoder setVertexBytes:&orthographicMatrix length:sizeof(orthographicMatrix) atIndex:2];
        
        [commandEncoder setFragmentTexture:[renderingContext resolvedTextureForImage:layer.content] atIndex:0];
        [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:layer.content] atIndex:0];
        
        [commandEncoder setFragmentTexture:renderTarget.texture atIndex:1];
        
        //parameters
        MTIMultilayerCompositingLayerShadingParameters parameters;
        parameters.opacity = layer.opacity;
        parameters.contentHasPremultipliedAlpha = (layer.content.alphaType == MTIAlphaTypePremultiplied);
        parameters.hasCompositingMask = !(layer.compositingMask == nil);
        parameters.compositingMaskComponent = (int)layer.compositingMask.component;
        parameters.usesOneMinusMaskValue = (layer.compositingMask.mode == MTIMaskModeOneMinusMaskValue);
        parameters.tintColor = MTIColorToFloat4(layer.tintColor);
        [commandEncoder setFragmentBytes:&parameters length:sizeof(parameters) atIndex:0];
        
        simd_float2 viewportSize = simd_make_float2(self.backgroundImage.size.width, self.backgroundImage.size.height);
        [commandEncoder setFragmentBytes:&viewportSize length:sizeof(simd_float2) atIndex:1];

        [vertices encodeDrawCallWithCommandEncoder:commandEncoder context:renderPipeline];
    }
    
    MTIRenderPipeline *outputAlphaTypeRenderPipeline = nil;
    switch (_alphaType) {
        case MTIAlphaTypeNonPremultiplied:
            break;
        case MTIAlphaTypeAlphaIsOne: {
            outputAlphaTypeRenderPipeline = kernelState.alphaToOneInPlaceRenderPipeline;
        } break;
        case MTIAlphaTypePremultiplied: {
            outputAlphaTypeRenderPipeline = kernelState.premultiplyAlphaInPlaceRenderPipeline;
        } break;
        default:
            NSAssert(NO, @"Unknown output alpha type.");
            break;
    }
    
    if (outputAlphaTypeRenderPipeline != nil) {
        prepareCommandEncoderForNextDraw();
        if (!commandEncoder) {
            if (inOutError) {
                *inOutError = MTIErrorCreate(MTIErrorFailedToCreateCommandEncoder, nil);
            }
            return nil;
        }
        
        [commandEncoder setRenderPipelineState:outputAlphaTypeRenderPipeline.state];
        [commandEncoder setFragmentTexture:renderTarget.texture atIndex:0];
        [commandEncoder setFragmentSamplerState:[renderingContext resolvedSamplerStateForImage:_backgroundImage] atIndex:0];
        [MTIVertices.fullViewportSquareVertices encodeDrawCallWithCommandEncoder:commandEncoder context:outputAlphaTypeRenderPipeline];
    }
    
    //end encoding
    [commandEncoder endEncoding];
    
    return renderTarget;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (instancetype)initWithKernel:(MTIMultilayerCompositeKernel *)kernel
               backgroundImage:(MTIImage *)backgroundImage
                        layers:(NSArray<MTILayer *> *)layers
             rasterSampleCount:(NSUInteger)rasterSampleCount
               outputAlphaType:(MTIAlphaType)outputAlphaType
       outputTextureDimensions:(MTITextureDimensions)outputTextureDimensions
             outputPixelFormat:(MTLPixelFormat)outputPixelFormat {
    if (self = [super init]) {
        NSParameterAssert(rasterSampleCount >= 1);
        NSParameterAssert(backgroundImage);
        NSParameterAssert(kernel);
        NSParameterAssert(outputAlphaType != MTIAlphaTypeUnknown);
        _backgroundImage = backgroundImage;
        _alphaType = outputAlphaType;
        _kernel = kernel;
        _layers = layers;
        _dimensions = outputTextureDimensions;
        _outputPixelFormat = outputPixelFormat;
        _rasterSampleCount = rasterSampleCount;
        NSMutableArray *dependencies = [NSMutableArray arrayWithCapacity:layers.count + 1];
        [dependencies addObject:backgroundImage];
        for (MTILayer *layer in layers) {
            [dependencies addObject:layer.content];
            if (layer.compositingMask) {
                [dependencies addObject:layer.compositingMask.content];
            }
        }
        _dependencies = [dependencies copy];
    }
    return self;
}

- (instancetype)promiseByUpdatingDependencies:(NSArray<MTIImage *> *)dependencies {
    NSAssert(dependencies.count == self.dependencies.count, @"");
    NSInteger pointer = 0;
    MTIImage *backgroundImage = dependencies[pointer];
    pointer += 1;
    NSMutableArray *newLayers = [NSMutableArray arrayWithCapacity:self.layers.count];
    for (MTILayer *layer in self.layers) {
        MTIImage *newContent = dependencies[pointer];
        pointer += 1;
        MTIMask *compositingMask = layer.compositingMask;
        MTIMask *newCompositingMask = nil;
        if (compositingMask) {
            MTIImage *newCompositingMaskContent = dependencies[pointer];
            pointer += 1;
            newCompositingMask = [[MTIMask alloc] initWithContent:newCompositingMaskContent component:compositingMask.component mode:compositingMask.mode];
        }
        MTILayer *newLayer = [[MTILayer alloc] initWithContent:newContent contentRegion:layer.contentRegion contentFlipOptions:layer.contentFlipOptions compositingMask:newCompositingMask layoutUnit:layer.layoutUnit position:layer.position size:layer.size rotation:layer.rotation opacity:layer.opacity blendMode:layer.blendMode];
        [newLayers addObject:newLayer];
    }
    return [[MTIMultilayerCompositingRecipe alloc] initWithKernel:_kernel backgroundImage:backgroundImage layers:newLayers rasterSampleCount:_rasterSampleCount outputAlphaType:_alphaType outputTextureDimensions:_dimensions outputPixelFormat:_outputPixelFormat];
}

- (MTIImagePromiseDebugInfo *)debugInfo {
    return [[MTIImagePromiseDebugInfo alloc] initWithPromise:self type:MTIImagePromiseTypeProcessor content:self.layers];
}

@end

@implementation MTIMultilayerCompositeKernel

- (id)newKernelStateWithContext:(MTIContext *)context configuration:(MTIMultilayerCompositeKernelConfiguration *)configuration error:(NSError * __autoreleasing *)error {
    NSParameterAssert(configuration);
    MTLRenderPipelineColorAttachmentDescriptor *colorAttachmentDescriptor = [[MTLRenderPipelineColorAttachmentDescriptor alloc] init];
    colorAttachmentDescriptor.pixelFormat = configuration.outputPixelFormat;
    colorAttachmentDescriptor.blendingEnabled = NO;
    return [[MTIMultilayerCompositeKernelState alloc] initWithContext:context colorAttachmentDescriptor:colorAttachmentDescriptor rasterSampleCount:configuration.rasterSampleCount error:error];
}

- (MTIImage *)applyToBackgroundImage:(MTIImage *)image
                              layers:(NSArray<MTILayer *> *)layers
                   rasterSampleCount:(NSUInteger)rasterSampleCount
                     outputAlphaType:(MTIAlphaType)outputAlphaType
             outputTextureDimensions:(MTITextureDimensions)outputTextureDimensions
                   outputPixelFormat:(MTLPixelFormat)outputPixelFormat {
    MTIMultilayerCompositingRecipe *receipt = [[MTIMultilayerCompositingRecipe alloc] initWithKernel:self
                                                                                     backgroundImage:image
                                                                                              layers:layers
                                                                                   rasterSampleCount:rasterSampleCount
                                                                                     outputAlphaType:outputAlphaType
                                                                             outputTextureDimensions:outputTextureDimensions
                                                                                   outputPixelFormat:outputPixelFormat];
    return [[MTIImage alloc] initWithPromise:receipt];
}

@end

#import "MTIRenderGraphOptimization.h"

void MTIMultilayerCompositingRenderGraphNodeOptimize(MTIRenderGraphNode *node) {
    if ([node.image.promise isKindOfClass:[MTIMultilayerCompositingRecipe class]]) {
        MTIMultilayerCompositingRecipe *recipe = node.image.promise;
        MTIRenderGraphNode *lastNode = node.inputs.firstObject;
        MTIImage *lastImage = node.inputs.firstObject.image;
        if (lastNode.uniqueDependentCount == 1 && [lastImage.promise isKindOfClass:[MTIMultilayerCompositingRecipe class]]) {
            MTIMultilayerCompositingRecipe *lastPromise = lastImage.promise;
            NSArray<MTILayer *> *layers = recipe.layers;
            if (lastImage.cachePolicy == MTIImageCachePolicyTransient && lastPromise.outputPixelFormat == recipe.outputPixelFormat && recipe.kernel == lastPromise.kernel) {
                layers = [lastPromise.layers arrayByAddingObjectsFromArray:layers];
                MTIMultilayerCompositingRecipe *promise = [[MTIMultilayerCompositingRecipe alloc] initWithKernel:recipe.kernel
                                                                                                 backgroundImage:lastPromise.backgroundImage
                                                                                                          layers:layers
                                                                                               rasterSampleCount:MAX(recipe.rasterSampleCount,lastPromise.rasterSampleCount)
                                                                                                 outputAlphaType:recipe.alphaType
                                                                                         outputTextureDimensions:MTITextureDimensionsMake2DFromCGSize(lastPromise.backgroundImage.size)
                                                                                               outputPixelFormat:recipe.outputPixelFormat];
                NSMutableArray *inputs = [NSMutableArray arrayWithArray:lastNode.inputs];
                [node.inputs removeObjectAtIndex:0];
                [inputs addObjectsFromArray:node.inputs];
                node.inputs = inputs;
                node.image = [[MTIImage alloc] initWithPromise:promise samplerDescriptor:node.image.samplerDescriptor cachePolicy:node.image.cachePolicy];
            }
        }
    }
}
