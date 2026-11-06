#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// Run only inside the library app's own Documents directory. The device
// service can deliver verified chunks without acquiring write access to the
// app's output file; the app then imports them with its normal sandbox rights.
// This handles data only. Executable frameworks are never imported here.
static NSString *const TTImportStorageReason=@"空间不足，分块已保留。";
static uint64_t TTImportStorageFree(NSString *documents) {
    return [[NSFileManager.defaultManager attributesOfFileSystemForPath:documents error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}
static uint64_t TTImportRequiredFree(uint64_t total) {return total+(256ull<<20);}
static void TTImportOutOfSpace(uint64_t total) {
    @throw [NSException exceptionWithName:@"TonTonImportSpace" reason:TTImportStorageReason
        userInfo:@{@"required_free_bytes":@(TTImportRequiredFree(total))}];
}
// Only recover proven capacity failures. Checksum and destination conflicts
// remain terminal, and their receipts are retained for review.
static BOOL TTImportCapacityReceipt(NSString *receiptPath) {
    NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:receiptPath error:nil];
    if(![a[NSFileType] isEqual:NSFileTypeRegular]||[a[NSFileSize] unsignedLongLongValue]>=(8<<20))return NO;
    NSData *data=[NSData dataWithContentsOfFile:receiptPath];
    if(!data)return NO;
    id receipt=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![receipt isKindOfClass:NSDictionary.class]||![receipt[@"status"] isEqual:@"failed"])return NO;
    id code=receipt[@"code"];
    return [code isEqual:@"insufficient_storage"]||(!code&&[receipt[@"reason"] isEqual:TTImportStorageReason]);
}
static BOOL TTImportCapacityRestored(NSString *documents,id manifest) {
    if(![manifest isKindOfClass:NSDictionary.class]||![manifest[@"bytes"] isKindOfClass:NSNumber.class])return NO;
    uint64_t total=[manifest[@"bytes"] unsignedLongLongValue];
    return total>0&&total<(2ull<<40)&&TTImportStorageFree(documents)>TTImportRequiredFree(total);
}
static BOOL TTImportMatch(NSString *text, NSString *pattern) {
    return [text isKindOfClass:NSString.class] &&
        [text rangeOfString:pattern options:NSRegularExpressionSearch].length==text.length && text.length;
}
static NSString *TTImportDigest(CC_SHA256_CTX *context) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(bytes,context);
    NSMutableString *hex=[NSMutableString new];
    for(unsigned i=0;i<sizeof(bytes);i++)[hex appendFormat:@"%02x",bytes[i]];
    return hex;
}
static BOOL TTImportRegular(NSString *path) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileType] isEqual:NSFileTypeRegular];
}
static void TTImportRequire(BOOL condition,NSString *reason) {
    if(!condition)@throw [NSException exceptionWithName:@"TonTonImport" reason:reason userInfo:nil];
}
static void TTImportDirectory(NSString *path) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *attributes=[fm attributesOfItemAtPath:path error:nil];
    if(attributes){TTImportRequire([attributes[NSFileType] isEqual:NSFileTypeDirectory],@"导入路径包含链接或非目录项目。");return;}
    NSError *error=nil;
    TTImportRequire([fm createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&error],error.localizedDescription);
}
static NSString *TTImportHashFile(NSString *path) {
    TTImportRequire(TTImportRegular(path),@"资源文件不存在或是链接。");
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    TTImportRequire(fd>=0,@"无法读取资源文件。");
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);uint8_t buffer[65536];ssize_t n;
    while((n=read(fd,buffer,sizeof(buffer)))>0)CC_SHA256_Update(&hash,buffer,(CC_LONG)n);
    close(fd);TTImportRequire(n==0,@"读取资源文件失败。");return TTImportDigest(&hash);
}
static NSDictionary *TTImportOne(NSString *documents,NSString *inbox,NSDictionary *manifest) {
    NSFileManager *fm=NSFileManager.defaultManager;
    TTImportRequire([manifest isKindOfClass:NSDictionary.class]&&[manifest[@"schema"] isEqual:@1],@"导入清单格式不支持。");
    NSString *title=manifest[@"game_id"],*name=manifest[@"resource_name"],*sha=manifest[@"sha256"];
    TTImportRequire(TTImportMatch(title,@"^[a-z0-9][a-z0-9_-]{0,63}$"),@"卡带标识无效。");
    // An archive or a RomFS image is data. No nested output paths or code names.
    TTImportRequire(TTImportMatch(name,@"^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,95}\\.(zip|img)$"),@"资源名称必须是 ZIP 或 RomFS 镜像。");
    TTImportRequire(TTImportMatch(sha,@"^[0-9a-f]{64}$"),@"资源校验值无效。");
    TTImportRequire([manifest[@"bytes"] isKindOfClass:NSNumber.class],@"缺少资源大小。");
    uint64_t total=[manifest[@"bytes"] unsignedLongLongValue];
    TTImportRequire(total>0&&total<(2ull<<40),@"资源大小无效。");
    NSArray *chunks=manifest[@"chunks"];
    TTImportRequire([chunks isKindOfClass:NSArray.class]&&chunks.count&&chunks.count<=16384,@"资源分块清单无效。");
    NSMutableSet *names=[NSMutableSet new];uint64_t sum=0;
    for(id item in chunks){
        TTImportRequire([item isKindOfClass:NSDictionary.class],@"资源分块条目无效。");
        NSString *file=item[@"file"];
        TTImportRequire(TTImportMatch(file,@"^[0-9]{4,5}-[0-9a-f]{64}\\.part$")&&![names containsObject:file],@"分块名称重复或无效。");
        TTImportRequire(TTImportMatch(item[@"sha256"],@"^[0-9a-f]{64}$")&&[item[@"bytes"] isKindOfClass:NSNumber.class],@"缺少分块校验数据。");
        uint64_t bytes=[item[@"bytes"] unsignedLongLongValue];
        TTImportRequire(bytes>0&&bytes<=(1ull<<30)&&sum<=total&&bytes<=total-sum,@"分块大小超出资源范围。");
        sum+=bytes;[names addObject:file];
    }
    TTImportRequire(sum==total,@"分块大小与完整资源不符。");
    NSString *games=[documents stringByAppendingPathComponent:@"Games"];TTImportDirectory(games);
    NSString *slot=[games stringByAppendingPathComponent:title];TTImportDirectory(slot);
    NSString *resources=[slot stringByAppendingPathComponent:@"Resources"];TTImportDirectory(resources);
    NSString *destination=[resources stringByAppendingPathComponent:name];
    NSDictionary *existing=[fm attributesOfItemAtPath:destination error:nil];
    // A failed device copy can leave an empty RomFS placeholder. Replacing it
    // requires an explicit data-only task; nonempty files and links stay intact.
    BOOL replaceEmpty=existing && [name isEqual:@"romfs.img"] &&
        [manifest[@"replace_empty_placeholder"] isEqual:@YES] &&
        [existing[NSFileType] isEqual:NSFileTypeRegular] &&
        [existing[NSFileSize] unsignedLongLongValue]==0;
    NSString *retainedEmpty=nil;
    if(existing && !replaceEmpty){
        TTImportRequire([[fm attributesOfItemAtPath:destination error:nil][NSFileSize] unsignedLongLongValue]==total&&
                        [TTImportHashFile(destination) isEqual:sha],@"已有资源与导入清单不同，已保留原文件。");
    }else{
        if(TTImportStorageFree(documents)<=TTImportRequiredFree(total))TTImportOutOfSpace(total);
        NSString *temporary=[inbox stringByAppendingPathComponent:[@".assembling-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        int output=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if(output<0&&errno==ENOSPC)TTImportOutOfSpace(total);
        TTImportRequire(output>=0,@"无法在应用内创建临时资源。");
        BOOL complete=NO;
        @try{
            CC_SHA256_CTX whole;CC_SHA256_Init(&whole);
            for(NSDictionary *chunk in chunks){
                NSString *path=[inbox stringByAppendingPathComponent:chunk[@"file"]];
                TTImportRequire(TTImportRegular(path),@"分块缺失或包含链接。");
                uint64_t expected=[chunk[@"bytes"] unsignedLongLongValue];
                TTImportRequire([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]==expected,@"分块大小已改变。");
                int input=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);TTImportRequire(input>=0,@"分块无法读取。");
                CC_SHA256_CTX hash;CC_SHA256_Init(&hash);uint64_t count=0;ssize_t n;uint8_t bytes[65536];
                @try{
                    while((n=read(input,bytes,sizeof(bytes)))>0){
                        count+=(uint64_t)n;TTImportRequire(count<=expected,@"分块在导入时改变。");
                        CC_SHA256_Update(&hash,bytes,(CC_LONG)n);CC_SHA256_Update(&whole,bytes,(CC_LONG)n);
                        ssize_t at=0;while(at<n){ssize_t wrote=write(output,bytes+at,(size_t)(n-at));
                            if(wrote<0&&errno==ENOSPC)TTImportOutOfSpace(total);
                            TTImportRequire(wrote>0,@"资源写入失败，原资源和分块已保留。");at+=wrote;}
                    }
                    TTImportRequire(n==0&&count==expected&&[TTImportDigest(&hash) isEqual:chunk[@"sha256"]],@"分块校验失败，原资源已保留。");
                }@finally{close(input);}
            }
            TTImportRequire([TTImportDigest(&whole) isEqual:sha],@"完整资源校验失败。");
            int synced=fsync(output);
            if(synced<0&&errno==ENOSPC)TTImportOutOfSpace(total);
            TTImportRequire(synced==0,@"资源写入尚未完成。");
            NSError *error=nil;
            if(replaceEmpty){
                NSDictionary *now=[fm attributesOfItemAtPath:destination error:nil];
                TTImportRequire([now[NSFileType] isEqual:NSFileTypeRegular] &&
                    [now[NSFileSize] unsignedLongLongValue]==0 &&
                    [now[NSFileSystemNumber] isEqual:existing[NSFileSystemNumber]] &&
                    [now[NSFileSystemFileNumber] isEqual:existing[NSFileSystemFileNumber]],
                    @"空资源已改变，未替换原文件。");
                retainedEmpty=[resources stringByAppendingPathComponent:
                    [@"romfs.img.empty-before-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                TTImportRequire([fm moveItemAtPath:destination toPath:retainedEmpty error:&error],error.localizedDescription);
            }
            if(![fm moveItemAtPath:temporary toPath:destination error:&error]){
                NSString *reason=error.localizedDescription;
                if(retainedEmpty && ![fm attributesOfItemAtPath:destination error:nil])
                    [fm moveItemAtPath:retainedEmpty toPath:destination error:nil];
                TTImportRequire(NO,reason);
            }
            complete=YES;
        }@finally{
            close(output);
            // Only this invocation's newly created temporary file is removed.
            // Inputs, existing destinations and saves are never deleted.
            if(!complete)[fm removeItemAtPath:temporary error:nil];
        }
    }
    TTImportDirectory([slot stringByAppendingPathComponent:@"UserData"]);
    NSString *cardPath=[slot stringByAppendingPathComponent:@"GameCard.json"];
    if(![fm attributesOfItemAtPath:cardPath error:nil]){
        NSMutableDictionary *card=[@{@"schema":@1,@"title_id":title,@"name":title,@"version":@"",@"size":@""} mutableCopy];
        if([manifest[@"card"] isKindOfClass:NSDictionary.class])for(NSString *key in @[@"name",@"version",@"size"])
            if([manifest[@"card"][key] isKindOfClass:NSString.class])card[key]=manifest[@"card"][key];
        NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:card options:0 error:&error];
        TTImportRequire(data&&[data writeToFile:cardPath options:NSDataWritingAtomic error:&error],error.localizedDescription);
    }
    NSDictionary *attributes=[fm attributesOfItemAtPath:destination error:nil];
    return @{@"status":@"imported",@"resource":name,@"game_id":title,@"bytes":@(total),@"sha256":sha,
             @"retained_empty_placeholder":retainedEmpty.lastPathComponent?:@"",
             @"mtime":@([attributes[NSFileModificationDate] timeIntervalSince1970])};
}
// Delivery services may read a destination but be unable to create its task
// file. Ship data-only task metadata with the signed app instead; the app
// creates it using its own sandbox rights, without changing system permissions.
static NSArray *TonTonSeedResourceImportTasks(NSString *documents,id tasks) {
    NSMutableArray *results=[NSMutableArray new];NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=[documents stringByAppendingPathComponent:@"TonTonIncoming"];
    if(![[fm attributesOfItemAtPath:root error:nil][NSFileType] isEqual:NSFileTypeDirectory])return results;
    if(![tasks isKindOfClass:NSArray.class]||[tasks count]>1024)return @[@{@"status":@"failed",@"reason":@"内置导入任务格式无效。"}];
    for(id task in tasks){
        NSString *temporary=nil;BOOL temporaryOwned=NO;
        @try{
            TTImportRequire([task isKindOfClass:NSDictionary.class],@"内置导入任务无效。");
            NSString *name=task[@"inbox"];
            TTImportRequire(TTImportMatch(name,@"^[a-z0-9][a-z0-9_-]{0,95}$"),@"内置导入目录无效。");
            NSString *folder=[root stringByAppendingPathComponent:name];
            NSDictionary *attributes=[fm attributesOfItemAtPath:folder error:nil];
            if(!attributes)continue; // A transfer for another device is absent.
            TTImportRequire([attributes[NSFileType] isEqual:NSFileTypeDirectory],@"内置导入目录包含链接。");
            NSString *path=[folder stringByAppendingPathComponent:@"ImportTask.json"];
            if([fm attributesOfItemAtPath:path error:nil])continue; // Never replace an existing task.
            TTImportRequire([task[@"manifest"] isKindOfClass:NSDictionary.class],@"缺少内置导入清单。");
            NSError *error=nil;
            NSData *data=[NSJSONSerialization dataWithJSONObject:task[@"manifest"] options:0 error:&error];
            TTImportRequire(data&&data.length<(8<<20),@"内置导入清单无效或过大。");
            temporary=[folder stringByAppendingPathComponent:[@".task-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            TTImportRequire([data writeToFile:temporary options:NSDataWritingWithoutOverwriting error:&error],error.localizedDescription);
            temporaryOwned=YES;
            TTImportRequire([fm moveItemAtPath:temporary toPath:path error:&error],error.localizedDescription);
        }@catch(NSException *error){[results addObject:@{@"status":@"failed",@"reason":error.reason?:@"导入清单创建失败"}];}
        @finally{if(temporaryOwned)[fm removeItemAtPath:temporary error:nil];}
    }return results;
}
static NSArray *TonTonImportPendingResources(NSString *documents) {
    static NSObject *guard;static dispatch_once_t once;dispatch_once(&once,^{guard=[NSObject new];});
    @synchronized(guard){
        NSMutableArray *results=[NSMutableArray new];NSFileManager *fm=NSFileManager.defaultManager;
        NSString *root=[documents stringByAppendingPathComponent:@"TonTonIncoming"];
        if(![[fm attributesOfItemAtPath:root error:nil][NSFileType] isEqual:NSFileTypeDirectory])return results;
        NSString *bundled=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Runtimes/ResourceImports.json"];
        if(TTImportRegular(bundled)&&[[fm attributesOfItemAtPath:bundled error:nil][NSFileSize] unsignedLongLongValue]<(8<<20)){
            id tasks=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:bundled] options:0 error:nil];
            [results addObjectsFromArray:TonTonSeedResourceImportTasks(documents,tasks)];
        }
        for(NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil]){
            NSString *folder=[root stringByAppendingPathComponent:entry];
            if(![[fm attributesOfItemAtPath:folder error:nil][NSFileType] isEqual:NSFileTypeDirectory])continue;
            NSString *manifestPath=[folder stringByAppendingPathComponent:@"ImportTask.json"];
            if(!TTImportRegular(manifestPath))continue;
            NSString *receiptPath=[folder stringByAppendingPathComponent:@"ImportResult.json"];
            BOOL hasReceipt=[fm attributesOfItemAtPath:receiptPath error:nil]!=nil;
            if(hasReceipt&&!TTImportCapacityReceipt(receiptPath))continue;
            NSDictionary *result;
            @try{
                TTImportRequire([[fm attributesOfItemAtPath:manifestPath error:nil][NSFileSize] unsignedLongLongValue]<(8<<20),@"导入清单过大。");
                NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifestPath] options:0 error:nil];
                if(hasReceipt&&!TTImportCapacityRestored(documents,manifest))continue;
                hasReceipt=NO;
                result=TTImportOne(documents,folder,manifest);
            }@catch(NSException *error){
                if(hasReceipt)continue; // Preserve the existing receipt if its manifest cannot be read.
                if([error.name isEqual:@"TonTonImportSpace"])
                    result=@{@"status":@"failed",@"code":@"insufficient_storage",@"reason":TTImportStorageReason,
                        @"required_free_bytes":error.userInfo[@"required_free_bytes"]};
                else result=@{@"status":@"failed",@"reason":error.reason?:@"导入失败"};
            }
            [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:receiptPath options:NSDataWritingAtomic error:nil];
            [results addObject:result];
        }return results;
    }
}
