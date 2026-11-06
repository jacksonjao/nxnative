// Private CloudKit transport for the portable, validated save_sync bundle.
#import <CloudKit/CloudKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include "save_sync.h"

static NSString *container_name(void) {
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMCloudSaveContainer"];
    // The Mac game's helper executable inherits this from its signed launcher.
    if (![name isKindOfClass:NSString.class] || !name.length) {
        const char *v = getenv("DM_CLOUDKIT_CONTAINER");
        if (v) name = [NSString stringWithUTF8String:v];
    }
    return [name isKindOfClass:NSString.class] && [name hasPrefix:@"iCloud."] ? name : nil;
}

int front_cloudkit_configured(void) {
    @autoreleasepool { return container_name() != nil; }
}

static NSString *account_scope(CKContainer *container) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString *account;
    [container fetchUserRecordIDWithCompletionHandler:^(CKRecordID *recordID, NSError *error) {
        if (!error && recordID.recordName.length) {
            NSString *identity = [NSString stringWithFormat:@"%@:%@", container.containerIdentifier, recordID.recordName];
            NSData *data = [identity dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
            char hex[33] = {0};
            for (unsigned i = 0; i < 16; ++i) snprintf(hex + 2*i, 3, "%02x", digest[i]);
            account = @(hex);
        }
        dispatch_semaphore_signal(done);
    }];
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC)) == 0 ? account : nil;
}

int front_cloudkit_account(char scope[33]) {
    @autoreleasepool {
        NSString *name = container_name();
        NSString *account = name ? account_scope([CKContainer containerWithIdentifier:name]) : nil;
        if (!account) return 0;
        memcpy(scope, account.UTF8String, 33);
        return 1;
    }
}

static CKDatabase *database_and_id(const char *path, CKRecordID **recordID) {
    NSString *name = container_name();
    NSArray<NSString *> *components = [@(path) componentsSeparatedByString:@"/"];
    if (!name || components.count != 4 || ![components[0] isEqualToString:@"cksave"] ||
        components[1].length != 32 || components[2].length != 16 ||
        ![components[3] isEqualToString:@"save.dmsync"]) return nil;
    CKContainer *container = [CKContainer containerWithIdentifier:name];
    if (![account_scope(container) isEqualToString:components[1]]) return nil;
    // The account scope is also part of the private record key. An account
    // switch cannot write the same record in a different account mid-request.
    NSString *key = [NSString stringWithFormat:@"save1-%@-%@", components[1], components[2]];
    *recordID = [[CKRecordID alloc] initWithRecordName:key];
    return container.privateCloudDatabase;
}

static void configure(CKOperation *op, NSTimeInterval timeout) {
    op.configuration.qualityOfService = NSQualityOfServiceUserInitiated;
    op.configuration.timeoutIntervalForRequest = timeout;
    op.configuration.timeoutIntervalForResource = timeout;
}

static int fetch(CKDatabase *db, CKRecordID *rid, NSArray<NSString *> *keys, CKRecord **output) {
    CKFetchRecordsOperation *op = [[CKFetchRecordsOperation alloc] initWithRecordIDs:@[rid]];
    op.desiredKeys = keys;
    configure(op, 5);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block CKRecord *found;
    __block NSError *failure;
    // The Swift Result properties wrap these Objective-C completion blocks.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    op.perRecordCompletionBlock = ^(CKRecord *record, CKRecordID *recordID, NSError *error) {
        (void)recordID;
        found = record; failure = error;
    };
    op.fetchRecordsCompletionBlock = ^(NSDictionary<CKRecordID *, CKRecord *> *records, NSError *error) {
        (void)records;
        if (!found && !failure) failure = error;
        dispatch_semaphore_signal(done);
    };
    #pragma clang diagnostic pop
    [db addOperation:op];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 6*NSEC_PER_SEC))) {
        [op cancel]; return -1;
    }
    if (found) { *output = found; return 1; }
    return [failure.domain isEqualToString:CKErrorDomain] && failure.code == CKErrorUnknownItem ? 0 : -1;
}

int front_cloudkit_fetch(const char *path, const char *local) {
    @autoreleasepool {
        CKRecordID *rid = nil;
        CKDatabase *db = database_and_id(path, &rid);
        if (!db) return -1;
        CKRecord *record = nil;
        int got = fetch(db, rid, @[@"digest", @"bundle"], &record);
        if (got != 1) return got;
        CKAsset *asset = record[@"bundle"];
        NSString *digest = record[@"digest"];
        if (![asset isKindOfClass:CKAsset.class] || !asset.fileURL.isFileURL ||
            ![digest isKindOfClass:NSString.class]) return -1;
        ss_meta meta;
        if (ss_read(asset.fileURL.fileSystemRepresentation, NULL, &meta) || ![digest isEqualToString:@(meta.hash)]) return -1;
        // The caller reserves a unique temporary path before starting fetch.
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *dst = [NSURL fileURLWithPath:@(local)];
        if (![fm removeItemAtURL:dst error:NULL]) return -1;
        return [fm copyItemAtURL:asset.fileURL toURL:dst error:NULL] ? 1 : -1;
    }
}

int front_cloudkit_store(const char *local, const char *path, const char *expected) {
    @autoreleasepool {
        CKRecordID *rid = nil;
        CKDatabase *db = database_and_id(path, &rid);
        if (!db) return 0;
        CKRecord *record = nil;
        int got = fetch(db, rid, @[@"digest"], &record);
        if (got < 0 || (got == 0 && *expected) ||
            (got == 1 && (!*expected || ![(id)record[@"digest"] isEqual:@(expected)]))) return 0;
        ss_meta meta;
        if (ss_read(local, NULL, &meta) || !meta.files) return 0;
        if (!record) record = [[CKRecord alloc] initWithRecordType:@"TonTonSaveV1" recordID:rid];
        record[@"digest"] = @(meta.hash);
        record[@"bundle"] = [[CKAsset alloc] initWithFileURL:[NSURL fileURLWithPath:@(local)]];
        CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];
        op.savePolicy = CKRecordSaveIfServerRecordUnchanged;
        configure(op, 10);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL saved = NO;
        op.perRecordSaveBlock = ^(CKRecordID *key, CKRecord *savedRecord, NSError *error) {
            (void)key;
            saved = savedRecord != nil && error == nil;
        };
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        op.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> *savedRecords, NSArray<CKRecordID *> *deleted, NSError *error) {
            (void)savedRecords; (void)deleted;
            if (error) saved = NO;
            dispatch_semaphore_signal(done);
        };
        #pragma clang diagnostic pop
        [db addOperation:op];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 11*NSEC_PER_SEC))) {
            [op cancel]; return 0;
        }
        return saved;
    }
}
