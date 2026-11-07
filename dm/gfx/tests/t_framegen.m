#import <Metal/Metal.h>
#import "../nvn/nvn_framegen.h"
#include <stdio.h>
#include <stdlib.h>
static int failed,checks;
#define CHECK(c,s) do { checks++; if(!(c)){failed++; printf("FAIL: %s\n",s);}else printf("PASS: %s\n",s); }while(0)
static int hud;
static MTLPixelFormat testFormat=MTLPixelFormatRGBA8Unorm;
static id<MTLDevice> dev; static id<MTL4CommandQueue> queue; static id<MTLCommandQueue> readq;
static id<MTLTexture> input(int x,BOOL cut) {
    enum { w=256,h=128 }; unsigned char pixels[w*h*4];
    for(int y=0;y<h;y++) for(int i=0;i<w;i++) {
        int k=(y*w+i)*4; BOOL rect=i>=x && i<x+64 && y>=32 && y<96;
        int v=cut?230:rect?210+((i-x)/8+y/8)%2*35:16;
        if(hud && y>=40 && y<88 && i>=96 && i<104) v=255;
        pixels[k]=pixels[k+1]=pixels[k+2]=v; pixels[k+3]=255;
    }
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:testFormat width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> t=[dev newTextureWithDescriptor:d]; [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:pixels bytesPerRow:w*4]; return t;
}
static id<MTLTexture> encode(DmFrameGenerator *fg,id<MTLTexture> src,double dt,int slot) {
    id<MTL4CommandAllocator> al=[dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[dev newCommandBuffer];
    id<MTLResidencySet> rs=[dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
    id<MTLSharedEvent> e=[dev newSharedEvent];
    if (!al || !cb || !rs || !e || !src) { fprintf(stderr,"Could not allocate Metal framegen fixture\n"); exit(1); }
    [rs addAllocation:src];[rs commit];[queue addResidencySet:rs];[queue addResidencySet:fg.residency];
    [cb beginCommandBufferWithAllocator:al]; const NSUInteger r[]={0,0,256,128};
    id<MTLTexture> out=[fg encode:cb source:src rect:r interval:dt slot:slot];[cb endCommandBuffer];
    [queue commit:&cb count:1];[queue signalEvent:e value:1];
    CHECK([e waitUntilSignaledValue:1 timeoutMS:10000],"GPU completes flow work");
    [queue removeResidencySet:rs];return out;
}
static unsigned char *pixels(id<MTLTexture> t) {
    id<MTLBuffer> b=[dev newBufferWithLength:256*128*4 options:MTLResourceStorageModeShared];
    if (!b || !t) { fprintf(stderr,"Missing Metal framegen readback resource\n"); exit(1); }
    id<MTLCommandBuffer> cb=[readq commandBuffer];id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(256,128,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:256*4 destinationBytesPerImage:256*128*4];
    [e endEncoding];[cb commit];[cb waitUntilCompleted];
    unsigned char *p=malloc(256*128*4);memcpy(p,b.contents,256*128*4);return p;
}
int main(int argc,char **argv){@autoreleasepool {
    (void)argv; if(argc>1)testFormat=MTLPixelFormatBGRA8Unorm;
    if (setvbuf(stdout,NULL,_IONBF,0)) return 1;
    dev=MTLCreateSystemDefaultDevice();queue=[dev newMTL4CommandQueue];readq=[dev newCommandQueue];
    CHECK(queue!=nil,"real Metal 4 queue available");if(!queue)return 1;
    DmFrameGenerator *fg=[[DmFrameGenerator alloc]initWithDevice:dev width:256 height:128 format:testFormat];
    CHECK(fg!=nil,"production interpolation pipelines created");if(!fg)return 1;
    CHECK(!encode(fg,input(48,NO),1./60,0),"first frame is real only");
    id<MTLTexture> mid=encode(fg,input(80,NO),1./60,1);CHECK(mid!=nil,"second frame generates a midpoint");CHECK(mid.pixelFormat==testFormat,"generated and real colors share one scaler format");
    unsigned char *p=pixels(mid);int inside=0;double sum=0,centre=0;for(int y=40;y<88;y++)for(int x=0;x<256;x++)if(p[(y*256+x)*4]>150){inside++;sum+=x;}
    centre=inside?sum/inside:0;printf("generated rectangle centre %.2f (expected 95.5)\n",centre);
    CHECK(centre>90 && centre<101,"moving object reaches its intermediate position");
    CHECK(p[(64*256+148)*4]<80,"midpoint differs from the current real frame");
    free(p);CHECK(!encode(fg,input(100,NO),.3,2),"long pause resets history instead of bridging frames");
    [fg resetHistory];CHECK(!encode(fg,input(112,NO),1./60,0),"explicit suspend reset keeps first frame real");
    mid=encode(fg,input(0,YES),1./60,1);p=pixels(mid);int bad=0;for(int i=0;i<256*128;i++)bad+=abs(p[i*4]-230)>2;
    CHECK(bad==0,"scene cut preserves current pixels without crossfade");free(p);
    hud=1; [fg resetHistory];
    encode(fg,input(48,NO),1./60,0);
    mid=encode(fg,input(80,NO),1./60,1); p=pixels(mid);
    int uiBad=0;
    for(int y=40;y<88;y++) for(int x=96;x<104;x++) uiBad+=p[(y*256+x)*4]!=255;
    CHECK(uiBad==0,"stationary HUD stroke stays exact over moving scene");free(p);
    printf("frame generation: %d checks, %d failed\n",checks,failed);return failed?1:0;
}}
