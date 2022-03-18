// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#define weakify(var) __weak typeof(var) weakSelf = var;
#define strongify(var) \
_Pragma("clang diagnostic push") \
_Pragma("clang diagnostic ignored \"-Wshadow\"") \
__strong typeof(var) var = weakSelf ; \
_Pragma("clang diagnostic pop")


#import "FLTVideoPlayerPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <GLKit/GLKit.h>
#import "messages.h"
#import "DVURLAsset.h"
#import "Reachability.h"
#import <KTVHTTPCache/KTVHTTPCache.h>
#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif

int64_t FLTCMTimeToMillis(CMTime time) {
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

@interface FLTFrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, weak, readonly) NSObject<FlutterTextureRegistry>* registry;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation FLTFrameUpdater
- (FLTFrameUpdater*)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry {
  NSAssert(self, @"super init cannot be nil");
  if (self == nil) return nil;
  _registry = registry;
  return self;
}

- (void)onDisplayLink:(CADisplayLink*)link {
  [_registry textureFrameAvailable:_textureId];
}
@end

@interface FLTVideoPlayer : NSObject <FlutterTexture, FlutterStreamHandler>
{
    id _timeObserver;
    
    id _itemEndObserver;
    id _itemFailedObserver;
    id _itemStalledObserver;
}
@property(readonly, nonatomic) AVPlayer* player;
@property(readonly, nonatomic) AVPlayerItemVideoOutput* videoOutput;
@property(readonly, nonatomic) CADisplayLink* displayLink;
@property(nonatomic) FlutterEventChannel* eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic, readonly) bool disposed;
@property(nonatomic, readonly) bool isPlaying;
@property(nonatomic) bool isLooping;
@property(nonatomic, readonly) bool isInitialized;
@property (nonatomic, assign) BOOL isBuffering;
@property (nonatomic, assign) BOOL isReadyToPlay;

- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater;
- (void)play;
- (void)pause;
- (void)setIsLooping:(bool)isLooping;
- (void)updatePlayingState;

@property(nonatomic) CGSize renderSize;
@end

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;
static void* presentationSizeContext = &presentationSizeContext;
static void *durationContext = &durationContext;

@implementation FLTVideoPlayer
- (instancetype)initWithAsset:(NSString*)asset frameUpdater:(FLTFrameUpdater*)frameUpdater {
  NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
  return [self initWithURL:[NSURL fileURLWithPath:path] frameUpdater:frameUpdater];
}

- (void)addObservers:(AVPlayerItem*)item {
    [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
    [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
    [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];
    [item addObserver:self
         forKeyPath:@"playbackBufferEmpty"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferEmptyContext];
    [item addObserver:self
         forKeyPath:@"playbackBufferFull"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferFullContext];
    [item addObserver:self
           forKeyPath:@"presentationSize"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:presentationSizeContext];
    [item addObserver:self
           forKeyPath:@"duration"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:durationContext];
    
    weakify(self);
    //播放结束通知
    _itemEndObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        strongify(self);
        if (!self) return;
        if (self.isLooping) {
            AVPlayerItem* p = [note object];
            [p seekToTime:kCMTimeZero completionHandler:nil];
        } else {
            [self notifyEventSink:@{@"event" : @"completed"}];
        }
    }];
    //播放失败
    _itemFailedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        strongify(self);
        if (!self) return;
        NSError * error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
        NSLog(@"AVPlayerItemFailedToPlayToEndTimeNotification:播放失败 %@",error);
    }];
    
    //异常中断 当发生卡顿
    _itemStalledObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemPlaybackStalledNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        strongify(self);
        if (!self) return;
        NSLog(@"AVPlayerItemPlaybackStalledNotification:异常中断 %@", note);
        if (self.isPlaying) [self.player play];
    }];
}

static inline CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360[
  return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
    AVMutableVideoCompositionInstruction* instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
    AVMutableVideoCompositionLayerInstruction* layerInstruction = [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    //获取视频方向
    NSInteger rotationDegrees =
          (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
    CGFloat width = videoTrack.naturalSize.width;
    CGFloat height = videoTrack.naturalSize.height;

    if (rotationDegrees == 90 || rotationDegrees == 270) {
        //视频90/270 修改画面宽高
        width = videoTrack.naturalSize.height;
        height = videoTrack.naturalSize.width;
        [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];
    }else if(rotationDegrees == 180){
        //视频180，修正画面
        CGAffineTransform rotateTransform = CGAffineTransformMakeRotation(M_PI);
        CGAffineTransform translateTransform = CGAffineTransformMakeTranslation(width, height);
        [layerInstruction setTransform:CGAffineTransformConcat(rotateTransform, translateTransform) atTime:kCMTimeZero];
    }else{
        [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];
    }
   
    AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
    instruction.layerInstructions = @[ layerInstruction ];
    videoComposition.instructions = @[ instruction ];
  
    videoComposition.renderSize = CGSizeMake(width, height);
    _renderSize = videoComposition.renderSize;  //[dj]:[ID1090896]

  // TODO(@recastrodiaz): should we use videoTrack.nominalFrameRate ?
  // Currently set at a constant 30 FPS
    videoComposition.frameDuration = CMTimeMake(1, 30);
    return videoComposition;
}

- (void)createVideoOutputAndDisplayLink:(FLTFrameUpdater*)frameUpdater {
  NSDictionary* pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
    
   _displayLink = [CADisplayLink displayLinkWithTarget:frameUpdater
                                             selector:@selector(onDisplayLink:)];
  [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  _displayLink.paused = YES;
}

- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater {
    if (url != nil && [url pathExtension] != nil && [[url scheme] hasPrefix:@"http"] && [[[url pathExtension] lowercaseString] isEqualToString:@"cachevideo"] && [self canCacheVideo] && KTVHTTPCache.proxyIsRunning) {
        NSString *urlString = [url absoluteString];
        urlString = [urlString substringToIndex:[urlString rangeOfComposedCharacterSequenceAtIndex:[urlString length] - [@".cachevideo" length]].location];
        url = [NSURL URLWithString:urlString];
        NSURL *proxyURL = [KTVHTTPCache proxyURLWithOriginalURL:url];
            
        AVPlayerItem* item = [AVPlayerItem playerItemWithURL:proxyURL];
        return [self initWithPlayerItem:item frameUpdater:frameUpdater];
    }
    
    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:url];
    return [self initWithPlayerItem:item frameUpdater:frameUpdater];
}

-(BOOL)canCacheVideo {
    NSError *error = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[paths lastObject] error: &error];
    
    if (dictionary && error == nil) {
        NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];
        return freeFileSystemSizeInBytes != nil && (freeFileSystemSizeInBytes.longLongValue / 1024 / 1024 > 300);
    } else {
        return false;
    }
    return false;
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform Setting tx to the height of the video instead of 0, properly
  // displays the video https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
//    if ((transform.tx == 0 || fabs(transform.tx - 640) < 5) && (transform.ty == 0 || fabs(transform.ty - 640) < 5)) {
    NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
    NSLog(@"TX and TY are 0. Rotation: %ld. Natural width,height: %f, %f", (long)rotationDegrees,
          videoTrack.naturalSize.width, videoTrack.naturalSize.height);
    if (rotationDegrees == 90) {
      NSLog(@"Setting transform tx");
      transform.tx = videoTrack.naturalSize.height;
      transform.ty = 0;
    } else if (rotationDegrees == 270) {
      NSLog(@"Setting transform ty");
      transform.tx = 0;
      transform.ty = videoTrack.naturalSize.width;
    }
//  }
  return transform;
}

- (instancetype)initWithPlayerItem:(AVPlayerItem*)item frameUpdater:(FLTFrameUpdater*)frameUpdater {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;

    _player = [AVPlayer playerWithPlayerItem:item];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    if (@available(iOS 9.0, *)) {
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = NO;
    }
    if (@available(iOS 10.0, *)) {
        item.preferredForwardBufferDuration = 1;
        _player.automaticallyWaitsToMinimizeStalling = YES;
    }
    
    [self createVideoOutputAndDisplayLink:frameUpdater];
    [self addObservers:item];
    [self listenTracks];
    return self;
}

-(void)listenTracks{
    weakify(self);
    [[self.player.currentItem asset] loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^(){
        strongify(self);
        NSError *error = nil;
        AVKeyValueStatus status = [self.player.currentItem.asset statusOfValueForKey:@"tracks" error:&error];
        if(error) return;
        
        if (status == AVKeyValueStatusLoaded) {
            NSArray* tracks = [self.player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] > 0) {
                AVAssetTrack* videoTrack = tracks[0];
                weakify(self);
                [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                      completionHandler:^(){
                strongify(self);
                if (self->_disposed) return;
                if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                              error:nil] == AVKeyValueStatusLoaded) {
                    // Rotate the video by using a videoComposition and the preferredTransform
                    self->_preferredTransform = [self fixTransform:videoTrack];
                    // Note:
                    // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
                    // Video composition can only be used with file-based media and is not supported for
                    // use with media served using HTTP Live Streaming.
                    AVMutableVideoComposition* videoComposition = [self getVideoCompositionWithTransform:self->_preferredTransform
                                                   withAsset:[self.player.currentItem asset]
                                              withVideoTrack:videoTrack];
                    self.player.currentItem.videoComposition = videoComposition;
                }
            }];
          }
        }else if (status == AVKeyValueStatusFailed) {
            
        }
    }];
}

-(void)notifyEventSink:(id)content{
    if(!_eventSink) return;
    _eventSink(content);
}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
      for (NSValue* rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FLTCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FLTCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem* item = (AVPlayerItem*)object;
    switch (item.status) {
        case AVPlayerItemStatusFailed:{
        //资源不合规https://developer.apple.com/documentation/foundation/1508628-url_loading_system_error_codes/nsurlerrornopermissionstoreadfile
        NSInteger code = item.error.code;
        [self notifyEventSink:[FlutterError
                               errorWithCode: code == -1102 ? @"403" : @"VideoError"
                               message:[@"Failed to load video: "stringByAppendingString:[item.error localizedDescription]]
                               details:@{@"code": @(code)}]];
        }
        break;
      case AVPlayerItemStatusUnknown:
        break;
      case AVPlayerItemStatusReadyToPlay:
        [item addOutput:_videoOutput];
        [self sendInitialized];
        [self updatePlayingState];
        break;
    }
  } else if (context == playbackLikelyToKeepUpContext) {
      // When the buffer is good
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
        [self updatePlayingState];
        [self notifyEventSink:@{@"event" : @"bufferingEnd"} ];
    }
  } else if (context == playbackBufferEmptyContext) {
      // When the buffer is empty
      [self notifyEventSink: @{@"event" : @"bufferingStart"}];
  } else if (context == playbackBufferFullContext) {
      [self notifyEventSink:@{@"event" : @"bufferingEnd"}];
  } else if (context == presentationSizeContext || context == durationContext) {
      AVPlayerItem *item = (AVPlayerItem *)object;
      if (item.status == AVPlayerItemStatusReadyToPlay) {
        // Due to an apparent bug, when the player item is ready, it still may not have determined
        // its presentation size or duration. When these properties are finally set, re-check if
        // all required properties and instantiate the event sink if it is not already set up.
        [self sendInitialized];
        [self updatePlayingState];
      }
    } else {
      [super observeValueForKeyPath:path ofObject:object change:change context:context];
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
      [_player play];
  } else {
    [_player pause];
  }
  _displayLink.paused = !_isPlaying;
}

- (void)sendInitialized {
//  if (_eventSink && !_isInitialized) {
//    CGSize size = [self.player currentItem].presentationSize;
    NSString *url = @"";
    if (_player && [_player currentItem] && [[_player currentItem] asset] && [[[_player currentItem] asset] isKindOfClass:[AVURLAsset class]]) {
        AVURLAsset *urlAsset = (AVURLAsset *)[[_player currentItem] asset];
        if ([urlAsset URL]) {
            url = [[(AVURLAsset *)[[_player currentItem] asset] URL] absoluteString];
        }
    }
    if ([[url lowercaseString] containsString:@".m3u8"] && _eventSink && !_isInitialized) {
        CGSize size = _renderSize;
        
        CGFloat width = size.width;
        CGFloat height = size.height;
        int64_t duration = [self duration] <= 0 ? 1 : [self duration];

        _isInitialized = true;
        _eventSink(@{
          @"event" : @"initialized",
          @"duration" : @(duration),
          @"width" : @(width),
          @"height" : @(height)
        });
        return;
    }
    
    if (_eventSink && !_isInitialized && !CGSizeEqualToSize(_renderSize, CGSizeZero)) { //
        CGSize size = _renderSize;
          
        CGFloat width = size.width;
        CGFloat height = size.height;

        // The player has not yet initialized.
        if (height == CGSizeZero.height && width == CGSizeZero.width) {
          return;
        }

        _isInitialized = true;
        _eventSink(@{
          @"event" : @"initialized",
          @"duration" : @([self duration]),
          @"width" : @(width),
          @"height" : @(height)
        });
    }
}

- (void)play {
  _isPlaying = true;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = false;
  [self updatePlayingState];
}

- (int64_t)position {
  return FLTCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
    if ([_player currentItem] == nil) return 0;
    CMTime t = [[_player currentItem] duration];
    if ((t.flags & kCMTimeFlags_ImpliedValueFlagsMask) > 0) {
        return ([[_player currentItem] asset] != nil) ? FLTCMTimeToMillis([[[_player currentItem] asset] duration]) : 0;
    }else {
        return FLTCMTimeToMillis([[_player currentItem] duration]);
    }
}

- (void)seekTo:(int)location {
  [_player seekToTime:CMTimeMake(location, 1000)
      toleranceBefore:kCMTimeZero
       toleranceAfter:kCMTimeZero];
}

- (void)setIsLooping:(bool)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed {
  // See https://developer.apple.com/library/archive/qa/qa1772/_index.html for an explanation of
  // these checks.
  if (speed > 2.0 && !_player.currentItem.canPlayFastForward) {
    if (_eventSink != nil) {
      _eventSink([FlutterError errorWithCode:@"VideoError"
                                     message:@"Video cannot be fast-forwarded beyond 2.0x"
                                     details:nil]);
    }
    return;
  }

  if (speed < 1.0 && !_player.currentItem.canPlaySlowForward) {
    if (_eventSink != nil) {
      _eventSink([FlutterError errorWithCode:@"VideoError"
                                     message:@"Video cannot be slow-forwarded"
                                     details:nil]);
    }
    return;
  }

  _player.rate = speed;
}

- (CVPixelBufferRef)copyPixelBuffer {
  CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    return [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
  } else {
    return NULL;
  }
}

- (void)onTextureUnregistered {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self dispose];
  });
}

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
  // https://github.com/flutter/flutter/issues/21483
  // This line ensures the 'initialized' event is sent when the event
  // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
  // onListenWithArguments is called)
  [self sendInitialized];
    
   
  return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
    _disposed = true;
    [_displayLink invalidate];
    AVPlayerItem *currentItem = self.player.currentItem;
    [currentItem removeObserver:self forKeyPath:@"status" context:statusContext];
    [currentItem removeObserver:self forKeyPath:@"loadedTimeRanges" context:timeRangeContext];
    [currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:playbackLikelyToKeepUpContext];
    [currentItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:playbackBufferEmptyContext];
    [currentItem removeObserver:self forKeyPath:@"playbackBufferFull" context:playbackBufferFullContext];
    [currentItem removeObserver:self forKeyPath:@"presentationSize" context:presentationSizeContext];
    [currentItem removeObserver:self forKeyPath:@"duration" context:durationContext];
    
    [[NSNotificationCenter defaultCenter] removeObserver:_itemEndObserver name:AVPlayerItemDidPlayToEndTimeNotification object:currentItem];
    _itemEndObserver = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:_itemFailedObserver name:AVPlayerItemFailedToPlayToEndTimeNotification object:currentItem];
    _itemFailedObserver = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:_itemStalledObserver name:AVPlayerItemPlaybackStalledNotification object:currentItem];
    _itemStalledObserver = nil;
    
    [_player replaceCurrentItemWithPlayerItem:nil];
}

- (void)dispose {
  [self disposeSansEventChannel];
  [_eventChannel setStreamHandler:nil];
}

@end

@interface FLTVideoPlayerPlugin () <FLTVideoPlayerApi>
@property(readonly, weak, nonatomic) NSObject<FlutterTextureRegistry>* registry;
@property(readonly, weak, nonatomic) NSObject<FlutterBinaryMessenger>* messenger;
@property(readonly, strong, nonatomic) NSMutableDictionary* players;
@property(readonly, strong, nonatomic) NSObject<FlutterPluginRegistrar>* registrar;
@end

@implementation FLTVideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FLTVideoPlayerPlugin* instance = [[FLTVideoPlayerPlugin alloc] initWithRegistrar:registrar];
  [registrar publish:instance];
  FLTVideoPlayerApiSetup(registrar.messenger, instance);
  [instance setupHTTPCache];
}

- (void)configHTTPCache {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self setupHTTPCache];
    });
}

- (void)setupHTTPCache {
    [KTVHTTPCache logSetConsoleLogEnable:NO];
    NSError *error = nil;
    [KTVHTTPCache proxyStart:&error];
    if (error) {
        NSLog(@"Proxy Start Failure, %@", error);
    } else {
        //NSLog(@"Proxy Start Success");
    }
    [KTVHTTPCache encodeSetURLConverter:^NSURL *(NSURL *URL) {
        //NSLog(@"URL Filter reviced URL : %@", URL);
        return URL;
    }];
    [KTVHTTPCache downloadSetUnacceptableContentTypeDisposer:^BOOL(NSURL *URL, NSString *contentType) {
        //NSLog(@"Unsupport Content-Type Filter reviced URL : %@, %@", URL, contentType);
        return NO;
    }];
    [KTVHTTPCache cacheSetMaxCacheLength:2000 * 1024 * 1024];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [registrar textures];
  _messenger = [registrar messenger];
  _registrar = registrar;
  _players = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  for (NSNumber* textureId in _players.allKeys) {
    FLTVideoPlayer* player = _players[textureId];
    [player disposeSansEventChannel];
  }
  [_players removeAllObjects];
  // TODO(57151): This should be commented out when 57151's fix lands on stable.
  // This is the correct behavior we never did it in the past and the engine
  // doesn't currently support it.
  // FLTVideoPlayerApiSetup(registrar.messenger, nil);
}

- (FLTTextureMessage*)onPlayerSetup:(FLTVideoPlayer*)player
                       frameUpdater:(FLTFrameUpdater*)frameUpdater {
  int64_t textureId = [_registry registerTexture:player];
  frameUpdater.textureId = textureId;
  FlutterEventChannel* eventChannel = [FlutterEventChannel
      eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                      textureId]
           binaryMessenger:_messenger];
  [eventChannel setStreamHandler:player];
  player.eventChannel = eventChannel;
  _players[@(textureId)] = player;
  FLTTextureMessage* result = [[FLTTextureMessage alloc] init];
  result.textureId = @(textureId);
  return result;
}

- (void)initialize:(FlutterError* __autoreleasing*)error {
  // Allow audio playback when the Ring/Silent switch is set to silent
  [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];

  for (NSNumber* textureId in _players) {
    [_registry unregisterTexture:[textureId unsignedIntegerValue]];
    [_players[textureId] dispose];
  }
  [_players removeAllObjects];
}

- (FLTTextureMessage*)create:(FLTCreateMessage*)input error:(FlutterError**)error {
  FLTFrameUpdater* frameUpdater = [[FLTFrameUpdater alloc] initWithRegistry:_registry];
  FLTVideoPlayer* player;
  if (input.asset) {
    NSString* assetPath;
    if (input.packageName) {
      assetPath = [_registrar lookupKeyForAsset:input.asset fromPackage:input.packageName];
    } else {
      assetPath = [_registrar lookupKeyForAsset:input.asset];
    }
    player = [[FLTVideoPlayer alloc] initWithAsset:assetPath frameUpdater:frameUpdater];
    return [self onPlayerSetup:player frameUpdater:frameUpdater];
  } else if (input.uri) {
      NSString * uri = [[NSString alloc] initWithString:input.uri];
      uri = [uri stringByAddingPercentEncodingWithAllowedCharacters: [NSCharacterSet URLQueryAllowedCharacterSet]];
    player = [[FLTVideoPlayer alloc] initWithURL:[NSURL URLWithString:uri]
                                    frameUpdater:frameUpdater];
    return [self onPlayerSetup:player frameUpdater:frameUpdater];
  } else {
    *error = [FlutterError errorWithCode:@"video_player" message:@"not implemented" details:nil];
    return nil;
  }
}

- (void)dispose:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [_registry unregisterTexture:input.textureId.intValue];
  [_players removeObjectForKey:input.textureId];
  // If the Flutter contains https://github.com/flutter/engine/pull/12695,
  // the `player` is disposed via `onTextureUnregistered` at the right time.
  // Without https://github.com/flutter/engine/pull/12695, there is no guarantee that the
  // texture has completed the un-reregistration. It may leads a crash if we dispose the
  // `player` before the texture is unregistered. We add a dispatch_after hack to make sure the
  // texture is unregistered before we dispose the `player`.
  //
  // TODO(cyanglaz): Remove this dispatch block when
  // https://github.com/flutter/flutter/commit/8159a9906095efc9af8b223f5e232cb63542ad0b is in
  // stable And update the min flutter version of the plugin to the stable version.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (!player.disposed) {
                     [player dispose];
                   }
                 });
}

- (void)setLooping:(FLTLoopingMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player setIsLooping:[input.isLooping boolValue]];
}

- (void)setVolume:(FLTVolumeMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player setVolume:[input.volume doubleValue]];
}

- (void)setPlaybackSpeed:(FLTPlaybackSpeedMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player setPlaybackSpeed:[input.speed doubleValue]];
}

- (void)play:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player play];
}

- (FLTPositionMessage*)position:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  FLTPositionMessage* result = [[FLTPositionMessage alloc] init];
  result.position = @([player position]);
  return result;
}

- (void)seekTo:(FLTPositionMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player seekTo:[input.position intValue]];
}

- (void)pause:(FLTTextureMessage*)input error:(FlutterError**)error {
  FLTVideoPlayer* player = _players[input.textureId];
  [player pause];
}

- (void)setMixWithOthers:(FLTMixWithOthersMessage*)input
                   error:(FlutterError* _Nullable __autoreleasing*)error {
  if ([input.mixWithOthers boolValue]) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
}

@end
