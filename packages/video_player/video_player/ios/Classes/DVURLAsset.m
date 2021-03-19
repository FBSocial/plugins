//
//  DVURLAsset.m
//  DVAssetLoaderDelegate
//
//  Created by Vladislav Dugnist on 07/01/2018.
//

#import "DVURLAsset.h"
#import "DVAssetLoaderDelegate.h"

static NSTimeInterval const kDefaultLoadingTimeout = 15;

@interface DVURLAsset()

@property (nonatomic, readonly) DVAssetLoaderDelegate *resourceLoaderDelegate;

@end

@implementation DVURLAsset

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *,id> *)options {
    return [self initWithURL:URL options:options networkTimeout:kDefaultLoadingTimeout];
}

- (instancetype)initWithURL:(NSURL *)url
                    options:(NSDictionary<NSString *,id> *)options
             networkTimeout:(NSTimeInterval)networkTimeout {
    NSParameterAssert(![url isFileURL]);
    if ([url isFileURL]) {
        return [super initWithURL:url options:options];
    }
    
    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = [DVAssetLoaderDelegate scheme];
    
    if (self = [super initWithURL:[components URL] options:options]) {
        DVAssetLoaderDelegate *resourceLoaderDelegate = [[DVAssetLoaderDelegate alloc] initWithURL:url cachedPath:[DVURLAsset cachedFilePath:url] fileName:[DVURLAsset cachedFileName:url]];
        resourceLoaderDelegate.networkTimeout = networkTimeout;
        [self.resourceLoader setDelegate:resourceLoaderDelegate queue:dispatch_get_main_queue()];
    }
    
    return self;
}

- (void)setLoaderDelegate:(NSObject<DVAssetLoaderDelegatesDelegate> *)loaderDelegate {
    self.resourceLoaderDelegate.delegate = loaderDelegate;
}

- (NSObject<DVAssetLoaderDelegatesDelegate> *)loaderDelegate {
    return self.resourceLoaderDelegate.delegate;
}

- (DVAssetLoaderDelegate *)resourceLoaderDelegate {
    if ([self.resourceLoader.delegate isKindOfClass:[DVAssetLoaderDelegate class]]) {
        return (DVAssetLoaderDelegate *)self.resourceLoader.delegate;
    }
    return nil;
}

- (void)dealloc {
    [self.resourceLoaderDelegate cancelRequests];
}


+ (NSString *) cachedFileName:(NSURL *) url {
    return [[self md5:[url absoluteString]] stringByAppendingPathExtension:[url pathExtension]];
}

+ (NSString *) cachedFilePath:(NSURL *) url {
    NSString *fileName = [[self md5:[url absoluteString]] stringByAppendingPathExtension:[url pathExtension]];
    NSString *cache = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"video"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cache]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return [cache stringByAppendingPathComponent:fileName];
}

+ (BOOL) isCached:(NSURL *) url {
    NSString *fileName = [[self md5:[url absoluteString]] stringByAppendingPathExtension:[url pathExtension]];
    NSString *cache = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"video"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cache]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *cachePath = [cache stringByAppendingPathComponent:fileName];
    return [[NSFileManager defaultManager] fileExistsAtPath:cachePath];
}


+ (NSString *) md5:(NSString *) input {
    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5( cStr, strlen(cStr), digest ); // This is the md5 call
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
     [output appendFormat:@"%02x", digest[i]];
    return  output;
}

@end
