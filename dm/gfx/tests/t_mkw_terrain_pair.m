#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdint.h>
static id<MTLBuffer> buf(id<MTLDevice> d, size_t n) {
    id<MTLBuffer> b=[d newBufferWithLength:n options:MTLResourceStorageModeShared];
    assert(b); memset(b.contents,0,n); return b;
}
static id<MTLFunction> compile(id<MTLDevice> d, const char *name) {
    NSError *err=nil; MTLCompileOptions *o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion3_0;
    NSString *source=[NSString stringWithContentsOfFile:@(name) encoding:NSUTF8StringEncoding error:&err];
    if (!source) { NSLog(@"%@",err); return nil; }
    id<MTLLibrary> l=[d newLibraryWithSource:source options:o error:&err];
    if (!l) NSLog(@"%@",err);assert(l);return [l newFunctionWithName:@"main0"];
}
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==3);id<MTLDevice> d=MTLCreateSystemDefaultDevice();
    id<MTLFunction> ms=compile(d,argv[1]), fs=compile(d,argv[2]);assert(ms&&fs);
    MTLMeshRenderPipelineDescriptor *p=[MTLMeshRenderPipelineDescriptor new];
    p.meshFunction=ms;p.fragmentFunction=fs;p.maxTotalThreadsPerMeshThreadgroup=32;
    p.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
    NSError *err=nil;
    id<MTLRenderPipelineState> ps=[d newRenderPipelineStateWithMeshDescriptor:p options:MTLPipelineOptionNone reflection:nil error:&err];
    if(!ps)NSLog(@"%@",err);assert(ps);
    id<MTLBuffer> c0=buf(d,384), c1=buf(d,256), c2=buf(d,64), ss=buf(d,32*16), first=buf(d,16);
    ((float*)c0.contents)[32]=.5f; ((float*)c0.contents)[33]=4; ((float*)c0.contents)[35]=4;
    ((uint32_t*)c1.contents)[0]=8; ((uint32_t*)c2.contents)[0]=32;
    for(int i=0;i<32;i++) {
        float *q=(float*)ss.contents+4*i; q[0]=(i<8 ? -.5f : .5f);q[1]=0;q[2]=.15f;q[3]=0;
    }
    id<MTLArgumentEncoder> me=[ms newArgumentEncoderWithBufferIndex:0], fe=[fs newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> ma=buf(d,me.encodedLength), fa=buf(d,fe.encodedLength), fc=buf(d,16), border=buf(d,1024);
    [me setArgumentBuffer:ma offset:0]; [me setBuffer:c0 offset:0 atIndex:0]; [me setBuffer:c2 offset:0 atIndex:1];
    [me setBuffer:c1 offset:0 atIndex:2]; [me setBuffer:ss offset:0 atIndex:3];
    ((float*)fc.contents)[1]=1;
    MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
    sd.usage=MTLTextureUsageShaderRead;sd.storageMode=MTLStorageModeShared;
    id<MTLTexture> t=[d newTextureWithDescriptor:sd];uint32_t texels[4]={0};[t replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:texels bytesPerRow:8];
    MTLSamplerDescriptor *s=[MTLSamplerDescriptor new];s.supportArgumentBuffers=YES;
    id<MTLSamplerState> sampler=[d newSamplerStateWithDescriptor:s];assert(sampler);
    [fe setArgumentBuffer:fa offset:0]; [fe setBuffer:fc offset:0 atIndex:0]; [fe setTexture:t atIndex:1];[fe setTexture:t atIndex:3];
    for(int i=2;i<=6;i++)if(i!=3)[fe setSamplerState:sampler atIndex:i];[fe setBuffer:border offset:0 atIndex:7];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:128 height:128 mipmapped:NO];
    td.textureType=MTLTextureType2DArray;td.arrayLength=5;td.usage=MTLTextureUsageRenderTarget;td.storageMode=MTLStorageModeShared;
    id<MTLTexture> target=[d newTextureWithDescriptor:td];assert(target);
    id<MTLCommandQueue> queue=[d newCommandQueue];
    for(int pass=0;pass<16;pass++){
      id<MTLCommandBuffer> cb=[queue commandBuffer];
      for(int slice=0;slice<5;slice++){
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=target;rp.colorAttachments[0].slice=slice;
        rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
        id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:ps];
        for(id<MTLResource> b in @[c0,c1,c2,ss])[en useResource:b usage:MTLResourceUsageRead stages:MTLRenderStageMesh];
        for(id<MTLResource> b in @[t,fc,border])[en useResource:b usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [en setMeshBuffer:ma offset:0 atIndex:0];[en setMeshBuffer:first offset:0 atIndex:29];[en setFragmentBuffer:fa offset:0 atIndex:0];
        [en drawMeshThreadgroups:MTLSizeMake(1,1,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(32,1,1)];
        [en endEncoding];
      }
      [cb commit];[cb waitUntilCompleted];if(cb.error)NSLog(@"%@",cb.error);assert(!cb.error);
    }
    for(int slice=0;slice<5;slice++){
        uint16_t left[4],right[4],middle[4],top[4];
        [target getBytes:left bytesPerRow:8 bytesPerImage:8 fromRegion:MTLRegionMake2D(32,64,1,1) mipmapLevel:0 slice:slice];
        [target getBytes:right bytesPerRow:8 bytesPerImage:8 fromRegion:MTLRegionMake2D(96,64,1,1) mipmapLevel:0 slice:slice];
        [target getBytes:middle bytesPerRow:8 bytesPerImage:8 fromRegion:MTLRegionMake2D(64,64,1,1) mipmapLevel:0 slice:slice];
        [target getBytes:top bytesPerRow:8 bytesPerImage:8 fromRegion:MTLRegionMake2D(96,32,1,1) mipmapLevel:0 slice:slice];
        fprintf(stderr,"slice %d early=%#x later=%#x gap=%#x outside=%#x\n",slice,left[3],right[3],middle[3],top[3]);
        if(left[3]!=0x3c00||right[3]!=0x3c00||middle[3]||top[3])return 1;
    }
    puts("Mesh positions and both vertex groups reached all five target layers without a GPU error.");return 0;
} }
