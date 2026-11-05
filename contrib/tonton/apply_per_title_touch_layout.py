from pathlib import Path
import sys
r=Path(sys.argv[1]).resolve()
def modify(path,fn):
 p=r/path
 p.write_text(fn(p.read_text()))
def edit(s):
 s=s.replace('static NSString *const TTPadLayoutPreference = @"tonton.touch-layout.v2";','''static NSString *const TTPadLayoutPreference = @"tonton.touch-layout.v2";
static NSString *TTPadLayoutKey(NSString *titleID) {
    return [TTPadLayoutPreference stringByAppendingFormat:@".%@", titleID.lowercaseString];
}
static NSString *TTReadTouchLayout(NSString *titleID) {
    if (titleID.length != 16) return nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *value = [defaults stringForKey:TTPadLayoutKey(titleID)];
    // The prior global layout was the player's Need for Speed layout. Keep
    // that customization there without inheriting it in any other title.
    if (!value && [titleID caseInsensitiveCompare:@"010029B0118E8000"] == NSOrderedSame)
        value = [defaults stringForKey:TTPadLayoutPreference];
    return value;
}''',1)
 s=s.replace('static void TTApplyTouchLayout(void) {\n    NSString *value=[NSUserDefaults.standardUserDefaults stringForKey:TTPadLayoutPreference];','static void TTApplyTouchLayout(NSString *titleID) {\n    NSString *value=TTReadTouchLayout(titleID);')
 s=s.replace('    if(value.length && dm_pad_layout_parse(value.UTF8String,&parsed))setenv("DM_TOUCH_LAYOUT",value.UTF8String,1);','    if(value.length && dm_pad_layout_parse(value.UTF8String,&parsed) && dm_pad_layout_count(&parsed))setenv("DM_TOUCH_LAYOUT",value.UTF8String,1);\n    else unsetenv("DM_TOUCH_LAYOUT");',1)
 s=s.replace('@interface TTPadLayoutEditor : UIViewController\n@end','@interface TTPadLayoutEditor : UIViewController\n- (instancetype)initWithTitleID:(NSString *)titleID;\n@end')
 s=s.replace('    DmPadLayout _layout;','    NSString *_titleID;\n    DmPadLayout _layout;',1)
 p='- (void)viewDidLoad {'
 s=s.replace(p,'''- (instancetype)initWithTitleID:(NSString *)titleID {
    if (titleID.length != 16) return nil;
    if ((self = [super initWithNibName:nil bundle:nil])) _titleID = [titleID copy];
    return self;
}
'''+p,1)
 s=s.replace('[NSUserDefaults.standardUserDefaults stringForKey:TTPadLayoutPreference].UTF8String','TTReadTouchLayout(_titleID).UTF8String')
 s=s.replace('forKey:TTPadLayoutPreference];','forKey:TTPadLayoutKey(_titleID)];')
 assert 'TTReadTouchLayout(_titleID)' in s and 'forKey:TTPadLayoutKey(_titleID)' in s
 return s
def main(s):
 s=s.replace('TTApplyTouchLayout();','TTApplyTouchLayout(titleID);',1)
 s=s.replace('    return 3;\n#else\n    return 2;\n#endif\n}', '    return 2;\n#else\n    return 1;\n#endif\n}',1)
 s=s.replace('indexPath.row==0?@"手柄按键与实时测试":indexPath.row==1?@"虚拟手柄布局":@"存档同步"','indexPath.row==0?@"手柄按键与实时测试":@"存档同步"')
 s=s.replace('if(indexPath.row==2){[self.navigationController pushViewController:[TTCloudSavesView new]','if(indexPath.row==1){[self.navigationController pushViewController:[TTCloudSavesView new]',1)
 s=s.replace('indexPath.row==0?TTControllerSettings(nil):[TTPadLayoutEditor new]','TTControllerSettings(nil)',1)
 s=s.replace('self.titleID.length!=16||librarySetting(self.titleID,@"DM_PAD_MAP")?1:2','self.titleID.length!=16?1:2',1)
 s=s.replace('section==1?1:self.specs.count','section==1?(librarySetting(self.titleID,@"DM_PAD_MAP")?1:2):self.specs.count',1)
 s=s.replace('if(section==1)return @"未单独修改的按键继承全局映射。";','if(section==1)return @"虚拟布局只影响这款游戏；没改过的游戏使用自己的默认布局。";',1)
 s=s.replace('cell.textLabel.text=@"本游戏手柄按键与实时测试";','cell.textLabel.text=indexPath.row==0?@"本游戏虚拟手柄布局":@"本游戏手柄按键与实时测试";',1)
 s=s.replace('[self.navigationController pushViewController:TTControllerSettings(self.titleID) animated:YES];return;}','[self.navigationController pushViewController:indexPath.row==0?[[TTPadLayoutEditor alloc] initWithTitleID:self.titleID]:TTControllerSettings(self.titleID) animated:YES];return;}',1)
 assert s.count('initWithTitleID:self.titleID')==1 and s.count('TTApplyTouchLayout(titleID)')==1
 return s
def pad(s):
 k='static NSString *const k_layout_key = @"DmPadLayout";'
 assert k in s
 end=s.index('\n',s.index(k))
 s=s[:end]+'''
static NSString *dm_layout_preference_key(void) {
#ifdef DM_LIBRARY_HOST
    const char *title = getenv("DM_LIBRARY_GAME_ID");
    if (title && *title) return [k_layout_key stringByAppendingFormat:@".%s", title];
#endif
    return k_layout_key;
}
'''+s[end:]
 s=s.replace('objectForKey:k_layout_key','objectForKey:dm_layout_preference_key()')
 s=s.replace('forKey:k_layout_key','forKey:dm_layout_preference_key()')
 return s
modify('dm/ios/LibraryApp/Sources/TouchLayoutEditor.h',edit)
modify('dm/ios/LibraryApp/Sources/main.m',main)
modify('dm/ios/Sources/DmGamepad.m',pad)
