// An unwritten second blend source uses zero; compare the folded descriptor with a shader that explicitly writes that zero.
#define DM_NVN_LEGACY_RENDERER_TEST 1
#include "../nvn/nvn_mtl.m"
#include "../nvn/nvn_protos.h"
#include "../../host/hle.h"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>

uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t p) { (void)p; return 0; }
int front_screen_max_fps(void) { return 60; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static void pixels(id<MTLRenderPipelineState> ps, __fp16 out[4]) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(.75, .5, .25, .875); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted, "blend draw completes");
    [t getBytes:out bytesPerRow:32 fromRegion:MTLRegionMake2D(1,1,1,1) mipmapLevel:0];
}


// Use the real recorder, not hand-built packets: a recorder/backend ABI gap
// otherwise drops every ordinary vertex/uniform binding without a GPU error.
static void binding_commands(void) {
    unsigned long length = 0;
    const hle_force_ent *entries = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &length);
    void *(*bootstrap)(const char *) = NULL;
    for (size_t i=0;i<length/sizeof *entries;i++) if (!strcmp(entries[i].name, "nvnBootstrapLoader")) bootstrap=entries[i].fn;
    CHECK(bootstrap != NULL, "production NVN bootstrap is registered");
    if (!bootstrap) return;
    PFNNVNDEVICEGETPROCADDRESSPROC gpa = (PFNNVNDEVICEGETPROCADDRESSPROC)bootstrap("nvnDeviceGetProcAddress");
#define API(name) ((NVNT_##name)gpa(NULL, #name))
    static uint8_t memory[16384] __attribute__((aligned(4096)));
    NVNmemoryPoolBuilder builder; NVNmemoryPool pool; NVNcommandBuffer commands;
    API(nvnMemoryPoolBuilderSetDefaults)(&builder);
    API(nvnMemoryPoolBuilderSetStorage)(&builder, memory, sizeof memory);
    API(nvnMemoryPoolBuilderSetFlags)(&builder, 0x24);
    CHECK(API(nvnMemoryPoolInitialize)(&pool, &builder), "binding command pool initializes");
    CHECK(API(nvnCommandBufferInitialize)(&commands, NULL), "binding recorder initializes");
    API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, sizeof memory);
    API(nvnCommandBufferBeginRecording)(&commands);
    for (int st=0;st<6;st++) for (int slot=0;slot<16;slot++)
        API(nvnCommandBufferBindUniformBuffer)(&commands, st, slot, 0x123400000ull + (st*16+slot)*4096, 256+slot*16);
    for(int slot=0;slot<16;slot++)
        API(nvnCommandBufferBindVertexBuffer)(&commands, slot, 0x567800000ull+slot*4096, 512+slot*16);
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands);
    mtl_sub_begin(); mtl_exec((const uint8_t *)(uintptr_t)handle); mtl_sub_commit(); mtl_drain();
    for(int st=0;st<6;st++) for(int slot=0;slot<16;slot++) {
        CHECK(S.ubo[st][slot].addr == 0x123400000ull+(st*16+slot)*4096 && S.ubo[st][slot].size == 256+slot*16,
              "recorded compact uniform binding reaches replay for every stage/slot");
    }
    for(int slot=0;slot<16;slot++) CHECK(S.vbuf[slot].address == 0x567800000ull+slot*4096 && S.vbuf[slot].size == 512+slot*16,
                                         "recorded compact vertex binding reaches replay for every stream");
    // Large uniform bindings and vector vertex bindings still use the wide ABI.
    API(nvnCommandBufferBeginRecording)(&commands);
    API(nvnCommandBufferBindUniformBuffer)(&commands, 1, 3, 0x987600000ull, UINT64_C(0x100000100));
    NVNbufferRange ranges[2]={{0xabc000000ull,128},{0xabc001000ull,256}};
    API(nvnCommandBufferBindVertexBuffers)(&commands, 4, 2, ranges);
    handle=API(nvnCommandBufferEndRecording)(&commands);
    mtl_sub_begin();mtl_exec((const uint8_t *)(uintptr_t)handle);mtl_sub_commit();mtl_drain();
    CHECK(S.ubo[1][3].addr==0x987600000ull && S.ubo[1][3].size==UINT64_C(0x100000100), "wide uniform binding remains exact above 4GiB");
    CHECK(S.vbuf[4].address==ranges[0].address && S.vbuf[5].address==ranges[1].address && S.vbuf[5].size==256,
          "wide multi-stream vertex binding remains intact");
    NVNsamplerPool pools[2];
    CHECK(API(nvnSamplerPoolInitialize)(&pools[0],&pool,0,32), "first sampler pool initializes");
    CHECK(API(nvnSamplerPoolInitialize)(&pools[1],&pool,1024,32), "second sampler pool initializes");
    for(int i=1;i>=0;i--) {
        API(nvnCommandBufferBeginRecording)(&commands);API(nvnCommandBufferSetSamplerPool)(&commands,&pools[i]);
        handle=API(nvnCommandBufferEndRecording)(&commands);mtl_sub_begin();mtl_exec((const uint8_t *)(uintptr_t)handle);mtl_sub_commit();mtl_drain();
        CHECK(S.samp_base==256*i,"recorded sampler pool updates replay base in both directions");
    }
    API(nvnSamplerPoolFinalize)(&pools[0]);API(nvnSamplerPoolFinalize)(&pools[1]);
    API(nvnCommandBufferFinalize)(&commands);API(nvnMemoryPoolFinalize)(&pool);
    state_reset();
#undef API
}

// CPU-written BC storage must survive readback without a packaged-layout flag.
// The Metal upload may transcode these blocks; only guest memory is lossless.
static void cpu_texture_readback(void) {
    tex_t t = {0}; t.magic=MAGIC('T','E','X',0); t.serial=nvn_new_serial();
    t.d=(nvn_texdesc){0};
    t.d.width=16; t.d.height=16; t.d.depth=2; t.d.levels=2;
    t.d.target=NVN_TEXTURE_TARGET_2D_ARRAY; t.d.format=0x41;
    nvn_tex_layout(&t.d, &t.L); t.mem=calloc(1,t.L.size);
    mtl_tex_init(&t); mtl_tex_cpu_written(&t);
    uint8_t src[128]; for(unsigned i=0;i<sizeof src;i++) src[i]=(uint8_t)(i*13+7);
    CHECK(!nvn_swizzle(&t.d,1,1,src,16,t.mem), "CPU BC mip/layer storage is swizzled");
    NVNcopyRegion r={.xoffset=4,.yoffset=0,.zoffset=0,.width=4,.height=8,.depth=1};
    uint8_t out[32]; memset(out,0xcd,sizeof out);
    mtl_read_texels(&t,1,1,&r,out,16,32);
    CHECK(!memcmp(out,src+8,8) && !memcmp(out+16,src+24,8), "CPU-written BC subregion reads exact original blocks");
    CHECK(out[8]==0xcd && out[15]==0xcd && out[24]==0xcd && out[31]==0xcd, "CPU BC strided read preserves padding");
    // A second CPU write after first read must be visible, without a GPU upload.
    src[8]^=0x5a; CHECK(!nvn_swizzle(&t.d,1,1,src,16,t.mem), "CPU BC second write is swizzled");
    mtl_read_texels(&t,1,1,&r,out,16,32);
    CHECK(!memcmp(out,src+8,8), "CPU BC read sees later writes without a draw");
    mtl_tex_release(&t); free(t.mem);
}

// A texture initialized over a CPU-visible pool already contains valid NVN
// blocks even when WriteTexels was never called and no packaged-layout flag was
// supplied. Host ShaderWrite usage for BC decoding is not a guest GPU write.
static void cpu_pool_bc_readback(void) {
    pool_t pool = {.flags=NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    tex_t t = {0}; t.magic=MAGIC('T','E','X',0); t.serial=nvn_new_serial(); t.pool=&pool;
    t.d=(nvn_texdesc){.width=256,.height=256,.depth=1,.levels=1,.target=NVN_TEXTURE_TARGET_2D,.format=0x42};
    nvn_tex_layout(&t.d, &t.L); t.mem=calloc(1,t.L.size); pool.mem=t.mem; pool.size=t.L.size;
    uint8_t *src=malloc(32768); for(unsigned i=0;i<32768;i++) src[i]=(uint8_t)(i*29+11);
    CHECK(!nvn_swizzle(&t.d,0,0,src,512,t.mem), "CPU-visible pool BC blocks are swizzled");
    mtl_tex_init(&t);
    NVNcopyRegion r={.width=256,.height=256,.depth=1}; uint8_t *out=calloc(1,32768);
    mtl_read_texels(&t,0,0,&r,out,512,32768);
    CHECK(!memcmp(out,src,32768), "unwritten CPU-visible pool reads exact original BC blocks");
    gpu_tex_mark(t.serial); CHECK(gpu_tex_written(t.serial), "actual guest GPU write takes ownership");
    mtl_tex_cpu_written(&t); CHECK(!gpu_tex_written(t.serial), "later CPU write returns ownership to guest storage");
    mtl_tex_release(&t); free(out); free(src); free(t.mem);
}

// A lazy format-view copy must precede the consumer's encoder. NFS changes
// an integer target to a normalized sampled view in the first scene after its splash.
static void format_view_draw(id<MTLFunction> vertex) {
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "fragment uint4 integer_color() { return uint4(32,64,128,96); }\n"
        "struct A { texture2d<float> image [[id(0)]]; };\n"
        "fragment float4 sample_view(constant A &a [[buffer(0)]]) { return a.image.read(uint2(1,1)); }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    CHECK(lib != nil, "format-view consumer compiles"); if (!lib) return;
    NvShader *vs=[NvShader new], *fs=[NvShader new], *sample=[NvShader new];
    vs->fn=vertex;fs->fn=[lib newFunctionWithName:@"integer_color"];fs->rf.color_known=1;fs->rf.color_mask=1;
    sample->fn=[lib newFunctionWithName:@"sample_view"];
    sample->ae=[sample->fn newArgumentEncoderWithBufferIndex:0];sample->arg_len=sample->ae.encodedLength;
    sample->rf.abi=0;sample->rf.nb=1;sample->rf.color_known=1;sample->rf.color_mask=1;
    sample->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.aid=0,.dtt=MTLTextureType2D};
    tex_t input={0},output={0};
    input.magic=output.magic=MAGIC('T','E','X',0);input.serial=nvn_new_serial();output.serial=nvn_new_serial();
    input.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8UI,.width=4,.height=4,.depth=1,.levels=1,.samples=1};
    output.d=input.d;output.d.format=NVN_FORMAT_RGBA16F;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint width:4 height:4 mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;d.storageMode=MTLStorageModePrivate;
    id<MTLTexture> original=[g_dev newTextureWithDescriptor:d];res_add(original);mtl_tex_init(&input);serial_put(input.serial,original);
    d=tex_desc(&output,0);d.storageMode=MTLStorageModeShared;
    id<MTLTexture> result=[g_dev newTextureWithDescriptor:d];res_add(result);mtl_tex_init(&output);serial_put(output.serial,result);
    CHECK(!(original.usage&MTLTextureUsagePixelFormatView), "source initially lacks format-view usage");
    view_t view={.set_format=1,.format=NVN_FORMAT_RGBA8};mtl_reg_tex(2,&input,&view);
    NvProg *program=[NvProg new];program->sh[0]=vs;program->sh[1]=fs;
    prog_t guest={.serial=nvn_new_serial()};serial_put(guest.serial,program);
    state_reset();memset(&R,0,sizeof R);S.prog=&guest;S.chmask.mask=15;S.poly.mode=NVN_POLYGON_MODE_FILL;
    R.has_rt=1;R.rt.n=1;R.rt.color[0]=&input;
    p_draw triangle={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    mtl_sub_begin();draw(&triangle,NULL);rp_end();
    R.rt.color[0]=&output;program->sh[1]=sample;S.tex[1][0]=2;g_pso_dirty=1;args_dirty_all();
    uint64_t upgrades=g_pfv_upgrades;draw(&triangle,NULL);
    CHECK(g_pfv_upgrades==upgrades+1, "consumer upgrades exactly once before argument encoding");
    CHECK(g_enc!=nil, "consumer retains a live render encoder after the copy");
    mtl_sub_commit();mtl_drain();CHECK(!mtl_last_commit_error(), "format-view producer/copy/consumer completes with Metal validation");
    __fp16 got[4];[result getBytes:got bytesPerRow:32 fromRegion:MTLRegionMake2D(1,1,1,1) mipmapLevel:0];
    float linear[4]={32.0f/255,64.0f/255,128.0f/255,96.0f/255};
    for(int c=0;c<4;c++) { float want=linear[c];
        CHECK(fabsf((float)got[c]-want)<.006f, "upgraded view preserves earlier GPU writes and samples the requested linear format"); }
    mtl_reg_tex(2,NULL,NULL);mtl_tex_release(&input);mtl_tex_release(&output);state_reset();memset(&R,0,sizeof R);
}

// Production replay: changing only a raw c10 sampler ID selects nearest/linear.
static void guest_sampler_id_draw(id<MTLFunction> vertex) {
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { texture2d<float> fp_t_cb720898_2000005A [[id(0)]]; sampler fp_t_cb720898_2000005ASmplr [[id(1)]]; };\n"
        "fragment float4 sample_id(constant A &a [[buffer(0)]]) { return a.fp_t_cb720898_2000005A.sample(a.fp_t_cb720898_2000005ASmplr,float2(.5,.5),level(0)); }\n";
    NSError *error=nil;id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];
    CHECK(lib!=nil,"raw sampler GPU shader compiles");if(!lib)return;
    NvShader *vs=[NvShader new],*fs=[NvShader new];vs->fn=vertex;fs->fn=[lib newFunctionWithName:@"sample_id"];
    NSDictionary *j=@{@"route":@"B",@"bindings":@[
        @{@"kind":@"tex",@"reg":@128,@"arg_id":@0,@"msl_name":@"fp_t_cb720898_2000005A",@"msl_type":@"texture2d<float>"},
        @{@"kind":@"samp",@"reg":[NSNull null],@"arg_id":@1,@"msl_name":@"fp_t_cb720898_2000005ASmplr",@"msl_type":@"sampler"}]};
    char err[160];int bad=nvn_refl_from_json(j,&fs->rf,err,sizeof err);
    CHECK(!bad,"raw sampler production reflection loads");if(bad)return;
    fs->rf.color_known=fs->rf.color_mask=1;fs->ae=[fs->fn newArgumentEncoderWithBufferIndex:0];fs->arg_len=fs->ae.encodedLength;
    tex_t input={0},output={0};input.magic=output.magic=MAGIC('T','E','X',0);input.serial=nvn_new_serial();output.serial=nvn_new_serial();
    input.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=2,.height=1,.depth=1,.levels=1,.samples=1};
    output.d=input.d;output.d.width=output.d.height=4;output.d.format=NVN_FORMAT_RGBA16F;
    MTLTextureDescriptor *d=tex_desc(&input,0);d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> image=[g_dev newTextureWithDescriptor:d];uint8_t pix[8]={0,0,0,255,255,255,255,255};
    [image replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:pix bytesPerRow:8];
    res_add(image);mtl_tex_init(&input);serial_put(input.serial,image);mtl_reg_tex(3,&input,NULL);
    d=tex_desc(&output,0);d.storageMode=MTLStorageModeShared;id<MTLTexture> target=[g_dev newTextureWithDescriptor:d];
    res_add(target);mtl_tex_init(&output);serial_put(output.serial,target);
    samp_par nearest={.ws=1,.wt=1,.wr=1,.minf=0,.magf=0,.lod_min=0,.lod_max=0};samp_par linear=nearest;linear.minf=linear.magf=1;
    mtl_reg_samp(10,&nearest);mtl_reg_samp(11,&linear);mtl_reg_samp(266,&nearest);
    uint32_t *words=aligned_alloc(16384,16384);memset(words,0,16384);mtl_pool_add(words,16384);
    NvProg *program=[NvProg new];program->sh[0]=vs;program->sh[1]=fs;prog_t guest={.serial=nvn_new_serial()};serial_put(guest.serial,program);
    state_reset();memset(&R,0,sizeof R);S.prog=&guest;S.chmask.mask=15;S.poly.mode=NVN_POLYGON_MODE_FILL;
    S.tex[1][128]=3;S.ubo[1][7]=(p_bind_buf){.addr=(uintptr_t)words,.size=8};R.has_rt=1;R.rt.n=1;R.rt.color[0]=&output;
    p_draw triangle={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    for(int i=0;i<4;i++) {
        S.samp_base=i==3?256:0;words[0]=i==1?11:10;args_dirty_all();mtl_sub_begin();draw(&triangle,NULL);mtl_sub_commit();mtl_drain();
        CHECK(!mtl_last_commit_error(),"raw sampler draw completes with Metal validation");
        __fp16 out[4];[target getBytes:out bytesPerRow:32 fromRegion:MTLRegionMake2D(1,1,1,1) mipmapLevel:0];
        CHECK(fabsf((float)out[0]-(i==1?.5f:1.f))<.01f,"raw sampler ID switches nearest/linear/nearest in production replay");
    }
    mtl_pool_del(words);free(words);mtl_reg_tex(3,NULL,NULL);mtl_tex_release(&input);mtl_tex_release(&output);state_reset();memset(&R,0,sizeof R);
}

// Exercise the production integer-entry choice with the R16Uint target that
// rejected Witcher's depth/composite pass, and keep normalized targets intact.
static void integer_entry_draw(id<MTLFunction> vertex) {
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "fragment float4 f() { return float4(0.25); }\n"
        "fragment uint4 fu() { return uint4(513); }\n";
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];
    CHECK(lib!=nil,"integer-entry fixtures compile"); if (!lib) return;
    NvShader *vs=[NvShader new],*fs=[NvShader new]; vs->fn=vertex;
    fs->fn=[lib newFunctionWithName:@"f"];fs->fn_u=[lib newFunctionWithName:@"fu"];
    fs->rf.color_known=1;fs->rf.color_mask=1;
    pso_key k={0};k.samples=1;k.chmask=15;k.cfmt[0]=MTLPixelFormatR16Uint;
    MTLRenderPipelineDescriptor *d=pso_desc(&k,vs,fs,nil,0);
    CHECK(d.fragmentFunction==fs->fn_u,"unsigned attachment selects packaged integer entry");
    id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(ps!=nil,"R16Uint pipeline is accepted");
    if(ps) {
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Uint width:4 height:4 mipmapped:NO];
        td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> t=[g_dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=t;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLCommandBuffer> cb=[[g_dev newCommandQueue] commandBuffer];
        id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];
        [cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted,"integer entry draw completes");
        uint16_t pixels[16]={0};[t getBytes:pixels bytesPerRow:8 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
        int exact=1;for(int i=0;i<16;i++)exact&=pixels[i]==513;CHECK(exact,"R16Uint pixels retain integer values");
    }
    k.cfmt[0]=MTLPixelFormatRGBA8Unorm;
    CHECK(pso_desc(&k,vs,fs,nil,0).fragmentFunction==fs->fn,"normalized output keeps float entry");
    k.cfmt[0]=MTLPixelFormatR16Sint;
    CHECK(pso_desc(&k,vs,fs,nil,0).fragmentFunction==fs->fn,"signed target does not use unsigned entry");
    k.cfmt[0]=MTLPixelFormatR16Uint;k.cfmt[1]=MTLPixelFormatRGBA8Unorm;
    CHECK(pso_desc(&k,vs,fs,nil,0).fragmentFunction==fs->fn_u,"unwritten normalized attachment is ignored");
    fs->rf.color_mask=3;
    CHECK(pso_desc(&k,vs,fs,nil,0).fragmentFunction==fs->fn,"mixed written targets do not use unsigned entry");
    fs->rf.color_mask=1;k.cfmt[1]=0;k.lmap[0]=0xff;
    CHECK(pso_desc(&k,vs,fs,nil,1).fragmentFunction==fs->fn,"unmapped merged output is not an integer write");
    k.lmap[0]=0;
    CHECK(pso_desc(&k,vs,fs,nil,1).fragmentFunction==fs->fn_u,"merged output location selects integer entry");
    CHECK(pso_desc(&k,vs,fs,fs->fn,0).fragmentFunction==fs->fn,"explicit fragment override remains intact");
}

static void classic_metalfx_present(void) {
    if (![MTLFXSpatialScalerDescriptor supportsDevice:g_dev]) {
        puts("SKIP: this GPU has no classic MetalFX spatial scaler");
        return;
    }
    setenv("DM_PRESENT_UPSCALE", "metalfx", 1);
    const NSUInteger widths[] = {1280, 960}, heights[] = {720, 540};
    for (int i = 0; i < 2; i++) {
        NSUInteger w = widths[i], h = heights[i];
        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                     width:w+2 height:h+2 mipmapped:NO];
        sd.storageMode = MTLStorageModeShared; sd.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> src = [g_dev newTextureWithDescriptor:sd];
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:2000 height:1080 mipmapped:NO];
        od.storageMode = MTLStorageModeShared; od.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> out = [g_dev newTextureWithDescriptor:od];
        CHECK(src && out, "MetalFX present textures exist");
        if (!src || !out) return;
        uint32_t *src_pixels = calloc((w+2)*(h+2), sizeof *src_pixels);
        if (!src_pixels) abort();
        for (NSUInteger y = 1; y <= h; y++)
            for (NSUInteger x = 1; x <= w; x++) src_pixels[y*(w+2)+x] = 0xffc84080;
        [src replaceRegion:MTLRegionMake2D(0, 0, w+2, h+2) mipmapLevel:0 withBytes:src_pixels bytesPerRow:(w+2)*4];
        free(src_pixels);
        int crop[4] = {1, 1, (int)w, (int)h};
        g_present_n += 30;
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        CHECK(present_encode_m4(cb, src, out, crop, 0) == 2, i ? "540p uses MetalFX" : "720p uses MetalFX");
        [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "classic MetalFX GPU pass completes");
        uint8_t p[4];
        [out getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(1000, 540, 1, 1) mipmapLevel:0];
        CHECK(abs(p[0]-200)<=3 && abs(p[1]-64)<=3 && abs(p[2]-128)<=3 && p[3]==255,
              "cropped MetalFX present preserves the source's display colors");
        [out getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 540, 1, 1) mipmapLevel:0];
        CHECK(p[0]==0 && p[1]==0 && p[2]==0 && p[3]==255, "MetalFX present keeps black aspect-ratio bars");
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "--cpu-only")) {
        cpu_pool_bc_readback();
        printf("legacy CPU pool readback: %d checks, %d failures\n", checks, failed);
        return failed != 0;
    }
    mtl_init();
    if (getenv("DM_TEST_CLASSIC_METALFX")) {
        classic_metalfx_present();
        printf("classic MetalFX: %d checks, %d failures\n", checks, failed);
        return failed != 0;
    }
    binding_commands(); cpu_texture_readback(); cpu_pool_bc_readback(); NSError *error = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "fragment float4 f() { return float4(.125,.25,.5,.375); }\n"
        "struct O { float4 a [[color(0)]]; float4 b [[color(0), index(1)]]; };\n"
        "fragment O f2() { return {float4(.125,.25,.5,.375), float4(0)}; }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&error];
    CHECK(lib != nil, "reference shaders compile"); if (!lib) return 1;
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    vs->fn = [lib newFunctionWithName:@"v"];
    fs->fn = [lib newFunctionWithName:@"f"];
    fs->rf.color_known = 1; fs->rf.color_mask = 1;
    integer_entry_draw(vs->fn);
    format_view_draw(vs->fn);
    guest_sampler_id_draw(vs->fn);
    pso_key k = {0}; k.samples = 1; k.chmask = 15; k.blend_en = 1; k.cfmt[0] = MTLPixelFormatRGBA16Float;
    int factors[] = {NVN_BLEND_FUNC_SRC1_COLOR, NVN_BLEND_FUNC_ONE_MINUS_SRC1_COLOR, NVN_BLEND_FUNC_SRC1_ALPHA, NVN_BLEND_FUNC_ONE_MINUS_SRC1_ALPHA};
    for (int i = 0; i < 4; i++) {
        k.blend[0] = (blend_st){.src_rgb=factors[i], .dst_rgb=factors[(i+1)%4], .src_a=factors[(i+2)%4], .dst_a=factors[(i+3)%4], .eq_rgb=1, .eq_a=1};
        MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, fs, nil, 0);
        CHECK(d.colorAttachments[0].blendingEnabled, "blending remains enabled");
        MTLRenderPipelineDescriptor *ref = [d copy]; ref.fragmentFunction = [lib newFunctionWithName:@"f2"];
        ref.colorAttachments[0].sourceRGBBlendFactor = bfac(k.blend[0].src_rgb); ref.colorAttachments[0].destinationRGBBlendFactor = bfac(k.blend[0].dst_rgb);
        ref.colorAttachments[0].sourceAlphaBlendFactor = bfac(k.blend[0].src_a); ref.colorAttachments[0].destinationAlphaBlendFactor = bfac(k.blend[0].dst_a);
        id<MTLRenderPipelineState> reference = [g_dev newRenderPipelineStateWithDescriptor:ref error:&error];
        CHECK(reference != nil, "explicit secondary source compiles");
        __fp16 want[4]; if (reference) pixels(reference, want);
        for (int metal4 = 0; metal4 < 2; metal4++) {
            id<MTLRenderPipelineState> ps = metal4 ? pso_build(&k, vs, fs, nil, 0, 0, &error) : [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
            CHECK(ps != nil, "folded pipeline compiles on both paths");
            if (ps && reference) {
                __fp16 got[4]; pixels(ps, got);
                CHECK(want[0] == got[0] && want[1] == got[1] && want[2] == got[2] && want[3] == got[3],
                      "folded blending equals explicit zero source");
            }
        }
    }
    fs->rf.color_mask = 3;
    CHECK(pso_desc(&k, vs, fs, nil, 0).colorAttachments[0].sourceRGBBlendFactor == bfac(k.blend[0].src_rgb), "written secondary output is preserved");
    fs->rf.color_mask = 1; fs->rf.color_known = 0;
    CHECK(pso_desc(&k, vs, fs, nil, 0).colorAttachments[0].sourceRGBBlendFactor == bfac(k.blend[0].src_rgb), "unknown output map is preserved");
    // A written source 1 must use the alternate entry on either compiler path.
    NSString *dualSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; };\n"
        "struct D { float4 a [[color(0)]]; float4 b [[color(0), index(1)]]; };\n"
        "fragment O mrt() { return {float4(.125,.25,.5,.375), float4(.25,.5,.75,.625)}; }\n"
        "fragment D dual() { return {float4(.125,.25,.5,.375), float4(.25,.5,.75,.625)}; }\n";
    id<MTLLibrary> dl = [g_dev newLibraryWithSource:dualSource options:nil error:&error];
    CHECK(dl != nil, "dual-source and MRT entries compile together");
    fs->fn = [dl newFunctionWithName:@"mrt"];
    fs->fn_d = [dl newFunctionWithName:@"dual"];
    fs->rf.color_known = 1; fs->rf.color_mask = 3; fs->has_dual = 1;
    for (int i = 0; i < 4; i++) {
        k.blend[0] = (blend_st){.src_rgb=factors[i], .dst_rgb=NVN_BLEND_FUNC_ONE, .src_a=factors[i], .dst_a=NVN_BLEND_FUNC_ONE, .eq_rgb=1, .eq_a=1};
        MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, fs, nil, 0);
        CHECK(d.fragmentFunction == fs->fn_d, "SRC1 pipeline selects the dual-source entry");
        for (int metal4 = 0; metal4 < 2; metal4++) {
            id<MTLRenderPipelineState> ps = metal4 ? pso_build(&k, vs, fs, nil, 0, 0, &error) : [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
            CHECK(ps != nil, "written secondary source compiles on both paths");
            if (ps) {
                __fp16 got[4]; pixels(ps, got);
                float src[4]={.125,.25,.5,.375}, secondary[4]={.25,.5,.75,.625}, dst[4]={.75,.5,.25,.875};
                for (int c=0;c<4;c++) {
                    float factor = (i<2 && c<3) ? secondary[c] : secondary[3];
                    if (i&1) factor = 1-factor;
                    CHECK(fabsf((float)got[c] - (dst[c]+src[c]*factor)) < .001, "actual secondary color/alpha reaches the blend unit");
                }
            }
        }
    }
    k.blend_en = 0; k.cfmt[1] = MTLPixelFormatRGBA16Float; k.chmask = 255;
    MTLRenderPipelineDescriptor *mrt = pso_desc(&k, vs, fs, nil, 0);
    CHECK(mrt.fragmentFunction == fs->fn, "ordinary MRT keeps the original entry");
    CHECK(mrt.colorAttachments[1].writeMask == MTLColorWriteMaskAll, "ordinary MRT keeps output 1 writable");
    CHECK([g_dev newRenderPipelineStateWithDescriptor:mrt error:&error] != nil, "ordinary MRT pipeline compiles");
    CHECK(pso_build(&k, vs, fs, nil, 0, 0, &error) != nil, "ordinary MRT compiles on Metal 4");
    k.blend_en = 1;
    CHECK(pso_desc(&k, vs, fs, nil, 0).colorAttachments[1].pixelFormat == MTLPixelFormatInvalid, "dual source omits MRT 1 from the physical pipeline");
    MTLRenderPipelineDescriptor *boundMRT = pso_desc(&k, vs, fs, nil, 0);
    CHECK([g_dev newRenderPipelineStateWithDescriptor:boundMRT error:&error] != nil, "dual source permits a bound unwritten MRT 1 on Metal");
    CHECK(pso_build(&k, vs, fs, nil, 0, 0, &error) != nil, "dual source permits a bound unwritten MRT 1 on Metal 4");
    // Replay real NVN draws while both guest targets remain bound. Switching blend modes
    // must split physical passes, retain clears, and restore normal output 1.
    if (!getenv("DM_NVN_TBDR")) setenv("DM_NVN_TBDR", "0", 1); setenv("DM_PSO_HYBRID", "0", 1);
    tex_t targets[2] = {0}; id<MTLTexture> textures[2];
    for (int i=0;i<2;i++) {
        targets[i].magic=MAGIC('T','E','X',0); targets[i].serial=99501+i;
        targets[i].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA16F,.width=4,.height=4,.depth=1,.levels=1,.samples=1};
        MTLTextureDescriptor *td=tex_desc(&targets[i],0); td.storageMode=MTLStorageModeShared;
        textures[i]=[g_dev newTextureWithDescriptor:td]; res_add(textures[i]); mtl_tex_init(&targets[i]); serial_put(targets[i].serial,textures[i]);
    }
    NvProg *program=[NvProg new]; program->sh[0]=vs;program->sh[1]=fs;
    prog_t guestProgram={.serial=99500}; serial_put(guestProgram.serial,program);
    state_reset(); memset(&R,0,sizeof R); S.prog=&guestProgram; S.chmask.mask=255;
    S.poly.cull=NVN_FACE_NONE; S.poly.mode=NVN_POLYGON_MODE_FILL;
    S.blend[0]=(blend_st){.src_rgb=NVN_BLEND_FUNC_SRC1_COLOR,.dst_rgb=NVN_BLEND_FUNC_ONE,.src_a=NVN_BLEND_FUNC_SRC1_ALPHA,.dst_a=NVN_BLEND_FUNC_ONE,.eq_rgb=1,.eq_a=1};
    R.has_rt=1;R.rt.n=2;R.rt.color[0]=&targets[0];R.rt.color[1]=&targets[1];
    R.clear_c[0]=R.clear_c[1]=1;R.cc[0]=MTLClearColorMake(.75,.5,.25,.875);R.cc[1]=MTLClearColorMake(.2,.3,.4,.5);
    p_draw triangle={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    for (int phase=0;phase<3;phase++) {
        S.color.blend_en=phase==1?0:1;g_pso_dirty=g_dss_dirty=1;
        mtl_sub_begin();draw(&triangle,NULL);
        CHECK(g_enc_dual==(phase!=1), "production draw picks the matching physical pass");
        CHECK((g_pass.cfmt[1]!=0)==(phase==1), "ordinary MRT target is restored only when written");
        mtl_sub_commit();mtl_drain();CHECK(!mtl_last_commit_error(), "production dual/MRT draw completes without validation error");
        __fp16 second[4];[textures[1] getBytes:second bytesPerRow:32 fromRegion:MTLRegionMake2D(1,1,1,1) mipmapLevel:0];
        float clear[4]={.2,.3,.4,.5},written[4]={.25,.5,.75,.625};
        for(int c=0;c<4;c++) CHECK(fabsf((float)second[c]-(phase==0?clear[c]:written[c]))<.001, "secondary target clear/write survives dual-source transitions");
    }
    mtl_sub_begin();
    for(int phase=0;phase<3;phase++) {
        uint64_t before=g_pass.serial;
        S.color.blend_en=phase==1?1:0;g_pso_dirty=g_dss_dirty=1;draw(&triangle,NULL);
        CHECK(g_pass.serial>before, "changing dual-source mode splits the physical pass within one submission");
        CHECK(g_enc_dual==(phase==1), "same-submission transition chooses the correct attachment layout");
    }
    mtl_sub_commit();mtl_drain();CHECK(!mtl_last_commit_error(), "same-submission dual/MRT transitions complete");
    S.color.blend_en=1;uint8_t map[8]={0};id<MTLFunction> tile=fs->fn;
    CHECK(!fz_p2_draw(program,&triangle,NULL,map,&tile), "tile-fetch planner preserves dual-source draws as a separate pass");
    CHECK(tile == nil, "rejected tile merge clears any previous specialization");
    for(int i=0;i<2;i++)mtl_tex_release(&targets[i]);

    fs->has_dual=0; fs->fn_d=nil;
    if (argc > 2) {
        NSString *text=[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error];
        MTLCompileOptions *options=[MTLCompileOptions new]; options.languageVersion=MTLLanguageVersion3_0;
        options.preserveInvariance=YES; options.fastMathEnabled=NO;
        id<MTLLibrary> actual=[g_dev newLibraryWithSource:text options:options error:&error];
        CHECK(actual != nil, "actual supplemental fragment library compiles");
        MTLFunctionConstantValues *values=[MTLFunctionConstantValues new];
        id<MTLFunction> primary=[actual newFunctionWithName:@"main0" constantValues:values error:&error];
        id<MTLFunction> secondary=[actual newFunctionWithName:@"main0_d" constantValues:values error:&error];
        CHECK(primary && secondary, "actual primary and dual entries remain available");
        NSUInteger original=[primary newArgumentEncoderWithBufferIndex:0].encodedLength;
        CHECK(original && original == [secondary newArgumentEncoderWithBufferIndex:0].encodedLength,
              "actual dual entry preserves the original argument-buffer layout");
    }
    {
        NSString *source = argc > 1 ? [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error] :
            @"#include <metal_stdlib>\nusing namespace metal; struct O {float4 c [[color(0)]];float z [[depth(any)]];}; fragment O main0() {return O{float4(1),.5};}";
        id<MTLLibrary> fragmentLibrary = [g_dev newLibraryWithSource:source options:nil error:&error];
        id<MTLLibrary> vertexLibrary = [g_dev newLibraryWithSource:
            @"#include <metal_stdlib>\nusing namespace metal; struct V {float4 p [[position]];float4 uv [[user(locn1)]];}; vertex V v(uint i [[vertex_id]]) {return V{float4(0,0,.5,1),float4(0)};}"
            options:nil error:&error];
        CHECK(fragmentLibrary && vertexLibrary, "actual depth fragment and matching vertex compile");
        vs->fn = [vertexLibrary newFunctionWithName:@"v"];
        fs->fn = [fragmentLibrary newFunctionWithName:@"main0"];
        fs->depth_out=1;
        k.blend_en=0; k.cfmt[0]=MTLPixelFormatBGRA8Unorm; k.topology=MTLPrimitiveTopologyClassTriangle;
        for (NSNumber *format in @[@0,@250,@252,@260,@0]) {
            k.dfmt=format.unsignedIntValue; k.sfmt=k.dfmt==260?260:0;
            NSError *why=nil;
            id<MTLRenderPipelineState> ps=pso_build(&k,vs,fs,nil,0,0,&why);
            printf("actual depth fragment: format=%u pipeline=%d error=%s\n", k.dfmt, ps!=nil, why.localizedDescription.UTF8String?:"-");
            CHECK((ps!=nil)==(k.dfmt!=0), "depth output requires a real depth attachment");
        }
    }
    printf("legacy blend: %d checks, %d failures\n", checks, failed);
    return failed != 0;
}}
