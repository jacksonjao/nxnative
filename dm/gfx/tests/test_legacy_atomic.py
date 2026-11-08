#!/usr/bin/env python3
"""Synthetic native/iOS ABI regression; no game files required."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('legacy_atomic', ROOT/'dm/gfx/tools/dmsh_legacy_atomic.py')
ATOMIC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ATOMIC)
SOURCE = """#include <metal_stdlib>
using namespace metal;
struct Args {
constant uint* constants [[id(0)]];
texture2d<float> mask [[id(3)]];
sampler smp [[id(4)]];
texture2d<uint, access::read_write> target [[id(5)]];
};
fragment void update_image(constant Args& a [[buffer(0)]], float4 p [[position]]) {
uint2 xy=uint2(p.xy);
float2 size=float2(a.target.get_width(),a.target.get_height());
if(a.mask.sample(a.smp,p.xy/size).x<0.5) discard_fragment();
uint previous=a.target.atomic_fetch_max(xy,a.constants[0]).x;
}
"""
META = {'route':'B', 'stage':'ps', 'entry':'update_image', 'msl_entry_kind':'fragment',
        'raster':{'colors':[], 'sample_mask':0, 'discard':1}, 'bindings':[
        {'kind':'cbuf','msl_type':'constant uint*','msl_name':'constants','arg_id':0,'reg':0},
        {'kind':'tex','msl_type':'texture2d<float>','msl_name':'mask','arg_id':3,'reg':0},
        {'kind':'samp_tex','msl_type':'sampler','msl_name':'smp','arg_id':4,'reg':0},
        {'kind':'img','msl_type':'texture2d<uint, access::read_write>','msl_name':'target','arg_id':5,'reg':1,'atomic':True}]}
DIGEST='a'*64

class AtomicABI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory()
        root=Path(cls.tmp.name)
        code=root/'check.m'
        code.write_text(r'''#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "nvn_refl.h"
#include "nvn_atomic_image_record.h"
int main(int argc,const char**argv) { @autoreleasepool {
 NSData* data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
 NSDictionary*j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
 NSString*why=nvn_atomic_image_record_error(j,[NSString stringWithUTF8String:argv[2]]);
 if(why) return 2;
 nvn_refl r; char error[256]; if(nvn_refl_from_json(j,&r,error,sizeof error)) return 3;
 int images=0; for(int i=0;i<r.nb;i++) if(r.b[i].kind==NVN_RB_IMGA) {
   if(r.b[i].aid!=5||r.b[i].reg!=1||!r.b[i].rw||r.b[i].dtt!=MTLTextureType2D) return 4; images++;
 }
 free(r.c1); return images!=1;
} }
''')
        cls.binary=root/'check'
        subprocess.run(['xcrun','clang','-fobjc-arc','-I'+str(ROOT/'dm/gfx/nvn'),str(code),str(ROOT/'dm/gfx/nvn/nvn_refl.m'),'-framework','Metal','-framework','Foundation','-o',str(cls.binary)],check=True)
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def native_accepts(self, meta, digest=DIGEST):
        p=Path(self.tmp.name)/'reflection.json';p.write_text(json.dumps(meta))
        return subprocess.run([str(self.binary),str(p),digest]).returncode==0
    def test_separate_reflection_preserves_native_and_discard(self):
        native=copy.deepcopy(META)
        record=ATOMIC.reflection(SOURCE,native,DIGEST)
        self.assertEqual(native,META)
        lowered,proof=ATOMIC.lower(SOURCE)
        self.assertIn('discard_fragment()',lowered)
        self.assertIn('dm_legacy_atomic_max_2d(a.target, xy, a.constants[0], dm_legacy_atomic_layout).x',lowered)
        self.assertEqual(proof['lowered_sha256'],hashlib.sha256(lowered.encode()).hexdigest())
        self.assertEqual(record['bindings'][-1]['kind'],'img_atomic_2d')
        self.assertTrue(self.native_accepts(record))
        self.assertFalse(self.native_accepts(record,'b'*64))
    def test_unproven_sources_are_rejected(self):
        for old,new in [('atomic_fetch_max','atomic_fetch_add'),('uint, access::read_write','int, access::read_write'),('texture2d<uint','texture2d_array<uint'),('fragment void','kernel void'),('buffer(0)','buffer(29)'),('uint previous=', 'uint escaped=a.target.read(xy).x; uint previous=')]:
            with self.subTest(new=new),self.assertRaises(ValueError): ATOMIC.reflection(SOURCE.replace(old,new),META,DIGEST)
    def test_bad_reflection_fails_before_publication(self):
        for field,value in [('stage','cs'),('entry','wrong'),('raster',{'colors':[0]})]:
            m=copy.deepcopy(META);m[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError): ATOMIC.reflection(SOURCE,m,DIGEST)
        for index,field,value in [(3,'arg_id',4),(3,'reg',32),(3,'atomic',False),(1,'reg',256),(0,'reg',16),(1,'rw',True),(0,'msl_type','device uint*'),(1,'kind','sbuf')]:
            m=copy.deepcopy(META);m['bindings'][index][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(ValueError): ATOMIC.reflection(SOURCE,m,DIGEST)
    def test_runtime_rejects_modified_records(self):
        valid=ATOMIC.reflection(SOURCE,META,DIGEST)
        for field,value in [('parameter_slot',28),('image_reg',32),('library_sha256','broken'),('pixel_format','R32Sint')]:
            m=copy.deepcopy(valid);m['legacy_image_atomic'][field]=value
            with self.subTest(field=field): self.assertFalse(self.native_accepts(m))
        for index,field,value in [(3,'kind','img'),(3,'reg',0),(1,'rw',True),(1,'arg_id',5),(0,'msl_type','device uint*'),(0,'reg',16)]:
            m=copy.deepcopy(valid);m['bindings'][index][field]=value
            with self.subTest(field=field,value=value): self.assertFalse(self.native_accepts(m))
        m=copy.deepcopy(valid);m['bindings'].pop();self.assertFalse(self.native_accepts(m))
        m=copy.deepcopy(valid);m['raster']['colors']=[0];self.assertFalse(self.native_accepts(m))

    def test_violet_border_sampler_with_fragment_atomic_max(self):
        source = SOURCE.replace('struct Args {', 'struct dm_border_t { uint mask; float4 k[32]; };\nstruct Args {').replace(
            'sampler smp [[id(4)]];', 'sampler smp [[id(4)]];\nsampler smp_w [[id(6)]];\nconstant dm_border_t* dm_border [[id(7)]];'
        ).replace('if(a.mask.sample(a.smp,p.xy/size).x<0.5)', '''float alpha=a.mask.sample(a.smp,p.xy/size).x;
if(a.dm_border->mask & 1u) alpha=mix(alpha,a.mask.sample(a.smp_w,p.xy/size).x,a.dm_border->k[0].x);
if(alpha<0.5)''')
        native = copy.deepcopy(META)
        native['bindings'] += [
            {'kind':'samp_tex','msl_type':'sampler','msl_name':'smp_w','arg_id':6,'reg':0,'border_bit':0},
            {'kind':'border','msl_type':'constant dm_border_t*','msl_name':'dm_border','arg_id':7},
        ]
        record = ATOMIC.reflection(source,native,DIGEST)
        self.assertTrue(self.native_accepts(record))
        for idx,fields in ((4,{'reg':1}),(4,{'border_bit':32}),(5,{'rw':True}),(5,{'msl_type':'constant uint*'})):
            with self.subTest(fields=fields):
                changed = copy.deepcopy(native)
                changed['bindings'][idx].update(fields)
                with self.assertRaises(ValueError): ATOMIC.reflection(source,changed,DIGEST)
                changed = copy.deepcopy(record)
                changed['bindings'][idx].update(fields)
                self.assertFalse(self.native_accepts(changed))

if __name__=='__main__': unittest.main()
