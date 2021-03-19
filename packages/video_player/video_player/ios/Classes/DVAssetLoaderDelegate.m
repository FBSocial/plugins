//
//  DVAssetLoaderDelegate.m
//
//  Created by Vladislav Dugnist on 31/12/2017.
//  Copyright © 2017 vdugnist. All rights reserved.
//

#import <MobileCoreServices/UTType.h>
#import <SystemConfiguration/SCNetworkReachability.h>
#import "DVAssetLoaderDelegate.h"
#import "DVAssetLoaderHelpers.h"
#import "DVAssetLoaderError.h"

static NSTimeInterval const kDefaultLoadingTimeout = 15;

@interface DVAssetLoaderDelegate () <NSURLSessionDelegate, NSURLSessionDataDelegate> {
    NSString *_cacheFileName;
    NSString *_cacheFilePath;
    NSString *_cacheFileTmpPath;
    NSRange _savedRange;
}

@property (nonatomic, readonly) NSURL *originalURL;
@property (nonatomic, readonly) NSString *originalScheme;

@property (nonatomic) DVAssetLoaderError *networkError;
@property (nonatomic) NSMutableArray<AVAssetResourceLoadingRequest *> *pendingRequests;
@property (nonatomic) NSMutableArray<NSURLSessionDataTask *> *fragDataTasks;
@property (nonatomic) NSMutableArray<NSMutableData *> *fragDatas;
@property (nonatomic) NSMutableDictionary<NSValue *, NSString *> *fragDataPathDictionary;

@end

@implementation DVAssetLoaderDelegate

#pragma mark - Public

- (instancetype)initWithURL:(NSURL *)url cachedPath:(NSString *)cachedPath fileName:(NSString *)fileName {
    _cacheFilePath = cachedPath;
    _cacheFileName = fileName;
    _cacheFileTmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[fileName stringByAppendingString:@".tmp"]];
    [[NSFileManager defaultManager] removeItemAtPath:_cacheFileTmpPath error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:_cacheFileTmpPath]) {
        [[NSFileManager defaultManager] createFileAtPath:_cacheFileTmpPath contents:nil attributes:nil];
    }
    return [self initWithURL:url];
}

- (instancetype)initWithURL:(NSURL *)url {
    NSParameterAssert([url.scheme.lowercaseString hasPrefix:@"http"]);

    if (self = [super init]) {
        _originalURL = url;
        _originalScheme = url.scheme;
        _pendingRequests = [NSMutableArray new];
        _fragDataTasks = [NSMutableArray new];
        _fragDatas = [NSMutableArray new];
        _fragDataPathDictionary = [NSMutableDictionary new];
        _savedRange = NSMakeRange(0, 0);
        _networkTimeout = kDefaultLoadingTimeout;
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:[NSOperationQueue mainQueue]];
    }

    return self;
}

- (instancetype)init {
    @throw [NSString stringWithFormat:@"Init unavailable. Use %@ instead.", NSStringFromSelector(@selector(initWithURL:))];
}

+ (instancetype) new {
    @throw [NSString stringWithFormat:@"New unavailable. Use alloc %@ instead.", NSStringFromSelector(@selector(initWithURL:))];
}

+ (NSString *)scheme {
    return NSStringFromClass(self);
}

- (void)cancelRequests {
    [self.session invalidateAndCancel];
    self.session = nil;
}

#pragma mark - Resource loader delegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    if (![loadingRequest.request.URL.scheme isEqualToString:[[self class] scheme]]) {
        return NO;
    }
    
    // check reachability only if there was network error before
    if (self.networkError) {
        BOOL nowReachable = isNetworkReachable();
        if (nowReachable) {
            self.networkError = nil;
        } else if ([[NSDate date] timeIntervalSinceDate:self.networkError.date] > self.networkTimeout){
            if ([self.delegate respondsToSelector:@selector(dvAssetLoaderDelegate:didRecieveLoadingError:withDataTask:forRequest:)]) {
                [self.delegate dvAssetLoaderDelegate:self didRecieveLoadingError:self.networkError.error withDataTask:nil forRequest:loadingRequest];
            }
            return NO;
        } else {
            [loadingRequest finishLoadingWithError:self.networkError.error];
            return YES;
        }
    }

    NSUInteger loadingRequestIndex = NSNotFound;

    loadingRequestIndex = [self.pendingRequests indexOfObjectPassingTest:^BOOL(AVAssetResourceLoadingRequest *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
        if (![obj.request isEqual:loadingRequest.request]) {
            return NO;
        }

        if (obj.dataRequest.requestedOffset != loadingRequest.dataRequest.requestedOffset) {
            return NO;
        }

        if (obj.dataRequest.requestedLength != loadingRequest.dataRequest.requestedLength) {
            return NO;
        }

        return YES;
    }];

    if (loadingRequestIndex == NSNotFound) {
        NSURL *actualURL = [self urlForLoadingRequest:loadingRequest];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:actualURL];

        if (loadingRequest.contentInformationRequest) {
            request.allHTTPHeaderFields = @{ @"Range" : @"bytes=0-1" };
        } else if (loadingRequest.dataRequest.requestsAllDataToEndOfResource) {
            long long requestedOffset = loadingRequest.dataRequest.requestedOffset;
            request.allHTTPHeaderFields = @{ @"Range" : [NSString stringWithFormat:@"bytes=%lld-", requestedOffset] };
        } else if (loadingRequest.dataRequest) {
            long long requestedOffset = loadingRequest.dataRequest.requestedOffset;
            long long requestedLength = loadingRequest.dataRequest.requestedLength;
            request.allHTTPHeaderFields = @{ @"Range" : [NSString stringWithFormat:@"bytes=%lld-%lld", requestedOffset, requestedOffset + requestedLength - 1] };
        } else {
            return NO;
        }

        if (@available(iOS 11, *)) {
            request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        }else {
            request.cachePolicy = [request.HTTPMethod isEqualToString:@"HEAD"] ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringCacheData;
        }

        NSURLSessionDataTask *dataTask = [self.session dataTaskWithRequest:request];
        [dataTask resume];

        if (dataTask) {
            [self.fragDatas addObject:[NSMutableData data]];
            [self.fragDataTasks addObject:dataTask];
            [self.pendingRequests addObject:loadingRequest];
        }

        return YES;
    }

    return NO;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSUInteger index = [self.pendingRequests indexOfObject:loadingRequest];

    if (index == NSNotFound) {
        return;
    }

    // should call delegate task:didCompleteWithError: that would cleanup resources
    [self.fragDataTasks[index] cancel];
}

#pragma mark - NSURLSession delegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSUInteger index = [self.fragDataTasks indexOfObject:dataTask];

    NSParameterAssert(index != NSNotFound);
    if (index == NSNotFound) {
        return;
    }

    AVAssetResourceLoadingRequest *loadingRequest = self.pendingRequests[index];
    loadingRequest.response = response;

    if (loadingRequest.contentInformationRequest) {
        [self fillInContentInformation:loadingRequest.contentInformationRequest fromResponse:response];
        [loadingRequest finishLoading];
        NSURLSessionDataTask *dataTask = self.fragDataTasks[index];
        [self.pendingRequests removeObjectAtIndex:index];
        [self.fragDataTasks removeObjectAtIndex:index];
        [self.fragDatas removeObjectAtIndex:index];
        [dataTask cancel];
    }

    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSUInteger index = [self.fragDataTasks indexOfObject:dataTask];
    NSParameterAssert(index != NSNotFound);
    
    if (index == NSNotFound) return;

    AVAssetResourceLoadingRequest *loadingRequest = self.pendingRequests[index];
    long long requestedOffset = loadingRequest.dataRequest.requestedOffset;
    long long currentOffset = loadingRequest.dataRequest.currentOffset;
    long long length = loadingRequest.dataRequest.requestedLength;

    NSMutableData *mutableData = self.fragDatas[index];
    NSParameterAssert(mutableData.length == currentOffset - requestedOffset);
    
    NSError *error = nil;
    NSInteger statusCode = [(NSHTTPURLResponse *)dataTask.response statusCode];
    if (statusCode < 200 || statusCode >= 400) {
         error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:statusCode
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Server returned failure status code" }];
    }


    if (!error && ![self isRangeOfRequest:dataTask.currentRequest
            equalsToRangeOfResponse:(NSHTTPURLResponse *)dataTask.response
                    requestToTheEnd:loadingRequest.dataRequest.requestsAllDataToEndOfResource]) {
        data = [self subdataFromData:data
                          forRequest:dataTask.currentRequest
                            response:(NSHTTPURLResponse *)dataTask.response
                      loadingRequest:loadingRequest];

        if (!data) {
            error = [NSError errorWithDomain:NSURLErrorDomain
                                        code:NSURLErrorBadServerResponse
                                    userInfo:@{ NSLocalizedDescriptionKey : @"Server returned wrong range of data or empty data" }];
        }
    }
    
    if (error) {
        [loadingRequest finishLoadingWithError:error];
        [dataTask cancel];
        if ([self.delegate respondsToSelector:@selector(dvAssetLoaderDelegate:didRecieveLoadingError:withDataTask:forRequest:)]) {
            [self.delegate dvAssetLoaderDelegate:self didRecieveLoadingError:error withDataTask:dataTask forRequest:loadingRequest];
        }
        return;
    }
    [mutableData appendData:data];

    if (loadingRequest.dataRequest.requestsAllDataToEndOfResource) {
        long long currentDataResponseOffset = currentOffset - requestedOffset;
        long long currentDataResponseLength = mutableData.length - currentDataResponseOffset;
        [loadingRequest.dataRequest respondWithData:[mutableData subdataWithRange:NSMakeRange((NSUInteger)currentDataResponseOffset, (NSUInteger)currentDataResponseLength)]];
    }else if (currentOffset - requestedOffset <= mutableData.length) {
        [loadingRequest.dataRequest respondWithData:[mutableData subdataWithRange:NSMakeRange((NSUInteger)(currentOffset - requestedOffset), (NSUInteger)MIN(mutableData.length - (currentOffset - requestedOffset), length))]];
    }else {
        [loadingRequest finishLoading];
        [self.pendingRequests removeObjectAtIndex:index];
        [self.fragDatas removeObjectAtIndex:index];
        [self.fragDataTasks[index] cancel];
        [self.fragDataTasks removeObjectAtIndex:index];
    }
}

- (BOOL)isRangeOfRequest:(NSURLRequest *)request equalsToRangeOfResponse:(NSHTTPURLResponse *)response requestToTheEnd:(BOOL)requestToTheEnd {
    NSString *requestRange = rangeFromRequest(request);
    NSString *responseRange = rangeFromResponse(response);
    return requestToTheEnd ? [responseRange hasPrefix:requestRange] : [requestRange isEqualToString:responseRange];
}

- (NSData *)subdataFromData:(NSData *)data
                 forRequest:(NSURLRequest *)request
                   response:(NSHTTPURLResponse *)response
             loadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSString *requestRange = rangeFromRequest(request);
    NSString *responseRange = rangeFromResponse(response);

    NSInteger requestFrom = [[[requestRange componentsSeparatedByString:@"-"] firstObject] integerValue];
    NSInteger requestTo = [[[requestRange componentsSeparatedByString:@"-"] lastObject] integerValue];

    NSInteger responseFrom = [[[responseRange componentsSeparatedByString:@"-"] firstObject] integerValue];
    NSInteger responseTo = [[[responseRange componentsSeparatedByString:@"-"] lastObject] integerValue];

    NSParameterAssert(requestFrom >= responseFrom);
    if (requestFrom < responseFrom) {
        return nil;
    }

    NSParameterAssert(requestFrom < responseTo);
    if (requestFrom >= responseTo) {
        return nil;
    }

    NSParameterAssert(data.length > requestFrom - responseFrom);
    if (data.length <= requestFrom - responseFrom) {
        return nil;
    }

    if (loadingRequest.dataRequest.requestsAllDataToEndOfResource) {
        return [data subdataWithRange:NSMakeRange(requestFrom - responseFrom, data.length - (requestFrom - responseFrom))];
    }

    NSParameterAssert(responseTo >= requestTo);
    if (responseTo < requestTo) {
        return nil;
    }

    return [data subdataWithRange:NSMakeRange(requestFrom - responseFrom, requestTo - requestFrom + 1)];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionDataTask *)task didCompleteWithError:(nullable NSError *)error {
    NSUInteger index = [self.fragDataTasks indexOfObject:task];

    if (index == NSNotFound) {
        return;
    }

    AVAssetResourceLoadingRequest *loadingRequest = self.pendingRequests[index];
    if (error) {
        [loadingRequest finishLoadingWithError:error];
    }else {
        [loadingRequest finishLoading];
    }

    NSMutableData *loadedData = self.fragDatas[index];
    long long requestedOffset = loadingRequest.dataRequest.requestedOffset;
    NSUInteger length = [loadedData length];
    long long fullLength = [[(NSHTTPURLResponse *)task.response allHeaderFields][@"Content-Range"] componentsSeparatedByString:@"/"].lastObject.longLongValue;
    NSString *mimeType = [(NSHTTPURLResponse *)task.response allHeaderFields][@"Content-Type"];
    [self processData:loadedData forOffset:requestedOffset length:length fullLength:fullLength mimeType:mimeType];

    [self.pendingRequests removeObjectAtIndex:index];
    [self.fragDatas removeObjectAtIndex:index];
    [self.fragDataTasks removeObjectAtIndex:index];

    BOOL isCancelledError = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    BOOL isNetworkError = [error.domain isEqualToString:NSURLErrorDomain] && error.code != NSURLErrorCancelled;
    BOOL isDelegateRespondsToSelector = [self.delegate respondsToSelector:@selector(dvAssetLoaderDelegate:didRecieveLoadingError:withDataTask:forRequest:)];
    
    if (error && !isCancelledError && !isNetworkError && isDelegateRespondsToSelector) {
        [self.delegate dvAssetLoaderDelegate:self didRecieveLoadingError:error withDataTask:task forRequest:loadingRequest];
    }
    
    if (error && isNetworkError) {
        self.networkError = [DVAssetLoaderError loaderErrorWithError:error];
    }
}

#pragma mark - Downloaded data processing

- (void)fillInContentInformation:(AVAssetResourceLoadingContentInformationRequest *)contentInformationRequest fromResponse:(NSURLResponse *)response {
    NSString *mimeType = [response MIMEType];
    CFStringRef contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)(mimeType), NULL);

    contentInformationRequest.contentType = CFBridgingRelease(contentType);

    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    contentInformationRequest.byteRangeAccessSupported = [httpResponse.allHeaderFields[@"Accept-Ranges"] isEqualToString:@"bytes"];

    NSString *contentRange = httpResponse.allHeaderFields[@"Content-Range"];
    if (!contentRange) {
        contentInformationRequest.contentLength = [response expectedContentLength];
    }
    else {
        contentInformationRequest.contentLength = [contentRange componentsSeparatedByString:@"/"].lastObject.longLongValue;
    }
}

- (void)processData:(NSData *)data forOffset:(long long)offset length:(NSUInteger)length fullLength:(long long)fullLength mimeType:(NSString *)mimeType {
    if (fullLength == 0 || fullLength > 110 * 1024 * 1024 || length == 0) return;
    
    if (_cacheFileTmpPath != nil) {
        NSString *fragFileName = [[NSUUID UUID] UUIDString];
        NSString *fragFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fragFileName];
        [[NSFileManager defaultManager] createFileAtPath:fragFilePath contents:data attributes:nil];
        
        NSRange currentRange = NSMakeRange((NSUInteger)offset, length);
        NSValue *currentRangeValue = [NSValue valueWithRange:currentRange];
        _fragDataPathDictionary[currentRangeValue] = fragFilePath;
        
        __block NSMutableDictionary<NSValue *, NSString *> *datasCache = [NSMutableDictionary dictionaryWithDictionary:_fragDataPathDictionary];
        __block long long tFullLength = fullLength;
        __block NSString *cacheFileTmpPath = _cacheFileTmpPath;
        __block NSString *cacheFilePath = _cacheFilePath;
        dispatch_queue_t queue = dispatch_queue_create("com.fanbook.concated_data", DISPATCH_QUEUE_CONCURRENT);
        dispatch_async(queue, ^{
            NSString *dataPath = concatedDataFromRanges(datasCache, tFullLength);
            if (dataPath && [[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
                NSFileHandle *writeHandle = [NSFileHandle fileHandleForWritingAtPath:cacheFileTmpPath];
                [writeHandle seekToEndOfFile];
                NSFileHandle *readHandle = [NSFileHandle fileHandleForReadingAtPath:dataPath];
                NSData *data = [readHandle readDataOfLength:1024 * 1024];
                while (data && [data length] > 0) {
                    [writeHandle writeData:data];
                    data = [readHandle readDataOfLength:1024 * 1024];
                }
                [readHandle closeFile];
                [writeHandle closeFile];
                [[NSFileManager defaultManager] removeItemAtPath:dataPath error:nil];
                if ([[NSFileManager defaultManager] fileExistsAtPath:cacheFilePath]) {
                    [[NSFileManager defaultManager] removeItemAtPath:cacheFilePath error:nil];
                }
                NSError *error;
                [[NSFileManager defaultManager] moveItemAtPath:cacheFileTmpPath toPath:cacheFilePath error:&error];
                [datasCache removeAllObjects];
            }
        });
    }
}

#pragma mark - Helpers
- (NSURL *)urlForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *interceptedURL = [loadingRequest.request URL];
    return [self fixedURLFromURL:interceptedURL];
}

- (NSURL *)fixedURLFromURL:(NSURL *)url {
    NSURLComponents *actualURLComponents = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
    actualURLComponents.scheme = self.originalScheme;
    return [actualURLComponents URL];
}

BOOL isNetworkReachable() {
    BOOL success = false;
    const char *host_name = [@"example.com" cStringUsingEncoding:NSASCIIStringEncoding];
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, host_name);
    SCNetworkReachabilityFlags flags;
    success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    BOOL isAvailable = success && (flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired);
    return isAvailable;
}

@end
