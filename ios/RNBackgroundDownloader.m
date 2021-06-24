//
//  RNFileBackgroundDownload.m
//  EkoApp
//
//  Created by Elad Gil on 20/11/2017.
//  Copyright © 2017 Eko. All rights reserved.
//
//
#import "RNBackgroundDownloader.h"
#import "RNBGDTaskConfig.h"

#define ID_TO_CONFIG_MAP_KEY @"com.eko.bgdownloadidmap"

static CompletionHandler storedCompletionHandler;

@implementation RNBackgroundDownloader {
    NSURLSession *urlSession;
    NSURLSessionConfiguration *sessionConfig;
    AVAssetDownloadURLSession *assetDownloadURLSession;
    NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *taskToConfigMap;
    NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *idToTaskMap;
    NSMutableDictionary<NSString *, NSURLSessionTask *> *idToAssetTaskMap;
    NSMutableDictionary<NSString *, NSData *> *idToResumeDataMap;
    NSMutableDictionary<NSString *, NSNumber *> *idToPercentMap;
    NSMutableDictionary<NSString *, NSDictionary *> *progressReports;
    NSMutableDictionary<AVAggregateAssetDownloadTask *, NSURL *> *willDownloadToUrlMap;
    NSDate *lastProgressReport;
    NSNumber *sharedLock;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue
{
    return dispatch_queue_create("com.eko.backgrounddownloader", DISPATCH_QUEUE_SERIAL);
}

+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"downloadComplete", @"downloadProgress", @"downloadFailed", @"downloadBegin"];
}

- (NSDictionary *)constantsToExport {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);

    return @{
             @"documents": [paths firstObject],
             @"TaskRunning": @(NSURLSessionTaskStateRunning),
             @"TaskSuspended": @(NSURLSessionTaskStateSuspended),
             @"TaskCanceling": @(NSURLSessionTaskStateCanceling),
             @"TaskCompleted": @(NSURLSessionTaskStateCompleted)
             };
}

- (id) init {
    self = [super init];
    if (self) {
        taskToConfigMap = [self deserialize:[[NSUserDefaults standardUserDefaults] objectForKey:ID_TO_CONFIG_MAP_KEY]];
        if (taskToConfigMap == nil) {
            taskToConfigMap = [[NSMutableDictionary alloc] init];
        }
        idToTaskMap = [[NSMutableDictionary alloc] init];
        idToResumeDataMap= [[NSMutableDictionary alloc] init];
        idToPercentMap = [[NSMutableDictionary alloc] init];
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
        progressReports = [[NSMutableDictionary alloc] init];
        lastProgressReport = [[NSDate alloc] init];
        sharedLock = [NSNumber numberWithInt:1];
    }
    return self;
}

- (void)lazyInitSession {
    if (urlSession == nil) {
        NSNumber *timestamp = [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]];
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        NSString *stringToAppend = [@".backgrounddownloadtask_" stringByAppendingString:[timestamp stringValue]];
        NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:stringToAppend];
        sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:sessonIdentifier];
        urlSession = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:nil];
    }
}

- (void)lazyInitAssetSession {
    if (assetDownloadURLSession == nil) {
        NSNumber *timestamp = [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]];
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        NSString *stringToAppend = [@".backgrounddownloadtask_" stringByAppendingString:[timestamp stringValue]];
        NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:stringToAppend];
        sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:sessonIdentifier];
        assetDownloadURLSession = [AVAssetDownloadURLSession sessionWithConfiguration:sessionConfig assetDownloadDelegate:self delegateQueue:nil];
    }
}

- (void)removeTaskFromMap: (NSURLSessionTask *)task {
    @synchronized (sharedLock) {
        NSNumber *taskId = @(task.taskIdentifier);
        RNBGDTaskConfig *taskConfig = taskToConfigMap[taskId];

        [taskToConfigMap removeObjectForKey:taskId];
        [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];
      
        if ([task isKindOfClass:[AVAggregateAssetDownloadTask class]]) {
          [willDownloadToUrlMap removeObjectForKey:task];
        }

        if (taskConfig) {
            [idToTaskMap removeObjectForKey:taskConfig.id];
            [idToPercentMap removeObjectForKey:taskConfig.id];
            [idToAssetTaskMap removeObjectForKey:taskConfig.id];
        }
    }
}

+ (void)setCompletionHandlerWithIdentifier: (NSString *)identifier completionHandler: (CompletionHandler)completionHandler {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
    if ([sessonIdentifier isEqualToString:identifier]) {
        storedCompletionHandler = completionHandler;
    }
}


#pragma mark - JS exported methods
RCT_EXPORT_METHOD(downloadStream: (NSDictionary *) options) {
  if (@available(iOS 11.0, *)) {
    NSString *identifier = options[@"id"];
    NSString *url = options[@"url"];
    NSString *title = options[@"title"];
    NSData   *imageData = options[@"image_data"];
    NSString *destination = options[@"destination"];
    NSNumber *minimumBitrate = options[@"minimum_bitrate"] != nil ? options[@"minimum_bitrate"] : @1300000;
    
    if (identifier == nil || url == nil || title == nil || destination == nil) {
        NSLog(@"[RNBackgroundDownloader] - [Error] id, url and destination must be set");
        return;
    }
    [self lazyInitAssetSession];

    NSURL *assetURL = [NSURL URLWithString:url];
    AVURLAsset *asset = [AVURLAsset assetWithURL:assetURL];
  
    @synchronized (sharedLock) {
      NSDictionary *options = @{AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: minimumBitrate};
      AVAggregateAssetDownloadTask *task = [assetDownloadURLSession aggregateAssetDownloadTaskWithURLAsset:asset
                                                                                           mediaSelections:asset.allMediaSelections
                                                                                                assetTitle:title
                                                                                          assetArtworkData:imageData
                                                                                                   options: options];
        RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary: @{@"id": identifier, @"destination": destination}];

        taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
        [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

        idToAssetTaskMap[identifier] = task;
        idToPercentMap[identifier] = @0.0;

        [task resume];
    }
  } else {
    NSLog(@"[RNBackgroundDownloader] - [Error] downloadStream is not available in this iOS version (11 required)");
    return;
  }
  
}

RCT_EXPORT_METHOD(download: (NSDictionary *) options) {
    NSString *identifier = options[@"id"];
    NSString *url = options[@"url"];
    NSString *destination = options[@"destination"];
    NSDictionary *headers = options[@"headers"];
    if (identifier == nil || url == nil || destination == nil) {
        NSLog(@"[RNBackgroundDownloader] - [Error] id, url and destination must be set");
        return;
    }
    [self lazyInitSession];

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url]];
    if (headers != nil) {
        for (NSString *headerKey in headers) {
            [request setValue:[headers valueForKey:headerKey] forHTTPHeaderField:headerKey];
        }
    }

    @synchronized (sharedLock) {
        NSURLSessionDownloadTask __strong *task = [urlSession downloadTaskWithRequest:request];
        RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary: @{@"id": identifier, @"destination": destination}];

        taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
        [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

        idToTaskMap[identifier] = task;
        idToPercentMap[identifier] = @0.0;

        [task resume];
    }
}

RCT_EXPORT_METHOD(pauseTask: (NSString *)identifier) {
    @synchronized (sharedLock) {
        NSURLSessionDownloadTask *task = idToTaskMap[identifier];
        if (task != nil && task.state == NSURLSessionTaskStateRunning) {
            [task suspend];
        }
      
        if (@available(iOS 11.0, *)) {
          AVAggregateAssetDownloadTask *assetTask = (AVAggregateAssetDownloadTask *)idToAssetTaskMap[identifier];
          if (assetTask != nil && assetTask.state == NSURLSessionTaskStateRunning) {
              [assetTask suspend];
          }
        }
    }
}

RCT_EXPORT_METHOD(resumeTask: (NSString *)identifier) {
    @synchronized (sharedLock) {
        NSURLSessionDownloadTask *task = idToTaskMap[identifier];
        if (task != nil && task.state == NSURLSessionTaskStateSuspended) {
            [task resume];
        }
        if (@available(iOS 11.0, *)) {
          AVAggregateAssetDownloadTask *assetTask = (AVAggregateAssetDownloadTask *)idToAssetTaskMap[identifier];
          if (assetTask != nil && assetTask.state == NSURLSessionTaskStateRunning) {
              [assetTask resume];
          }
        }
    }
}

RCT_EXPORT_METHOD(stopTask: (NSString *)identifier) {
    @synchronized (sharedLock) {
        NSURLSessionDownloadTask *task = idToTaskMap[identifier];
        if (task != nil) {
            [task cancel];
            [self removeTaskFromMap:task];
        }
        if (@available(iOS 11.0, *)) {
          AVAggregateAssetDownloadTask *assetTask = (AVAggregateAssetDownloadTask *)idToAssetTaskMap[identifier];
          if (assetTask != nil && assetTask.state == NSURLSessionTaskStateRunning) {
              [assetTask cancel];
              [self removeTaskFromMap:assetTask];
          }
        }
    }
}

RCT_EXPORT_METHOD(checkForExistingDownloads: (RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    [self lazyInitSession];
    [urlSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        NSMutableArray *idsFound = [[NSMutableArray alloc] init];
        @synchronized (sharedLock) {
            for (NSURLSessionDownloadTask *foundTask in downloadTasks) {
                NSURLSessionDownloadTask __strong *task = foundTask;
                RNBGDTaskConfig *taskConfig = taskToConfigMap[@(task.taskIdentifier)];
                if (taskConfig) {
                    if (task.state == NSURLSessionTaskStateCompleted && task.countOfBytesReceived < task.countOfBytesExpectedToReceive) {
                        if (task.error && task.error.code == -999 && task.error.userInfo[NSURLSessionDownloadTaskResumeData] != nil) {
                            task = [urlSession downloadTaskWithResumeData:task.error.userInfo[NSURLSessionDownloadTaskResumeData]];
                        } else {
                            task = [urlSession downloadTaskWithURL:foundTask.currentRequest.URL];
                        }
                        [task resume];
                    }
                    NSNumber *percent = foundTask.countOfBytesExpectedToReceive > 0 ? [NSNumber numberWithFloat:(float)task.countOfBytesReceived/(float)foundTask.countOfBytesExpectedToReceive] : @0.0;
                    [idsFound addObject:@{
                                          @"id": taskConfig.id,
                                          @"state": [NSNumber numberWithInt: task.state],
                                          @"bytesWritten": [NSNumber numberWithLongLong:task.countOfBytesReceived],
                                          @"totalBytes": [NSNumber numberWithLongLong:foundTask.countOfBytesExpectedToReceive],
                                          @"percent": percent
                                          }];
                    taskConfig.reportedBegin = YES;
                    taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
                    idToTaskMap[taskConfig.id] = task;
                    idToPercentMap[taskConfig.id] = percent;
                } else {
                    [task cancel];
                }
            }
            resolve(idsFound);
        }
    }];
}

- (void)completeTask:(NSURLSessionTask *)downloadTask forLocation:(NSURL *)location {
  RNBGDTaskConfig *taskCofig = taskToConfigMap[@(downloadTask.taskIdentifier)];
  if (taskCofig != nil) {
      NSFileManager *fileManager = [NSFileManager defaultManager];
      NSURL *destURL = [NSURL fileURLWithPath:taskCofig.destination];
      [fileManager createDirectoryAtURL:[destURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
      [fileManager removeItemAtURL:destURL error:nil];
      NSError *moveError;
      BOOL moved = [fileManager moveItemAtURL:location toURL:destURL error:&moveError];
      if (self.bridge) {
          if (moved) {
              [self sendEventWithName:@"downloadComplete" body:@{@"id": taskCofig.id}];
          } else {
              [self sendEventWithName:@"downloadFailed" body:@{@"id": taskCofig.id, @"error": [moveError localizedDescription]}];
          }
      }
      [self removeTaskFromMap:downloadTask];
  }
}

#pragma mark - AVAssetDownloadDelegate methods
- (void)URLSession:(NSURLSession *)session aggregateAssetDownloadTask:(AVAggregateAssetDownloadTask *)aggregateAssetDownloadTask willDownloadToURL:(NSURL *)location  API_AVAILABLE(ios(11.0)){
  willDownloadToUrlMap[aggregateAssetDownloadTask] = location;
}

- (void)URLSession:(NSURLSession *)session aggregateAssetDownloadTask:(AVAggregateAssetDownloadTask *)aggregateAssetDownloadTask didLoadTimeRange:(CMTimeRange)timeRange totalTimeRangesLoaded:(NSArray<NSValue *> *)loadedTimeRanges timeRangeExpectedToLoad:(CMTimeRange)timeRangeExpectedToLoad forMediaSelection:(AVMediaSelection *)mediaSelection  API_AVAILABLE(ios(11.0)){
    @synchronized (sharedLock) {
      RNBGDTaskConfig *taskCofig = taskToConfigMap[@(aggregateAssetDownloadTask.taskIdentifier)];
      if (taskCofig != nil) {
          float percent = 0;
          float totalLoaded = 0;
          for (NSValue *value in loadedTimeRanges) {
              CMTimeRange timeRange = [value CMTimeRangeValue];
              totalLoaded += CMTimeGetSeconds(timeRange.duration);
              percent += CMTimeGetSeconds(timeRange.duration) / CMTimeGetSeconds(timeRangeExpectedToLoad.duration);
          }
          if (!taskCofig.reportedBegin) {
              [self sendEventWithName:@"downloadBegin" body:@{@"id": taskCofig.id, @"expectedBytes": [NSNumber numberWithLongLong: CMTimeGetSeconds(timeRangeExpectedToLoad.duration)]}];
              taskCofig.reportedBegin = YES;
          }

          NSNumber *prevPercent = idToPercentMap[taskCofig.id];
          if (percent - [prevPercent floatValue] > 0.01f) {
              progressReports[taskCofig.id] = @{@"id": taskCofig.id, @"written": [NSNumber numberWithLongLong: totalLoaded], @"total": [NSNumber numberWithLongLong: CMTimeGetSeconds(timeRangeExpectedToLoad.duration)], @"percent": [NSNumber numberWithFloat:percent]};
              idToPercentMap[taskCofig.id] = [NSNumber numberWithFloat:percent];
          }

          NSDate *now = [[NSDate alloc] init];
          if ([now timeIntervalSinceDate:lastProgressReport] > 1.5 && progressReports.count > 0) {
              if (self.bridge) {
                  [self sendEventWithName:@"downloadProgress" body:[progressReports allValues]];
              }
              lastProgressReport = now;
              [progressReports removeAllObjects];
          }
      }
    }
}

#pragma mark - NSURLSessionDownloadDelegate methods
- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location {
    @synchronized (sharedLock) {
      [self completeTask:downloadTask forLocation:location];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskCofig = taskToConfigMap[@(downloadTask.taskIdentifier)];
        if (taskCofig != nil) {
            if (!taskCofig.reportedBegin) {
                [self sendEventWithName:@"downloadBegin" body:@{@"id": taskCofig.id, @"expectedBytes": [NSNumber numberWithLongLong: totalBytesExpectedToWrite]}];
                taskCofig.reportedBegin = YES;
            }

            NSNumber *prevPercent = idToPercentMap[taskCofig.id];
            NSNumber *percent = [NSNumber numberWithFloat:(float)totalBytesWritten/(float)totalBytesExpectedToWrite];
            if ([percent floatValue] - [prevPercent floatValue] > 0.01f) {
                progressReports[taskCofig.id] = @{@"id": taskCofig.id, @"written": [NSNumber numberWithLongLong: totalBytesWritten], @"total": [NSNumber numberWithLongLong: totalBytesExpectedToWrite], @"percent": percent};
                idToPercentMap[taskCofig.id] = percent;
            }

            NSDate *now = [[NSDate alloc] init];
            if ([now timeIntervalSinceDate:lastProgressReport] > 1.5 && progressReports.count > 0) {
                if (self.bridge) {
                    [self sendEventWithName:@"downloadProgress" body:[progressReports allValues]];
                }
                lastProgressReport = now;
                [progressReports removeAllObjects];
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskCofig = taskToConfigMap[@(task.taskIdentifier)];
        if (error != nil && error.code != -999 && taskCofig != nil) {
            if (self.bridge) {
                [self sendEventWithName:@"downloadFailed" body:@{@"id": taskCofig.id, @"error": [error localizedDescription]}];
            }
            [self removeTaskFromMap:task];
        } else if (@available(iOS 11.0, *)) {
          if ([task isKindOfClass:[AVAggregateAssetDownloadTask class]]) {
            NSURL *location = willDownloadToUrlMap[(AVAggregateAssetDownloadTask *)task];
            if (location != nil) {
              [self completeTask:task forLocation:location];
            }
          }
        }
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (storedCompletionHandler) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            storedCompletionHandler();
            storedCompletionHandler = nil;
        }];
    }
}

#pragma mark - serialization
- (NSData *)serialize: (id)obj {
    return [NSKeyedArchiver archivedDataWithRootObject:obj];
}

- (id)deserialize: (NSData *)data {
    if (data == nil) {
        return nil;
    }

    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

@end
