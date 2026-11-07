"""Exercise the actual legacy OP_BIND_PROGRAM handler, including Witcher capture."""
from pathlib import Path
import subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[3]
class BindingTests(unittest.TestCase):
 def test_captured_and_interleaved_stage_bindings(self):
  source=(ROOT/'dm/gfx/nvn/nvn_mtl_legacy.inc').read_text()
  case=source.split('case OP_BIND_PROGRAM: { const p_bind_program *bp_ = a;',1)[1].split('case OP_BIND_STATE:',1)[0]
  body='case OP_BIND_PROGRAM: { const p_bind_program *bp_ = a;'+case
  code=r'''
#include <assert.h>
#include <stdint.h>
typedef struct {int n;} prog_t;
typedef struct {const prog_t *prog;int32_t stages;} p_bind_program;
static struct {const prog_t *prog,*cprog,*bst[5];} S;
static int g_pso_dirty,args_dirty;
static void args_dirty_all(void){args_dirty++;}
static const prog_t *bind_stages(const prog_t *p,int stages){for(int i=0;i<5;i++)if(stages>>i&1)S.bst[i]=p;return S.bst[0];}
enum { OP_BIND_PROGRAM=14 };
static void apply(const prog_t *p,int mask){p_bind_program b={p,mask};const void *a=&b;switch(OP_BIND_PROGRAM){
'''+body+r'''
}}
int main(void){prog_t gfx={1},cs={2},gfx2={3};
apply(&gfx,3);assert(S.prog==&gfx);
// Exact captured Witcher sequence: unset geometry/tessellation/compute, keep V/F.
apply(0,0x3c);assert(S.prog==&gfx && !S.cprog);
apply(&cs,0x20);assert(S.prog==&gfx && S.cprog==&cs);
apply(&gfx2,3);assert(S.prog==&gfx2 && S.cprog==&cs);
apply(0,0x20);assert(S.prog==&gfx2 && !S.cprog);
apply(&cs,0x3f);assert(S.prog==&cs && S.cprog==&cs);
apply(0,0x1f);assert(!S.prog && S.cprog==&cs);
apply(&gfx,0);assert(!S.prog && S.cprog==&cs);
apply(0,0x3f);assert(!S.prog && !S.cprog);
return 0;}
'''
  with tempfile.TemporaryDirectory() as temp:
   p=Path(temp);(p/'test.c').write_text(code)
   subprocess.run(['clang','-fsanitize=address,undefined','-g',str(p/'test.c'),'-o',str(p/'test')],check=True)
   subprocess.run([str(p/'test')],check=True)
 def test_dispatch_and_submit_index_use_compute_binding(self):
  source=(ROOT/'dm/gfx/nvn/nvn_mtl_legacy.inc').read_text()
  dispatch=source.split('static void dispatch(const p_dispatch *dp) {',1)[1].split('int min_cs',1)[0]
  self.assertIn('prog_get(S.cprog)',dispatch)
  self.assertNotIn('S.prog',dispatch)
  self.assertIn('h.op == OP_DISPATCH ? g_pp_cprog : g_pp_prog',source)
  self.assertIn('g_pp_cprog = S.cprog',source)
if __name__=='__main__':unittest.main()
