#import "CodePush.h"
#if __has_include(<SSZipArchive/SSZipArchive.h>)
#import <SSZipArchive/SSZipArchive.h>
#else
#import "SSZipArchive.h"
#endif

@implementation CodePushPackage

#pragma mark - Private constants

static NSString *const DiffManifestFileName = @"hotcodepush.json";
static NSString *const DownloadFileName = @"download.zip";
static NSString *const RelativeBundlePathKey = @"bundlePath";
static NSString *const StatusFile = @"codepush.json";
static NSString *const UpdateBundleFileName = @"app.jsbundle";
static NSString *const UpdateMetadataFileName = @"app.json";
static NSString *const UnzippedFolderName = @"unzipped";

#pragma mark - Public methods

+ (void)clearUpdates
{
    [[NSFileManager defaultManager] removeItemAtPath:[self getCodePushPath] error:nil];
}

+ (void)downloadAndReplaceCurrentBundle:(NSString *)remoteBundleUrl
{
    NSURL *urlRequest = [NSURL URLWithString:remoteBundleUrl];
    NSError *error = nil;
    NSString *downloadedBundle = [NSString stringWithContentsOfURL:urlRequest
                                                          encoding:NSUTF8StringEncoding
                                                             error:&error];
    
    if (error) {
        CPLog(@"Error downloading from URL %@", remoteBundleUrl);
    } else {
        NSString *currentPackageBundlePath = [self getCurrentPackageBundlePath:&error];
        [downloadedBundle writeToFile:currentPackageBundlePath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:&error];
    }
}

+ (void)downloadPackage:(NSDictionary *)updatePackage
 expectedBundleFileName:(NSString *)expectedBundleFileName
              publicKey:(NSString *)publicKey
         operationQueue:(dispatch_queue_t)operationQueue
       progressCallback:(void (^)(long long, long long))progressCallback
           doneCallback:(void (^)())doneCallback
           failCallback:(void (^)(NSError *err))failCallback
{
    NSString *newUpdateHash = updatePackage[@"packageHash"];
    NSString *newUpdateFolderPath = [self getPackageFolderPath:newUpdateHash];
    NSString *newUpdateMetadataPath = [newUpdateFolderPath stringByAppendingPathComponent:UpdateMetadataFileName];
    NSError *error;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:newUpdateFolderPath]) {
        // This removes any stale data in newUpdateFolderPath that could have been left
        // uncleared due to a crash or error during the download or install process.
        [[NSFileManager defaultManager] removeItemAtPath:newUpdateFolderPath
                                                   error:&error];
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:[self getCodePushPath]]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[self getCodePushPath]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
                                                        
        // Ensure that none of the CodePush updates we store on disk are
        // ever included in the end users iTunes and/or iCloud backups
        NSURL *codePushURL = [NSURL fileURLWithPath:[self getCodePushPath]];
        [codePushURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    
    if (error) {
        return failCallback(error);
    }

    // Check for multi-patch update
    NSArray *patches = updatePackage[@"patches"];
    if (patches != nil && [patches count] > 0) {
        CPLog(@"Multi-patch update detected: %lu patches", (unsigned long)[patches count]);
        [self downloadAndApplyMultiplePatches:patches
                          finalUpdateFolderPath:newUpdateFolderPath
                        finalUpdateMetadataPath:newUpdateMetadataPath
                         expectedBundleFileName:expectedBundleFileName
                                      publicKey:publicKey
                                 operationQueue:operationQueue
                               progressCallback:progressCallback
                                   doneCallback:doneCallback
                                   failCallback:failCallback
                                  updatePackage:updatePackage];
        return;
    }
    
    // Single patch update (existing logic)
    CPLog(@"Single patch update");
    
    NSString *downloadFilePath = [self getDownloadFilePath];
    NSString *bundleFilePath = [newUpdateFolderPath stringByAppendingPathComponent:UpdateBundleFileName];
    
    CodePushDownloadHandler *downloadHandler = [[CodePushDownloadHandler alloc]
                                                init:downloadFilePath
                                                operationQueue:operationQueue
                                                progressCallback:progressCallback
                                                doneCallback:^(BOOL isZip) {
                                                    NSError *error = nil;
                                                    NSString * unzippedFolderPath = [CodePushPackage getUnzippedFolderPath];
                                                    NSMutableDictionary * mutableUpdatePackage = [updatePackage mutableCopy];
                                                    if (isZip) {
                                                        if ([[NSFileManager defaultManager] fileExistsAtPath:unzippedFolderPath]) {
                                                            // This removes any unzipped download data that could have been left
                                                            // uncleared due to a crash or error during the download process.
                                                            [[NSFileManager defaultManager] removeItemAtPath:unzippedFolderPath
                                                                                                       error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                        }
                                                        
                                                        NSError *nonFailingError = nil;
                                                        [SSZipArchive unzipFileAtPath:downloadFilePath
                                                                        toDestination:unzippedFolderPath];
                                                        [[NSFileManager defaultManager] removeItemAtPath:downloadFilePath
                                                                                                   error:&nonFailingError];
                                                        if (nonFailingError) {
                                                            CPLog(@"Error deleting downloaded file: %@", nonFailingError);
                                                            nonFailingError = nil;
                                                        }
                                                        
                                                        NSString *diffManifestFilePath = [unzippedFolderPath stringByAppendingPathComponent:DiffManifestFileName];
                                                        BOOL isDiffUpdate = [[NSFileManager defaultManager] fileExistsAtPath:diffManifestFilePath];
                                                        
                                                        if (isDiffUpdate) {
                                                            // Copy the current package to the new package.
                                                            NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                            
                                                            if (currentPackageFolderPath == nil) {
                                                                // Currently running the binary version, copy files from the bundled resources
                                                                NSString *newUpdateCodePushPath = [newUpdateFolderPath stringByAppendingPathComponent:[CodePushUpdateUtils manifestFolderPrefix]];
                                                                [[NSFileManager defaultManager] createDirectoryAtPath:newUpdateCodePushPath
                                                                                          withIntermediateDirectories:YES
                                                                                                           attributes:nil
                                                                                                                error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                                
                                                                [[NSFileManager defaultManager] copyItemAtPath:[CodePush bundleAssetsPath]
                                                                                                        toPath:[newUpdateCodePushPath stringByAppendingPathComponent:[CodePushUpdateUtils assetsFolderName]]
                                                                                                         error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                                
                                                                [[NSFileManager defaultManager] copyItemAtPath:[[CodePush binaryBundleURL] path]
                                                                                                        toPath:[newUpdateCodePushPath stringByAppendingPathComponent:[[CodePush binaryBundleURL] lastPathComponent]]
                                                                                                         error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                            } else {
                                                                [[NSFileManager defaultManager] copyItemAtPath:currentPackageFolderPath
                                                                                                        toPath:newUpdateFolderPath
                                                                                                         error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                            }
                                                            
                                                            // Delete files mentioned in the manifest.
                                                            NSString *manifestContent = [NSString stringWithContentsOfFile:diffManifestFilePath
                                                                                                                  encoding:NSUTF8StringEncoding
                                                                                                                     error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                            
                                                            NSData *data = [manifestContent dataUsingEncoding:NSUTF8StringEncoding];
                                                            NSDictionary *manifestJSON = [NSJSONSerialization JSONObjectWithData:data
                                                                                                                         options:kNilOptions
                                                                                                                           error:&error];
                                                            NSArray *deletedFiles = manifestJSON[@"deletedFiles"];
                                                            for (NSString *deletedFileName in deletedFiles) {
                                                                NSString *absoluteDeletedFilePath = [newUpdateFolderPath stringByAppendingPathComponent:deletedFileName];
                                                                if ([[NSFileManager defaultManager] fileExistsAtPath:absoluteDeletedFilePath]) {
                                                                    [[NSFileManager defaultManager] removeItemAtPath:absoluteDeletedFilePath
                                                                                                               error:&error];
                                                                    if (error) {
                                                                        failCallback(error);
                                                                        return;
                                                                    }
                                                                }
                                                            }
                                                            
                                                            [[NSFileManager defaultManager] removeItemAtPath:diffManifestFilePath
                                                                                                       error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                        }
                                                        
                                                        [CodePushUpdateUtils copyEntriesInFolder:unzippedFolderPath
                                                                                      destFolder:newUpdateFolderPath
                                                                                           error:&error];
                                                        if (error) {
                                                            failCallback(error);
                                                            return;
                                                        }
                                                        
                                                        [[NSFileManager defaultManager] removeItemAtPath:unzippedFolderPath
                                                                                                   error:&nonFailingError];
                                                        if (nonFailingError) {
                                                            CPLog(@"Error deleting downloaded file: %@", nonFailingError);
                                                            nonFailingError = nil;
                                                        }
                                                        
                                                        NSString *relativeBundlePath = [CodePushUpdateUtils findMainBundleInFolder:newUpdateFolderPath
                                                                                                                  expectedFileName:expectedBundleFileName
                                                                                                                             error:&error];
                                                        
                                                        if (error) {
                                                            failCallback(error);
                                                            return;
                                                        }
                                                        
                                                        if (relativeBundlePath) {
                                                            [mutableUpdatePackage setValue:relativeBundlePath forKey:RelativeBundlePathKey];
                                                        } else {
                                                            NSString *errorMessage = [NSString stringWithFormat:@"Update is invalid - A JS bundle file named \"%@\" could not be found within the downloaded contents. Please ensure that your app is syncing with the correct deployment and that you are releasing your CodePush updates using the exact same JS bundle file name that was shipped with your app's binary.", expectedBundleFileName];
                                                            
                                                            error = [CodePushErrorUtils errorWithMessage:errorMessage];
                                                            
                                                            failCallback(error);
                                                            return;
                                                        }
                                                        
                                                        if ([[NSFileManager defaultManager] fileExistsAtPath:newUpdateMetadataPath]) {
                                                            [[NSFileManager defaultManager] removeItemAtPath:newUpdateMetadataPath
                                                                                                       error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                        }

                                                        CPLog((isDiffUpdate) ? @"Applying diff update." : @"Applying full update.");
                                                        
                                                        BOOL isSignatureVerificationEnabled = (publicKey != nil);
                                                        
                                                        NSString *signatureFilePath = [CodePushUpdateUtils getSignatureFilePath:newUpdateFolderPath];
                                                        BOOL isSignatureAppearedInBundle = [[NSFileManager defaultManager] fileExistsAtPath:signatureFilePath];
                                                        
                                                        if (isSignatureVerificationEnabled) {
                                                            if (isSignatureAppearedInBundle) {
                                                                if (![CodePushUpdateUtils verifyFolderHash:newUpdateFolderPath
                                                                                              expectedHash:newUpdateHash
                                                                                                     error:&error]) {
                                                                    CPLog(@"The update contents failed the data integrity check.");
                                                                    if (!error) {
                                                                        error = [CodePushErrorUtils errorWithMessage:@"The update contents failed the data integrity check."];
                                                                    }
                                                                    
                                                                    failCallback(error);
                                                                    return;
                                                                } else {
                                                                    CPLog(@"The update contents succeeded the data integrity check.");
                                                                }
                                                                BOOL isSignatureValid = [CodePushUpdateUtils verifyUpdateSignatureFor:newUpdateFolderPath
                                                                                                                         expectedHash:newUpdateHash
                                                                                                                        withPublicKey:publicKey
                                                                                                                                error:&error];
                                                                if (!isSignatureValid) {
                                                                    CPLog(@"The update contents failed code signing check.");
                                                                    if (!error) {
                                                                        error = [CodePushErrorUtils errorWithMessage:@"The update contents failed code signing check."];
                                                                    }
                                                                    failCallback(error);
                                                                    return;
                                                                } else {
                                                                    CPLog(@"The update contents succeeded the code signing check.");
                                                                }
                                                            } else {
                                                                error = [CodePushErrorUtils errorWithMessage:
                                                                         @"Error! Public key was provided but there is no JWT signature within app bundle to verify " \
                                                                         "Possible reasons, why that might happen: \n" \
                                                                         "1. You've been released CodePush bundle update using version of CodePush CLI that is not support code signing.\n" \
                                                                         "2. You've been released CodePush bundle update without providing --privateKeyPath option."];
                                                                failCallback(error);
                                                                return;
                                                            }
                                                            
                                                        } else {
                                                            BOOL needToVerifyHash;
                                                            if (isSignatureAppearedInBundle) {
                                                                CPLog(@"Warning! JWT signature exists in codepush update but code integrity check couldn't be performed" \
                                                                      " because there is no public key configured. " \
                                                                      "Please ensure that public key is properly configured within your application.");
                                                                needToVerifyHash = true;
                                                            } else {
                                                                needToVerifyHash = isDiffUpdate;
                                                            }
                                                            if(needToVerifyHash){
                                                                if (![CodePushUpdateUtils verifyFolderHash:newUpdateFolderPath
                                                                                              expectedHash:newUpdateHash
                                                                                                     error:&error]) {
                                                                    CPLog(@"The update contents failed the data integrity check.");
                                                                    if (!error) {
                                                                        error = [CodePushErrorUtils errorWithMessage:@"The update contents failed the data integrity check."];
                                                                    }
                                                                    
                                                                    failCallback(error);
                                                                    return;
                                                                } else {
                                                                    CPLog(@"The update contents succeeded the data integrity check.");
                                                                }
                                                            }
                                                        }
                                                    } else {
                                                        [[NSFileManager defaultManager] createDirectoryAtPath:newUpdateFolderPath
                                                                                  withIntermediateDirectories:YES
                                                                                                   attributes:nil
                                                                                                        error:&error];
                                                        [[NSFileManager defaultManager] moveItemAtPath:downloadFilePath
                                                                                                toPath:bundleFilePath
                                                                                                 error:&error];
                                                        if (error) {
                                                            failCallback(error);
                                                            return;
                                                        }
                                                    }
                                                    
                                                    NSData *updateSerializedData = [NSJSONSerialization dataWithJSONObject:mutableUpdatePackage
                                                                                                                   options:0
                                                                                                                     error:&error];
                                                    NSString *packageJsonString = [[NSString alloc] initWithData:updateSerializedData
                                                                                                        encoding:NSUTF8StringEncoding];
                                                    
                                                    [packageJsonString writeToFile:newUpdateMetadataPath
                                                                        atomically:YES
                                                                          encoding:NSUTF8StringEncoding
                                                                             error:&error];
                                                    if (error) {
                                                        failCallback(error);
                                                    } else {
                                                        doneCallback();
                                                    }
                                                }
                                                
                                                failCallback:failCallback];
    
    [downloadHandler download:updatePackage[@"downloadUrl"]];
}

+ (NSString *)getCodePushPath
{
    NSString* codePushPath = [[CodePush getApplicationSupportDirectory] stringByAppendingPathComponent:@"CodePush"];
    if ([CodePush isUsingTestConfiguration]) {
        codePushPath = [codePushPath stringByAppendingPathComponent:@"TestPackages"];
    }
    
    return codePushPath;
}

+ (NSDictionary *)getCurrentPackage:(NSError **)error
{
    NSString *packageHash = [CodePushPackage getCurrentPackageHash:error];
    if (!packageHash) {
        return nil;
    }

    return [CodePushPackage getPackage:packageHash error:error];
}

+ (NSString *)getCurrentPackageBundlePath:(NSError **)error
{
    NSString *packageFolder = [self getCurrentPackageFolderPath:error];
    
    if (!packageFolder) {
        return nil;
    }
    
    NSDictionary *currentPackage = [self getCurrentPackage:error];
    
    if (!currentPackage) {
        return nil;
    }
    
    NSString *relativeBundlePath = [currentPackage objectForKey:RelativeBundlePathKey];
    if (relativeBundlePath) {
        return [packageFolder stringByAppendingPathComponent:relativeBundlePath];
    } else {
        return [packageFolder stringByAppendingPathComponent:UpdateBundleFileName];
    }
}

+ (NSString *)getCurrentPackageHash:(NSError **)error
{
    NSDictionary *info = [self getCurrentPackageInfo:error];
    if (!info) {
        return nil;
    }
    
    return info[@"currentPackage"];
}

+ (NSString *)getCurrentPackageFolderPath:(NSError **)error
{
    NSDictionary *info = [self getCurrentPackageInfo:error];
    
    if (!info) {
        return nil;
    }
    
    NSString *packageHash = info[@"currentPackage"];
    
    if (!packageHash) {
        return nil;
    }
    
    return [self getPackageFolderPath:packageHash];
}

+ (NSMutableDictionary *)getCurrentPackageInfo:(NSError **)error
{
    NSString *statusFilePath = [self getStatusFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:statusFilePath]) {
        return [NSMutableDictionary dictionary];
    }
    
    NSString *content = [NSString stringWithContentsOfFile:statusFilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:error];
    if (!content) {
        return nil;
    }
    
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:kNilOptions
                                                           error:error];
    if (!json) {
        return nil;
    }
    
    return [json mutableCopy];
}

+ (NSString *)getDownloadFilePath
{
    return [[self getCodePushPath] stringByAppendingPathComponent:DownloadFileName];
}

+ (NSDictionary *)getPackage:(NSString *)packageHash
                       error:(NSError **)error
{
    NSString *updateDirectoryPath = [self getPackageFolderPath:packageHash];
    NSString *updateMetadataFilePath = [updateDirectoryPath stringByAppendingPathComponent:UpdateMetadataFileName];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:updateMetadataFilePath]) {
        return nil;
    }
    
    NSString *updateMetadataString = [NSString stringWithContentsOfFile:updateMetadataFilePath
                                                               encoding:NSUTF8StringEncoding
                                                                  error:error];
    if (!updateMetadataString) {
        return nil;
    }
    
    NSData *updateMetadata = [updateMetadataString dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:updateMetadata
                                           options:kNilOptions
                                             error:error];
}

+ (NSString *)getPackageFolderPath:(NSString *)packageHash
{
    return [[self getCodePushPath] stringByAppendingPathComponent:packageHash];
}

+ (NSDictionary *)getPreviousPackage:(NSError **)error
{
    NSString *packageHash = [self getPreviousPackageHash:error];
    if (!packageHash) {
        return nil;
    }
    
    return [CodePushPackage getPackage:packageHash error:error];
}

+ (NSString *)getPreviousPackageHash:(NSError **)error
{
    NSDictionary *info = [self getCurrentPackageInfo:error];
    if (!info) {
        return nil;
    }
    
    return info[@"previousPackage"];
}

+ (NSString *)getStatusFilePath
{
    return [[self getCodePushPath] stringByAppendingPathComponent:StatusFile];
}

+ (NSString *)getUnzippedFolderPath
{
    return [[self getCodePushPath] stringByAppendingPathComponent:UnzippedFolderName];
}

+ (BOOL)installPackage:(NSDictionary *)updatePackage
   removePendingUpdate:(BOOL)removePendingUpdate
                 error:(NSError **)error
{
    NSString *packageHash = updatePackage[@"packageHash"];
    NSMutableDictionary *info = [self getCurrentPackageInfo:error];
    
    if (!info) {
        return NO;
    }
    
    if (packageHash && [packageHash isEqualToString:info[@"currentPackage"]]) {
        // The current package is already the one being installed, so we should no-op.
        return YES;
    }

    if (removePendingUpdate) {
        NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:error];
        if (currentPackageFolderPath) {
            // Error in deleting pending package will not cause the entire operation to fail.
            NSError *deleteError;
            [[NSFileManager defaultManager] removeItemAtPath:currentPackageFolderPath
                                                       error:&deleteError];
            if (deleteError) {
                CPLog(@"Error deleting pending package: %@", deleteError);
            }
        }
    } else {
        NSString *previousPackageHash = [self getPreviousPackageHash:error];
        if (previousPackageHash && ![previousPackageHash isEqualToString:packageHash]) {
            NSString *previousPackageFolderPath = [self getPackageFolderPath:previousPackageHash];
            // Error in deleting old package will not cause the entire operation to fail.
            NSError *deleteError;
            [[NSFileManager defaultManager] removeItemAtPath:previousPackageFolderPath
                                                       error:&deleteError];
            if (deleteError) {
                CPLog(@"Error deleting old package: %@", deleteError);
            }
        }
        [info setValue:info[@"currentPackage"] forKey:@"previousPackage"];
    }
    
    [info setValue:packageHash forKey:@"currentPackage"];
    return [self updateCurrentPackageInfo:info
                                    error:error];
}

+ (void)rollbackPackage
{
    NSError *error;
    NSMutableDictionary *info = [self getCurrentPackageInfo:&error];
    if (!info) {
        CPLog(@"Error getting current package info: %@", error);
        return;
    }
    
    NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:&error];        
    if (!currentPackageFolderPath) {
        CPLog(@"Error getting current package folder path: %@", error);
        return;
    }
    
    NSError *deleteError;
    BOOL result = [[NSFileManager defaultManager] removeItemAtPath:currentPackageFolderPath
                                               error:&deleteError];
    if (!result) {
        CPLog(@"Error deleting current package contents at %@ error %@", currentPackageFolderPath, deleteError);
    }
    
    [info setValue:info[@"previousPackage"] forKey:@"currentPackage"];
    [info removeObjectForKey:@"previousPackage"];
    
    [self updateCurrentPackageInfo:info error:&error];
}

+ (BOOL)updateCurrentPackageInfo:(NSDictionary *)packageInfo
                           error:(NSError **)error
{
    NSData *packageInfoData = [NSJSONSerialization dataWithJSONObject:packageInfo
                                                              options:0
                                                                error:error];
    if (!packageInfoData) {
        return NO;
    }

    NSString *packageInfoString = [[NSString alloc] initWithData:packageInfoData
                                                        encoding:NSUTF8StringEncoding];
    BOOL result = [packageInfoString writeToFile:[self getStatusFilePath]
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:error];

    if (!result) {
        return NO;
    }
    return YES;
}

#pragma mark - Multi-patch support

+ (void)downloadAndApplyMultiplePatches:(NSArray *)patches
                    finalUpdateFolderPath:(NSString *)finalUpdateFolderPath
                  finalUpdateMetadataPath:(NSString *)finalUpdateMetadataPath
                   expectedBundleFileName:(NSString *)expectedBundleFileName
                                publicKey:(NSString *)publicKey
                           operationQueue:(dispatch_queue_t)operationQueue
                         progressCallback:(void (^)(long long, long long))progressCallback
                             doneCallback:(void (^)())doneCallback
                             failCallback:(void (^)(NSError *err))failCallback
                            updatePackage:(NSDictionary *)updatePackage
{
    dispatch_async(operationQueue, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *error = nil;
        
        // Create temporary working directory
        NSString *tempWorkingPath = [[self getCodePushPath] stringByAppendingPathComponent:@"temp_multi_patch"];
        if ([fileManager fileExistsAtPath:tempWorkingPath]) {
            [fileManager removeItemAtPath:tempWorkingPath error:&error];
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                return;
            }
        }
        
        [fileManager createDirectoryAtPath:tempWorkingPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
            return;
        }
        
        @try {
            // Start with current package as base
            NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:&error];
            NSString *workingFolderPath = tempWorkingPath;
            
            if (currentPackageFolderPath != nil && [fileManager fileExistsAtPath:currentPackageFolderPath]) {
                CPLog(@"Copying current package as base for multi-patch update");
                // Copy contents of current package to working folder
                NSArray *contents = [fileManager contentsOfDirectoryAtPath:currentPackageFolderPath error:&error];
                if (error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
                for (NSString *item in contents) {
                    NSString *srcPath = [currentPackageFolderPath stringByAppendingPathComponent:item];
                    NSString *dstPath = [workingFolderPath stringByAppendingPathComponent:item];
                    [fileManager copyItemAtPath:srcPath toPath:dstPath error:&error];
                    if (error) {
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                }
            }
            
            // Calculate total size for progress reporting
            NSInteger totalPatches = [patches count];
            long long totalBytesExpected = 0;
            __block long long totalBytesReceived = 0;
            
            for (NSDictionary *patch in patches) {
                totalBytesExpected += [patch[@"size"] longLongValue];
            }
            
            // Apply each patch sequentially
            for (NSInteger i = 0; i < totalPatches; i++) {
                NSDictionary *patch = patches[i];
                NSString *patchUrl = patch[@"url"];
                NSString *fromLabel = patch[@"from_label"] ?: @"";
                NSString *toLabel = patch[@"to_label"] ?: @"";
                long long patchSize = [patch[@"size"] longLongValue];
                
                CPLog(@"Applying patch %ld/%ld: %@ -> %@", (long)(i + 1), (long)totalPatches, fromLabel, toLabel);
                
                // Download patch synchronously
                NSString *patchFilePath = [self downloadSinglePatchSync:patchUrl
                                                             patchIndex:i
                                                       progressCallback:progressCallback
                                                     bytesReceivedSoFar:totalBytesReceived
                                                     totalBytesExpected:totalBytesExpected
                                                                  error:&error];
                if (error || !patchFilePath) {
                    if (!error) {
                        error = [CodePushErrorUtils errorWithMessage:@"Failed to download patch"];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
                totalBytesReceived += patchSize;
                
                // Verify patch file hash (diff.zip SHA256)
                NSString *expectedPatchHash = patch[@"hash"];
                if (expectedPatchHash) {
                    CPLog(@"Verifying patch file hash...");
                    NSData *patchData = [NSData dataWithContentsOfFile:patchFilePath];
                    NSString *actualPatchHash = [CodePushUpdateUtils computeHashForData:patchData];
                    if (![expectedPatchHash isEqualToString:actualPatchHash]) {
                        error = [CodePushErrorUtils errorWithMessage:
                                [NSString stringWithFormat:@"Patch file hash mismatch. Expected: %@, Actual: %@",
                                 expectedPatchHash, actualPatchHash]];
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                    CPLog(@"Patch file hash verified successfully");
                }
                
                // Unzip patch to temporary folder
                NSString *patchUnzipPath = [tempWorkingPath stringByAppendingPathComponent:
                                           [NSString stringWithFormat:@"patch_%ld", (long)i]];
                [SSZipArchive unzipFileAtPath:patchFilePath toDestination:patchUnzipPath];
                [fileManager removeItemAtPath:patchFilePath error:nil];
                
                // Apply diff to a temporary result folder
                NSString *tempResultPath = [tempWorkingPath stringByAppendingPathComponent:
                                           [NSString stringWithFormat:@"result_%ld", (long)i]];
                [fileManager createDirectoryAtPath:tempResultPath
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:&error];
                if (error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
                
                NSString *diffManifestPath = [patchUnzipPath stringByAppendingPathComponent:DiffManifestFileName];
                if ([fileManager fileExistsAtPath:diffManifestPath]) {
                    // Copy working folder contents to temp result, apply deletions
                    NSArray *workingContents = [fileManager contentsOfDirectoryAtPath:workingFolderPath error:&error];
                    if (error) {
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                    
                    for (NSString *item in workingContents) {
                        NSString *srcPath = [workingFolderPath stringByAppendingPathComponent:item];
                        NSString *dstPath = [tempResultPath stringByAppendingPathComponent:item];
                        [fileManager copyItemAtPath:srcPath toPath:dstPath error:&error];
                        if (error) {
                            dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                            return;
                        }
                    }
                    
                    // Read diff manifest and delete files
                    NSString *manifestContent = [NSString stringWithContentsOfFile:diffManifestPath
                                                                          encoding:NSUTF8StringEncoding
                                                                             error:&error];
                    if (error) {
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                    
                    NSData *data = [manifestContent dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *manifestJSON = [NSJSONSerialization JSONObjectWithData:data
                                                                                 options:kNilOptions
                                                                                   error:&error];
                    if (error) {
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                    
                    NSArray *deletedFiles = manifestJSON[@"deletedFiles"];
                    for (NSString *deletedFileName in deletedFiles) {
                        NSString *absoluteDeletedFilePath = [tempResultPath stringByAppendingPathComponent:deletedFileName];
                        if ([fileManager fileExistsAtPath:absoluteDeletedFilePath]) {
                            [fileManager removeItemAtPath:absoluteDeletedFilePath error:nil];
                        }
                    }
                    
                    [fileManager removeItemAtPath:diffManifestPath error:nil];
                } else {
                    // No diff manifest, just copy working folder to temp result
                    NSArray *workingContents = [fileManager contentsOfDirectoryAtPath:workingFolderPath error:&error];
                    if (!error) {
                        for (NSString *item in workingContents) {
                            NSString *srcPath = [workingFolderPath stringByAppendingPathComponent:item];
                            NSString *dstPath = [tempResultPath stringByAppendingPathComponent:item];
                            [fileManager copyItemAtPath:srcPath toPath:dstPath error:nil];
                        }
                    }
                }
                
                // Merge patch contents into temp result
                [CodePushUpdateUtils copyEntriesInFolder:patchUnzipPath
                                              destFolder:tempResultPath
                                                   error:&error];
                if (error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
                
                [fileManager removeItemAtPath:patchUnzipPath error:nil];
                
                // Replace working folder with result
                // Clear working folder first
                NSArray *oldContents = [fileManager contentsOfDirectoryAtPath:workingFolderPath error:nil];
                for (NSString *item in oldContents) {
                    [fileManager removeItemAtPath:[workingFolderPath stringByAppendingPathComponent:item] error:nil];
                }
                
                // Copy temp result to working folder
                NSArray *resultContents = [fileManager contentsOfDirectoryAtPath:tempResultPath error:nil];
                for (NSString *item in resultContents) {
                    NSString *srcPath = [tempResultPath stringByAppendingPathComponent:item];
                    NSString *dstPath = [workingFolderPath stringByAppendingPathComponent:item];
                    [fileManager copyItemAtPath:srcPath toPath:dstPath error:nil];
                }
                
                [fileManager removeItemAtPath:tempResultPath error:nil];
            }
            
            // Move final result to target location
            CPLog(@"Moving final multi-patch result to: %@", finalUpdateFolderPath);
            [fileManager createDirectoryAtPath:finalUpdateFolderPath
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&error];
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                return;
            }
            
            NSArray *finalContents = [fileManager contentsOfDirectoryAtPath:workingFolderPath error:nil];
            for (NSString *item in finalContents) {
                NSString *srcPath = [workingFolderPath stringByAppendingPathComponent:item];
                NSString *dstPath = [finalUpdateFolderPath stringByAppendingPathComponent:item];
                [fileManager copyItemAtPath:srcPath toPath:dstPath error:&error];
                if (error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
            }
            
            // Find JS bundle and verify
            NSString *relativeBundlePath = [CodePushUpdateUtils findMainBundleInFolder:finalUpdateFolderPath
                                                                      expectedFileName:expectedBundleFileName
                                                                                 error:&error];
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                return;
            }
            
            if (!relativeBundlePath) {
                NSString *errorMessage = [NSString stringWithFormat:
                    @"Update is invalid - A JS bundle file named \"%@\" could not be found within the downloaded contents.",
                    expectedBundleFileName];
                error = [CodePushErrorUtils errorWithMessage:errorMessage];
                dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                return;
            }
            
            // Verify hash and signature
            NSString *newUpdateHash = updatePackage[@"packageHash"];
            BOOL isSignatureVerificationEnabled = (publicKey != nil);
            NSString *signatureFilePath = [CodePushUpdateUtils getSignatureFilePath:finalUpdateFolderPath];
            BOOL isSignaturePresent = [fileManager fileExistsAtPath:signatureFilePath];
            
            if (isSignatureVerificationEnabled) {
                if (isSignaturePresent) {
                    if (![CodePushUpdateUtils verifyFolderHash:finalUpdateFolderPath
                                                 expectedHash:newUpdateHash
                                                        error:&error]) {
                        CPLog(@"The update contents failed the data integrity check.");
                        if (!error) {
                            error = [CodePushErrorUtils errorWithMessage:@"The update contents failed the data integrity check."];
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                    
                    BOOL isSignatureValid = [CodePushUpdateUtils verifyUpdateSignatureFor:finalUpdateFolderPath
                                                                             expectedHash:newUpdateHash
                                                                            withPublicKey:publicKey
                                                                                    error:&error];
                    if (!isSignatureValid) {
                        CPLog(@"The update contents failed code signing check.");
                        if (!error) {
                            error = [CodePushErrorUtils errorWithMessage:@"The update contents failed code signing check."];
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                        return;
                    }
                } else {
                    error = [CodePushErrorUtils errorWithMessage:
                             @"Error! Public key was provided but there is no JWT signature within app bundle to verify."];
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
            } else {
                if (isSignaturePresent) {
                    CPLog(@"Warning! JWT signature exists but no public key configured.");
                }
                if (![CodePushUpdateUtils verifyFolderHash:finalUpdateFolderPath
                                             expectedHash:newUpdateHash
                                                    error:&error]) {
                    CPLog(@"The update contents failed the data integrity check.");
                    if (!error) {
                        error = [CodePushErrorUtils errorWithMessage:@"The update contents failed the data integrity check."];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                    return;
                }
            }
            
            // Save metadata
            NSMutableDictionary *mutableUpdatePackage = [updatePackage mutableCopy];
            [mutableUpdatePackage setValue:relativeBundlePath forKey:RelativeBundlePathKey];
            
            NSData *updateSerializedData = [NSJSONSerialization dataWithJSONObject:mutableUpdatePackage
                                                                           options:0
                                                                             error:&error];
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                return;
            }
            
            NSString *packageJsonString = [[NSString alloc] initWithData:updateSerializedData
                                                                encoding:NSUTF8StringEncoding];
            [packageJsonString writeToFile:finalUpdateMetadataPath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&error];
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{ failCallback(error); });
                return;
            }
            
            CPLog(@"Multi-patch update completed successfully!");
            dispatch_async(dispatch_get_main_queue(), ^{ doneCallback(); });
            
        } @catch (NSException *exception) {
            // Clean up on error
            if ([fileManager fileExistsAtPath:finalUpdateFolderPath]) {
                [fileManager removeItemAtPath:finalUpdateFolderPath error:nil];
            }
            NSError *exError = [CodePushErrorUtils errorWithMessage:
                               [NSString stringWithFormat:@"Multi-patch update failed: %@", exception.reason]];
            dispatch_async(dispatch_get_main_queue(), ^{ failCallback(exError); });
        } @finally {
            // Clean up temporary directory
            if ([fileManager fileExistsAtPath:tempWorkingPath]) {
                [fileManager removeItemAtPath:tempWorkingPath error:nil];
            }
        }
    });
}

+ (NSString *)downloadSinglePatchSync:(NSString *)patchUrl
                           patchIndex:(NSInteger)patchIndex
                     progressCallback:(void (^)(long long, long long))progressCallback
                   bytesReceivedSoFar:(long long)bytesReceivedSoFar
                   totalBytesExpected:(long long)totalBytesExpected
                                error:(NSError **)error
{
    NSURL *url = [NSURL URLWithString:patchUrl];
    if (!url) {
        if (error) {
            *error = [CodePushErrorUtils errorWithMessage:
                     [NSString stringWithFormat:@"Invalid patch URL: %@", patchUrl]];
        }
        return nil;
    }
    
    NSString *downloadFolder = [self getCodePushPath];
    NSString *patchFilePath = [downloadFolder stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"patch_%ld.zip", (long)patchIndex]];
    
    // Use synchronous download for simplicity in sequential patch application
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *downloadError = nil;
    __block BOOL downloadSuccess = NO;
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *taskError) {
            if (taskError) {
                downloadError = taskError;
            } else if (location) {
                NSError *moveError = nil;
                NSFileManager *fileManager = [NSFileManager defaultManager];
                
                // Remove existing file if any
                if ([fileManager fileExistsAtPath:patchFilePath]) {
                    [fileManager removeItemAtPath:patchFilePath error:nil];
                }
                
                [fileManager moveItemAtPath:[location path] toPath:patchFilePath error:&moveError];
                if (moveError) {
                    downloadError = moveError;
                } else {
                    downloadSuccess = YES;
                }
            }
            dispatch_semaphore_signal(semaphore);
        }];
    
    [downloadTask resume];
    
    // Wait for download to complete (with timeout of 5 minutes per patch)
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        [downloadTask cancel];
        if (error) {
            *error = [CodePushErrorUtils errorWithMessage:@"Patch download timed out"];
        }
        return nil;
    }
    
    if (downloadError) {
        if (error) {
            *error = downloadError;
        }
        return nil;
    }
    
    if (!downloadSuccess) {
        if (error) {
            *error = [CodePushErrorUtils errorWithMessage:@"Patch download failed"];
        }
        return nil;
    }
    
    // Report progress after successful download
    if (progressCallback && totalBytesExpected > 0) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSDictionary *attrs = [fileManager attributesOfItemAtPath:patchFilePath error:nil];
        long long fileSize = [attrs fileSize];
        long long totalReceived = bytesReceivedSoFar + fileSize;
        dispatch_async(dispatch_get_main_queue(), ^{
            progressCallback(totalReceived, totalBytesExpected);
        });
    }
    
    return patchFilePath;
}


@end
