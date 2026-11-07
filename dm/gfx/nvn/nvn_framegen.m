#import "nvn_framegen.h"
#include <TargetConditionals.h>
#if !TARGET_OS_IPHONE || defined(DM_NVN_MODERN_RENDERER)
#include <math.h>
#include <stdio.h>
#include "nvn_framegen_kernels.h"

static id<MTLComputePipelineState> framegen_pipeline(id<MTLDevice> device, id<MTLLibrary> library, NSString *name, NSError **error) {
    id<MTLFunction> fn = [library newFunctionWithName:name];
    return fn ? [device newComputePipelineStateWithFunction:fn error:error] : nil;
}

@implementation DmFrameGenerator {
    id<MTLDevice> _device;
    id<MTLTexture> _color[2], _luma[2][3], _flow[2][3], _output[3];
    id<MTLComputePipelineState> _pyramid, _match, _interpolate, _cut;
    id<MTL4ArgumentTable> _args[3][11];
    id<MTLBuffer> _level[3][3], _cutFlag[3];
    int _current;
    BOOL _history;
}
- (id<MTLTexture>)texture:(MTLPixelFormat)format width:(NSUInteger)w height:(NSUInteger)h usage:(MTLTextureUsage)usage {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate; d.usage=usage;
    id<MTLTexture> t=[_device newTextureWithDescriptor:d];
    if(t) [_residency addAllocation:t];
    return t;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device width:(NSUInteger)w height:(NSUInteger)h format:(MTLPixelFormat)format {
    if (!(self=[super init])) return nil;
    if(!w || !h || w>8192 || h>8192) return nil;
    _device=device; _width=w; _height=h; NSError *e=nil;
    _residency=[device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&e];
    MTLCompileOptions *options=[MTLCompileOptions new]; options.mathMode=MTLMathModeSafe;
    id<MTLLibrary> lib=[device newLibraryWithSource:@(dm_framegen_msl) options:options error:&e];
    if(lib) {
        _cut=framegen_pipeline(device,lib,@"fg_cut",&e);
        _pyramid=framegen_pipeline(device,lib,@"fg_luma",&e);
        _match=framegen_pipeline(device,lib,@"fg_match",&e);
        _interpolate=framegen_pipeline(device,lib,@"fg_interpolate",&e);
    }
    if(!_residency || !_pyramid || !_match || !_interpolate || !_cut) {
        fprintf(stderr,"[dm] [framegen] optical flow unavailable: %s\n",e.localizedDescription.UTF8String ?: "missing Metal resource or function"); return nil;
    }
    MTLTextureUsage rw=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
    for(int i=0;i<2;i++) {
        _color[i]=[self texture:format width:w height:h usage:MTLTextureUsageShaderRead];
        if(!_color[i]) return nil;
        for(int l=0;l<3;l++) {
            NSUInteger lw=MAX((NSUInteger)1,(w+((8u<<l)-1))/(8u<<l)), lh=MAX((NSUInteger)1,(h+((8u<<l)-1))/(8u<<l));
            _luma[i][l]=[self texture:MTLPixelFormatR16Float width:lw height:lh usage:rw];
            _flow[i][l]=[self texture:MTLPixelFormatRGBA16Float width:lw height:lh usage:rw];
            if(!_luma[i][l] || !_flow[i][l]) return nil;
        }
    }
    MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount=5; ad.maxBufferBindCount=1;
    for(int i=0;i<3;i++) {
        _cutFlag[i]=[device newBufferWithLength:16 options:MTLResourceStorageModeShared]; if(!_cutFlag[i]) return nil; [_residency addAllocation:_cutFlag[i]];
        _output[i]=[self texture:format width:w height:h usage:rw]; if(!_output[i]) return nil;
        for(int k=0;k<11;k++) { _args[i][k]=[device newArgumentTableWithDescriptor:ad error:&e]; if(!_args[i][k]) return nil; }
        for(int l=0;l<3;l++) {
            _level[i][l]=[device newBufferWithLength:16 options:MTLResourceStorageModeShared]; if(!_level[i][l]) return nil;
            *(uint32_t*)_level[i][l].contents=l; [_residency addAllocation:_level[i][l]];
        }
    }
    [_residency commit];
    fprintf(stderr,"[dm] [framegen] image optical flow: %lux%lu, eighth-resolution motion pyramid; MetalFX frame interpolator is NOT used\n",(unsigned long)w,(unsigned long)h);
    return self;
}
- (id<MTLTexture>)currentTexture { return _color[_current]; }
- (void)resetHistory { _history=NO; }
- (void)dispatch:(id<MTL4ComputeCommandEncoder>)ce pipeline:(id<MTLComputePipelineState>)ps args:(id<MTL4ArgumentTable>)args output:(id<MTLTexture>)out {
    [ce setComputePipelineState:ps]; [ce setArgumentTable:args];
    [ce dispatchThreads:MTLSizeMake(out.width,out.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [ce barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
}
- (id<MTLTexture>)encode:(id<MTL4CommandBuffer>)cb source:(id<MTLTexture>)source rect:(const NSUInteger[4])r interval:(double)seconds slot:(int)slot {
    if(slot<0 || slot>=3 || r[2]!=_width || r[3]!=_height || r[0]+r[2]>source.width || r[1]+r[3]>source.height) { _history=NO; return nil; }
    int next=_current^1; BOOL pair=_history && isfinite(seconds) && seconds>=.01 && seconds<=.08;
    id<MTL4ComputeCommandEncoder> ce=[cb computeCommandEncoder];
    [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [ce copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(r[0],r[1],0) sourceSize:MTLSizeMake(_width,_height,1)
              toTexture:_color[next] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    for(int l=0;l<3;l++) {
        id<MTL4ArgumentTable> a=_args[slot][l];
        [a setTexture:_color[next].gpuResourceID atIndex:0]; [a setTexture:_luma[next][l].gpuResourceID atIndex:1];
        [self dispatch:ce pipeline:_pyramid args:a output:_luma[next][l]];
    }
    if(pair) {
        id<MTL4ArgumentTable> ca=_args[slot][10];
        [ca setTexture:_luma[_current][2].gpuResourceID atIndex:0]; [ca setTexture:_luma[next][2].gpuResourceID atIndex:1];
        [ca setAddress:_cutFlag[slot].gpuAddress atIndex:0]; [ce setComputePipelineState:_cut]; [ce setArgumentTable:ca];
        [ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [ce barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
        for(int dir=0;dir<2;dir++) for(int l=2;l>=0;l--) {
            int from=dir==0?next:_current, to=dir==0?_current:next;
            id<MTL4ArgumentTable> a=_args[slot][3+dir*3+l];
            [a setTexture:_luma[from][l].gpuResourceID atIndex:0]; [a setTexture:_luma[to][l].gpuResourceID atIndex:1];
            [a setTexture:(l==2?_luma[from][2]:_flow[dir][l+1]).gpuResourceID atIndex:2]; [a setTexture:_flow[dir][l].gpuResourceID atIndex:3];
            [a setAddress:_level[slot][l].gpuAddress atIndex:0];
            [self dispatch:ce pipeline:_match args:a output:_flow[dir][l]];
        }
        id<MTL4ArgumentTable> a=_args[slot][9];
        [a setAddress:_cutFlag[slot].gpuAddress atIndex:0];
        [a setTexture:_color[_current].gpuResourceID atIndex:0]; [a setTexture:_color[next].gpuResourceID atIndex:1];
        [a setTexture:_flow[0][0].gpuResourceID atIndex:2]; [a setTexture:_flow[1][0].gpuResourceID atIndex:3]; [a setTexture:_output[slot].gpuResourceID atIndex:4];
        [self dispatch:ce pipeline:_interpolate args:a output:_output[slot]];
    }
    [ce barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [ce endEncoding];
    _current=next; _history=YES;
    return pair?_output[slot]:nil;
}
@end

#endif
