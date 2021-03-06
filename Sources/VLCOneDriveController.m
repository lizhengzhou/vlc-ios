/*****************************************************************************
 * VLCOneDriveController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2014-2019 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCOneDriveController.h"
#import "VLCOneDriveConstants.h"
#import "UIDevice+VLC.h"
#import "NSString+SupportedMedia.h"
#import "VLCHTTPFileDownloader.h"
#import <OneDriveSDK.h>

#if TARGET_OS_IOS
# import "VLC-Swift.h"
#endif

@interface VLCOneDriveController ()
{
    NSMutableArray *_pendingDownloads;
    BOOL _downloadInProgress;

    CGFloat _averageSpeed;
    CGFloat _fileSize;
    NSTimeInterval _startDL;
    NSTimeInterval _lastStatsUpdate;

    ODClient *_oneDriveClient;
    NSMutableArray *_currentItems;
    VLCHTTPFileDownloader *_fileDownloader;
}

@end

@implementation VLCOneDriveController

+ (VLCCloudStorageController *)sharedInstance
{
    static VLCOneDriveController *sharedInstance = nil;
    static dispatch_once_t pred;

    dispatch_once(&pred, ^{
        sharedInstance = [[VLCOneDriveController alloc] init];
    });

    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];

    if (!self)
        return self;
//    [self restoreFromSharedCredentials];
    _oneDriveClient = [ODClient loadCurrentClient];
    [self setupSession];
    return self;
}

- (void)setupSession
{
    _parentItem = nil;
    _currentItem  = nil;
    _rootItemID = nil;
    _currentItems = [[NSMutableArray alloc] init];
}

#pragma mark - authentication

- (BOOL)activeSession
{
    return _oneDriveClient != nil;
}

- (void)loginWithViewController:(UIViewController *)presentingViewController
{
    _presentingViewController = presentingViewController;

    [ODClient authenticatedClientWithCompletion:^(ODClient *client, NSError *error) {
        if (error) {
            [self authFailed:error];
            return;
        }
        self->_oneDriveClient = client;
        [self authSuccess];
    }];
}

- (void)logout
{
    [_oneDriveClient signOutWithCompletion:^(NSError *error) {
        NSUbiquitousKeyValueStore *ubiquitousStore = [NSUbiquitousKeyValueStore defaultStore];
        [ubiquitousStore removeObjectForKey:kVLCStoreOneDriveCredentials];
        [ubiquitousStore synchronize];
        self->_oneDriveClient = nil;
        self->_currentItem  = nil;
        self->_currentItems = nil;
        self->_rootItemID = nil;
        self->_parentItem = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_presentingViewController) {
                [self->_presentingViewController.navigationController popViewControllerAnimated:YES];
            }
        });
    }];
}

- (NSArray *)currentListFiles
{
    return [_currentItems copy];
}

- (BOOL)isAuthorized
{
    return _oneDriveClient != nil;
}

- (void)authSuccess
{
    APLog(@"VLCOneDriveController: Authentication complete.");

    [self setupSession];

    [[NSNotificationCenter defaultCenter] postNotificationName:VLCOneDriveControllerSessionUpdated object:self];
//    [self shareCredentials];
}

- (void)authFailed:(NSError *)error
{
    APLog(@"VLCOneDriveController: Authentication failure.");

    if (self.delegate) {
        if ([self.delegate respondsToSelector:@selector(sessionWasUpdated)])
            [self.delegate performSelector:@selector(sessionWasUpdated)];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:VLCOneDriveControllerSessionUpdated object:self];
}

- (void)shareCredentials
{
    // FIXME: https://github.com/OneDrive/onedrive-sdk-ios/issues/187

/* share our credentials */
//    LiveAuthStorage *authStorage = [[LiveAuthStorage alloc] initWithClientId:kVLCOneDriveClientID];
//    _oneDriveClient = [[ODClient alloc] ]
//    _oneDriveClient.authProvider.accountSession.refreshToken;
//NSString *credentials = [authStorage refreshToken];
//  NSString *credentials = [_oneDriveClient token]
//    if (credentials == nil)
//        return;
//
//    NSUbiquitousKeyValueStore *ubiquitousStore = [NSUbiquitousKeyValueStore defaultStore];
//    [ubiquitousStore setString:credentials forKey:kVLCStoreOneDriveCredentials];
//    [ubiquitousStore synchronize];
}

- (BOOL)restoreFromSharedCredentials
{
//    LiveAuthStorage *authStorage = [[LiveAuthStorage alloc] initWithClientId:kVLCOneDriveClientID];
//    NSUbiquitousKeyValueStore *ubiquitousStore = [NSUbiquitousKeyValueStore defaultStore];
//    [ubiquitousStore synchronize];
//    NSString *credentials = [ubiquitousStore stringForKey:kVLCStoreOneDriveCredentials];
//    if (!credentials)
//        return NO;
//
//    [authStorage setRefreshToken:credentials];
    return YES;
}

#pragma mark - listing

- (void)requestDirectoryListingAtPath:(NSString *)path
{
    [self loadODItems];
}

- (void)prepareODItems:(NSArray<ODItem *> *)items
{
    for (ODItem *item in items) {
        if (!_rootItemID) {
            _rootItemID = item.parentReference.id;
        }

        if (![_currentItems containsObject:item.id] && ([item.name isSupportedFormat] || item.folder)) {
            [_currentItems addObject:item];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate) {
            [self.delegate performSelector:@selector(mediaListUpdated)];
        }
    });

}

- (void)loadODItemsWithCompletionHandler:(void (^)(void))completionHandler
{
    NSString *itemID = _currentItem ? _currentItem.id : @"root";
    ODChildrenCollectionRequest * request = [[[[_oneDriveClient drive] items:itemID] children] request];

    // Clear all current
    [_currentItems removeAllObjects];

    __weak typeof(self) weakSelf = self;

    [request getWithCompletion:^(ODCollection *response, ODChildrenCollectionRequest *nextRequest, NSError *error) {
        if (!error) {
            [self prepareODItems:response.value];
            if (completionHandler) {
                completionHandler();
            }
        } else {
            [weakSelf handleLoadODItemErrorWithError:error itemID:itemID];
        }
    }];
}

- (void)handleLoadODItemErrorWithError:(NSError *)error itemID:(NSString *)itemID
{
    __weak typeof(self) weakSelf = self;

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[error localizedFailureReason]
                                                                             message:[error localizedDescription]
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"BUTTON_OK", nil)
                                                       style:UIAlertActionStyleCancel
                                                     handler:^(UIAlertAction *alertAction) {
                                                         if (weakSelf.presentingViewController && [itemID isEqualToString:@"root"]) {
                                                             [weakSelf.presentingViewController.navigationController popViewControllerAnimated:YES];
                                                         }
                                                     }];

    [alertController addAction:okAction];

    if (weakSelf.presentingViewController) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.presentingViewController presentViewController:alertController animated:YES completion:nil];
        });
    }
}

- (void)loadODParentItem
{
    NSString *parentID = _parentItem.id ? _parentItem.id : @"root";

    ODItemRequest *request = [[[_oneDriveClient drive] items:parentID] request];

    __weak typeof(self) weakSelf = self;

    [request getWithCompletion:^(ODItem *response, NSError *error) {
        if (!error) {
            weakSelf.parentItem = response;
        } else {
            [weakSelf handleLoadODItemErrorWithError:error itemID:parentID];
        }
    }];
}

- (void)loadODItems
{
    [self loadODItemsWithCompletionHandler:nil];
}

- (void)loadThumbnails:(NSArray<ODItem *> *)items
{
    for (ODItem *item in items) {
        if ([item thumbnails:0]) {
            [[[[[_oneDriveClient.drive items:item.id] thumbnails:@"0"] small] contentRequest]
             downloadWithCompletion:^(NSURL *location, NSURLResponse *response, NSError *error) {
                 if (!error) {
                 }
             }];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate) {
            [self.delegate performSelector:@selector(mediaListUpdated)];
        }
    });
}

#pragma - subtitle

- (NSString *)configureSubtitleWithFileName:(NSString *)fileName folderItems:(NSArray *)folderItems
{
    return [self _getFileSubtitleFromServer:[self _searchSubtitle:fileName folderItems:folderItems]];
}

- (NSMutableDictionary *)_searchSubtitle:(NSString *)fileName folderItems:(NSArray *)folderItems
{
    NSMutableDictionary *itemSubtitle = [[NSMutableDictionary alloc] init];

    NSString *urlTemp = [[fileName lastPathComponent] stringByDeletingPathExtension];

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name contains[c] %@", urlTemp];
    NSArray *results = [folderItems filteredArrayUsingPredicate:predicate];

    for (ODItem *item in results) {
        if ([item.name isSupportedSubtitleFormat]) {
            [itemSubtitle setObject:item.name forKey:@"filename"];
            [itemSubtitle setObject:[NSURL URLWithString:item.dictionaryFromItem[@"@content.downloadUrl"]] forKey:@"url"];
        }
    }
    return itemSubtitle;
}

- (NSString *)_getFileSubtitleFromServer:(NSMutableDictionary *)itemSubtitle
{
    NSString *fileSubtitlePath = nil;
    if (itemSubtitle[@"filename"]) {
        NSData *receivedSub = [NSData dataWithContentsOfURL:[itemSubtitle objectForKey:@"url"]]; // TODO: fix synchronous load

        if (receivedSub.length < [[UIDevice currentDevice] VLCFreeDiskSpace].longLongValue) {
            NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
            NSString *directoryPath = searchPaths.firstObject;
            fileSubtitlePath = [directoryPath stringByAppendingPathComponent:[itemSubtitle objectForKey:@"filename"]];

            NSFileManager *fileManager = [NSFileManager defaultManager];
            if (![fileManager fileExistsAtPath:fileSubtitlePath]) {
                //create local subtitle file
                [fileManager createFileAtPath:fileSubtitlePath contents:nil attributes:nil];
                if (![fileManager fileExistsAtPath:fileSubtitlePath]) {
                    APLog(@"file creation failed, no data was saved");
                    return nil;
                }
            }
            [receivedSub writeToFile:fileSubtitlePath atomically:YES];
        } else {
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"DISK_FULL", nil)
                                                                                     message:[NSString stringWithFormat:NSLocalizedString(@"DISK_FULL_FORMAT", nil),
                                                                                              [itemSubtitle objectForKey:@"filename"],
                                                                                              [[UIDevice currentDevice] model]]
                                                                              preferredStyle:UIAlertControllerStyleAlert];

            UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"BUTTON_OK", nil)
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];

            [alertController addAction:okAction];
            [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alertController animated:YES completion:nil];
        }
    }

    return fileSubtitlePath;
}

#pragma mark - file handling

- (BOOL)canPlayAll
{
    return YES;
}

- (void)startDownloadingODItem:(ODItem *)item
{
    if (item == nil)
        return;
    if (item.folder)
        return;

    if (!_pendingDownloads)
        _pendingDownloads = [[NSMutableArray alloc] init];
    [_pendingDownloads addObject:item];

    [self _triggerNextDownload];
}

- (void)downloadODItem:(ODItem *)item
{
#if TARGET_OS_IOS
    if (!_fileDownloader) {
        _fileDownloader = [[VLCHTTPFileDownloader alloc] init];
        _fileDownloader.delegate = self;
    }
    [_fileDownloader downloadFileFromURL:[NSURL URLWithString:item.dictionaryFromItem[@"@content.downloadUrl"]]
                            withFileName:item.name];
#endif
}

- (void)_triggerNextDownload
{
    if (_pendingDownloads.count > 0 && !_downloadInProgress) {
        _downloadInProgress = YES;
        [self downloadODItem:_pendingDownloads.firstObject];
        [_pendingDownloads removeObjectAtIndex:0];

        if ([self.delegate respondsToSelector:@selector(numberOfFilesWaitingToBeDownloadedChanged)])
            [self.delegate numberOfFilesWaitingToBeDownloadedChanged];
    }
}

- (void)downloadStarted
{
    _startDL = [NSDate timeIntervalSinceReferenceDate];
    if ([self.delegate respondsToSelector:@selector(operationWithProgressInformationStarted)])
        [self.delegate operationWithProgressInformationStarted];
}

- (void)downloadEnded
{
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString(@"GDRIVE_DOWNLOAD_SUCCESSFUL", nil));

    if ([self.delegate respondsToSelector:@selector(operationWithProgressInformationStopped)])
        [self.delegate operationWithProgressInformationStopped];

#if TARGET_OS_IOS
    // FIXME: Replace notifications by cleaner observers
    [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.VLCNewFileAddedNotification
                                                        object:self];
#endif
    _downloadInProgress = NO;
    [self _triggerNextDownload];
}

- (void)downloadFailedWithErrorDescription:(NSString *)description
{
    APLog(@"VLCOneDriveController: Download failed (%@)", description);
}

- (void)progressUpdatedTo:(CGFloat)percentage receivedDataSize:(CGFloat)receivedDataSize expectedDownloadSize:(CGFloat)expectedDownloadSize
{
    [self progressUpdated:percentage];
    [self calculateRemainingTime:receivedDataSize expectedDownloadSize:expectedDownloadSize];
}

- (void)progressUpdated:(CGFloat)progress
{
    if ([self.delegate respondsToSelector:@selector(currentProgressInformation:)])
        [self.delegate currentProgressInformation:progress];
}

- (void)calculateRemainingTime:(CGFloat)receivedDataSize expectedDownloadSize:(CGFloat)expectedDownloadSize
{
    CGFloat lastSpeed = receivedDataSize / ([NSDate timeIntervalSinceReferenceDate] - _startDL);
    CGFloat smoothingFactor = 0.005;
    _averageSpeed = isnan(_averageSpeed) ? lastSpeed : smoothingFactor * lastSpeed + (1 - smoothingFactor) * _averageSpeed;

    CGFloat RemainingInSeconds = (expectedDownloadSize - receivedDataSize)/_averageSpeed;

    NSDate *date = [NSDate dateWithTimeIntervalSince1970:RemainingInSeconds];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss"];
    [formatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];

    NSString  *remaingTime = [formatter stringFromDate:date];
    if ([self.delegate respondsToSelector:@selector(updateRemainingTime:)])
        [self.delegate updateRemainingTime:remaingTime];
}

@end
