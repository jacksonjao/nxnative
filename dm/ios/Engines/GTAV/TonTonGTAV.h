#import <UIKit/UIKit.h>
BOOL TonTonGTAVAvailable(NSString *slot);
BOOL TonTonGTAVIsActive(void);
void TonTonGTAVFocus(int focus, int suspend);
UIViewController *TonTonGTAVCreateController(NSString *slot);
UIViewController *TonTonGTAVCreateControllerWithReturn(NSString *slot, void (^returnToLibrary)(void));
