#!/usr/bin/env python3
"""Exercise Route C identity/ABI/OS gates before signed code is loaded."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class FrameworkIdentity(unittest.TestCase):
    def test_manifest_gates(self):
        harness = r'''
#import <Foundation/Foundation.h>
#import "LibraryFramework.h"
#include <assert.h>
const dm_game_profile *dm_profile_find(const char *id){return NULL;}
int dm_set_game_image_header(const void *p){return 0;}
int main(){@autoreleasepool{
    NSString *titleID=@"010029b0118e8000";NSArray *mods=@[@"main",@"subsdk1"];
    NSDictionary *good=@{@"schema":@1,@"title_id":titleID.uppercaseString,@"modules":mods,
        @"chain":@"b-testchain",@"tonton_host_abi":TONTON_FRAMEWORK_ABI,
        @"framework":@"DmGame010029B0118E8000.framework",@"framework_executable":@"DmGame",
        @"image_marker":@"dm_game_image_marker",@"loader":@"FR",@"nro_count":@0,@"min_os":@"16.1"};
    assert(!TonTonFrameworkProblem(good,titleID,mods,@"17.7.11"));
    assert(!TonTonFrameworkProblem(good,titleID,mods,@"16.1"));
    assert(TonTonFrameworkProblem(good,titleID,mods,@"16.0"));
    assert(TonTonFrameworkProblem(nil,titleID,mods,@"27.0"));
    NSMutableDictionary *unbound=good.mutableCopy;unbound[@"unbound_resource_tables"]=@YES;
    assert(TonTonFrameworkProblem(unbound,titleID,mods,@"27.0"));
    unbound[@"unbound_resource_tables"]=@NO;
    assert(!TonTonFrameworkProblem(unbound,titleID,mods,@"27.0"));
    for(NSString *key in good){
        NSMutableDictionary *bad=good.mutableCopy;[bad removeObjectForKey:key];
        assert(TonTonFrameworkProblem(bad,titleID,mods,@"27.0"));
    }
    NSDictionary *changes=@{@"schema":@2,@"title_id":@"0100000000000000",
        @"modules":@[@"subsdk1",@"main"],@"chain":@"b-other",
        @"tonton_host_abi":@"upstream",@"framework":@"../../Other.framework",
        @"framework_executable":@"../Other",@"image_marker":@"foreign",
        @"loader":@"FH",@"nro_count":@1,@"min_os":@"26.0"};
    for(NSString *key in changes){NSMutableDictionary *bad=good.mutableCopy;bad[key]=changes[key];
        assert(TonTonFrameworkProblem(bad,titleID,mods,@"17.0"));}
    for(id version in @[@"",@"16..1",@".16",@"16.",@"16.1.0.0",@"16.x",@16]){
        NSMutableDictionary *bad=good.mutableCopy;bad[@"min_os"]=version;
        assert(TonTonFrameworkProblem(bad,titleID,mods,@"27.0"));}
    NSMutableDictionary *own=good.mutableCopy;
    own[@"loader"]=@"FH";
    own[@"tonton_host_abi"]=TONTON_INDEPENDENT_ABI;
    own[@"chain"]=@"b-0123456789ab";
    assert(!TonTonFrameworkProblem(own,titleID,mods,@"16.1"));
    own[@"chain"]=@"b-../../escape";
    assert(TonTonFrameworkProblem(own,titleID,mods,@"16.1"));
    own[@"chain"]=@"b-0123456789ab";
    own[@"tonton_host_abi"]=TONTON_FRAMEWORK_ABI;
    assert(TonTonFrameworkProblem(own,titleID,mods,@"16.1"));
    puts("35 framework identity checks passed");
}}
'''
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'test.m').write_text(harness)
            (p / 'dmsh_chain.h').write_text('#define DMSH_CHAIN "testchain"\n')
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                            '-I', str(p), '-I', str(ROOT / 'dm/host'),
                            '-I', str(ROOT / 'dm/ios/LibraryApp/Sources'),
                            str(p / 'test.m'), '-o', str(p / 'test')], check=True)
            subprocess.run([str(p / 'test')], check=True)

    def test_dispatch_to_selected_image_and_verify_its_shader_chain(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'engine.c').write_text(r'''
const int dm_glue_version = 1;
const char *dm_glue_shader_chain(void) { return "b-0123456789ab"; }
const char *dm_glue_start_game(const char *const *argv, int argc, const void *image) {
    return argc == 2 && image ? 0 : "bad invocation";
}
void dm_glue_present_game(void *window) {}
void dm_glue_focus_event(int event) {}
void dm_glue_set_catalog(void *(*catalog)(void *)) {}
''')
            (p / 'test.m').write_text(r'''
#import "IndependentGameHost.h"
#include <assert.h>
int main(int argc, char **argv) { @autoreleasepool {
    void *h = dlopen(argv[1], RTLD_LOCAL | RTLD_NOW | RTLD_FIRST);
    assert(h);
    Dl_info own;
    assert(dladdr(dlsym(h, "dm_glue_version"), &own));
    TonTonGameHost host = {0};
    assert(!TonTonReadIndependentHost(h, &argc, @"b-0123456789ab", &host));
    assert(!TonTonReadIndependentHost(h, own.dli_fbase, @"b-fedcba987654", &host));
    assert(!host.start);
    assert(TonTonReadIndependentHost(h, own.dli_fbase, @"b-0123456789ab", &host));
    assert(!host.start((const char *const *)argv, argc, own.dli_fbase));
} }
''')
            subprocess.run(['xcrun', 'clang', '-dynamiclib', str(p / 'engine.c'),
                            '-o', str(p / 'engine.dylib')], check=True)
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                            '-I', str(ROOT / 'dm/ios/LibraryApp/Sources'),
                            str(p / 'test.m'), '-o', str(p / 'test')], check=True)
            subprocess.run([str(p / 'test'), str(p / 'engine.dylib')], check=True)


if __name__ == '__main__':
    unittest.main()
