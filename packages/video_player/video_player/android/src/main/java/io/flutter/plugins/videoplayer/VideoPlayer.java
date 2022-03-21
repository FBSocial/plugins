// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static com.google.android.exoplayer2.Player.REPEAT_MODE_ALL;
import static com.google.android.exoplayer2.Player.REPEAT_MODE_OFF;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;

import com.danikula.videocache.CacheListener;
import com.danikula.videocache.HttpProxyCacheServer;
import com.danikula.videocache.ProxyCacheException;
import com.google.android.exoplayer2.C;
import com.google.android.exoplayer2.ExoPlaybackException;
import com.google.android.exoplayer2.Format;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.PlaybackParameters;
import com.google.android.exoplayer2.Player;
import com.google.android.exoplayer2.Player.Listener;
import com.google.android.exoplayer2.SimpleExoPlayer;
import com.google.android.exoplayer2.audio.AudioAttributes;
import com.google.android.exoplayer2.source.MediaSource;
import com.google.android.exoplayer2.source.ProgressiveMediaSource;
import com.google.android.exoplayer2.source.dash.DashMediaSource;
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource;
import com.google.android.exoplayer2.source.hls.HlsMediaSource;
import com.google.android.exoplayer2.source.smoothstreaming.DefaultSsChunkSource;
import com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource;
import com.google.android.exoplayer2.upstream.DataSource;
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory;
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource;
import com.google.android.exoplayer2.upstream.DefaultLoadErrorHandlingPolicy;
import com.google.android.exoplayer2.upstream.HttpDataSource;
import com.google.android.exoplayer2.util.Util;

import io.flutter.plugin.common.EventChannel;
import io.flutter.view.TextureRegistry;

import java.io.File;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class NetLoadErrorPolicy
        extends DefaultLoadErrorHandlingPolicy {
  @Override
  public long getRetryDelayMsFor(LoadErrorInfo loadErrorInfo) {
    // 网络错误，每隔6秒重试一次
    if(loadErrorInfo.exception instanceof HttpDataSource.HttpDataSourceException){
      return 6000;
    }else{
      return  C.TIME_UNSET;
    }
  }

  @Override
  public int getMinimumLoadableRetryCount(int dataType) {
    return Integer.MAX_VALUE;
  }
}

final class VideoPlayer implements CacheListener {
  private static final String FORMAT_SS = "ss";
  private static final String FORMAT_DASH = "dash";
  private static final String FORMAT_HLS = "hls";
  private static final String FORMAT_OTHER = "other";

  private SimpleExoPlayer exoPlayer;

  private Surface surface;

  private final TextureRegistry.SurfaceTextureEntry textureEntry;

  private QueuingEventSink eventSink = new QueuingEventSink();

  private final EventChannel eventChannel;

  private boolean isInitialized = false;

  private final VideoPlayerOptions options;

  private HttpProxyCacheServer proxyCacheServer;

  private HashMap<String, String> urlForbidenErrorMap = new HashMap<>();

  private String dataSource;

  private Handler mainHandler = new Handler(Looper.getMainLooper());
  private Runnable accessForbidenRunnable = new Runnable() {
    @Override
    public void run() {
        if (eventSink != null) eventSink.error("403", "Video player had error ", null);
    }
  };

  VideoPlayer(
      Context context,
      EventChannel eventChannel,
      TextureRegistry.SurfaceTextureEntry textureEntry,
      String dataSource,
      String formatHint,
      Map<String, String> httpHeaders,
      VideoPlayerOptions options,
      HttpProxyCacheServer proxyCacheServer) {
    this.eventChannel = eventChannel;
    this.textureEntry = textureEntry;
    this.options = options;
    this.proxyCacheServer = proxyCacheServer;

    String proxyUrl;
    if (dataSource.endsWith(".cachevideo")) {
      dataSource = dataSource.substring(0, dataSource.length() - ".cachevideo".length());
      this.dataSource = dataSource;
      if (proxyCacheServer.canCache()) {
        proxyCacheServer.registerCacheListener(this, dataSource);
        proxyUrl = proxyCacheServer.getProxyUrl(dataSource);
      }else {
        proxyUrl = dataSource;
      }
    }else {
      this.dataSource = dataSource;
      proxyUrl = dataSource;
    }

    exoPlayer = new SimpleExoPlayer.Builder(context).build();

    Uri uri = Uri.parse(proxyUrl);

    DataSource.Factory dataSourceFactory;
    if (isHTTP(uri)) {
      DefaultHttpDataSource.Factory httpDataSourceFactory =
          new DefaultHttpDataSource.Factory()
              .setUserAgent("ExoPlayer")
              .setAllowCrossProtocolRedirects(true);

      if (httpHeaders != null && !httpHeaders.isEmpty()) {
        httpDataSourceFactory.setDefaultRequestProperties(httpHeaders);
      }
      dataSourceFactory = httpDataSourceFactory;
    } else {
      dataSourceFactory = new DefaultDataSourceFactory(context, "ExoPlayer");
    }

    MediaSource mediaSource = buildMediaSource(uri, dataSourceFactory, formatHint, context);
    exoPlayer.setMediaSource(mediaSource);
    exoPlayer.prepare();

    setupVideoPlayer(eventChannel, textureEntry);
  }

  private static boolean isHTTP(Uri uri) {
    if (uri == null || uri.getScheme() == null) {
      return false;
    }
    String scheme = uri.getScheme();
    return scheme.equals("http") || scheme.equals("https");
  }

  private MediaSource buildMediaSource(
      Uri uri, DataSource.Factory mediaDataSourceFactory, String formatHint, Context context) {
    int type;
    if (formatHint == null) {
      type = Util.inferContentType(uri.getLastPathSegment());
    } else {
      switch (formatHint) {
        case FORMAT_SS:
          type = C.TYPE_SS;
          break;
        case FORMAT_DASH:
          type = C.TYPE_DASH;
          break;
        case FORMAT_HLS:
          type = C.TYPE_HLS;
          break;
        case FORMAT_OTHER:
          type = C.TYPE_OTHER;
          break;
        default:
          type = -1;
          break;
      }
    }
    switch (type) {
      case C.TYPE_SS:
        return new SsMediaSource.Factory(
                new DefaultSsChunkSource.Factory(mediaDataSourceFactory),
                new DefaultDataSourceFactory(context, null, mediaDataSourceFactory))
            .createMediaSource(MediaItem.fromUri(uri));
      case C.TYPE_DASH:
        return new DashMediaSource.Factory(
                new DefaultDashChunkSource.Factory(mediaDataSourceFactory),
                new DefaultDataSourceFactory(context, null, mediaDataSourceFactory))
            .createMediaSource(MediaItem.fromUri(uri));
      case C.TYPE_HLS:
        return new HlsMediaSource.Factory(mediaDataSourceFactory)
            .createMediaSource(MediaItem.fromUri(uri));
      case C.TYPE_OTHER:
        return new ProgressiveMediaSource.Factory(mediaDataSourceFactory)
                .setLoadErrorHandlingPolicy(new NetLoadErrorPolicy())
            .createMediaSource(MediaItem.fromUri(uri));
      default:
        {
          throw new IllegalStateException("Unsupported type: " + type);
        }
    }
  }

  void checkMediaAccess(String url) {
    new Thread(new Runnable() {
      @Override
      public void run() {
        if (fetchUrlResultCode(url) == 403) mainHandler.post(accessForbidenRunnable);
      }
    }).start();
  }

  int fetchUrlResultCode(String url) {
    int resultCode = 200;
    try {
      HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
      connection.setRequestMethod("GET");
      connection.connect();
      resultCode = connection.getResponseCode();
    }catch (Exception e) {
      e.printStackTrace();
    }
    return resultCode;
  }

  private void setupVideoPlayer(
      EventChannel eventChannel, TextureRegistry.SurfaceTextureEntry textureEntry) {
    eventChannel.setStreamHandler(
        new EventChannel.StreamHandler() {
          @Override
          public void onListen(Object o, EventChannel.EventSink sink) {
            eventSink.setDelegate(sink);
          }

          @Override
          public void onCancel(Object o) {
            eventSink.setDelegate(null);
          }
        });

    surface = new Surface(textureEntry.surfaceTexture());
    exoPlayer.setVideoSurface(surface);
    setAudioAttributes(exoPlayer, options.mixWithOthers);

    exoPlayer.addListener(
        new Listener() {
          private boolean isBuffering = false;

          public void setBuffering(boolean buffering) {
            if (isBuffering != buffering) {
              isBuffering = buffering;
              Map<String, Object> event = new HashMap<>();
              event.put("event", isBuffering ? "bufferingStart" : "bufferingEnd");
              eventSink.success(event);
            }
          }

          @Override
          public void onPlaybackStateChanged(final int playbackState) {
            if (playbackState == Player.STATE_BUFFERING) {
              setBuffering(true);
              sendBufferingUpdate();
            } else if (playbackState == Player.STATE_READY) {
              if (!isInitialized) {
                isInitialized = true;
                sendInitialized();
              }
            } else if (playbackState == Player.STATE_ENDED) {
              Map<String, Object> event = new HashMap<>();
              event.put("event", "completed");
              eventSink.success(event);
            }

            if (playbackState != Player.STATE_BUFFERING) {
              setBuffering(false);
            }
          }

          @Override
          public void onIsLoadingChanged(boolean isLoading) {
            Listener.super.onIsLoadingChanged(isLoading);
            if (isLoading) checkMediaAccess(dataSource);
          }

          @Override
          public void onPlayerError(final ExoPlaybackException error) {
            setBuffering(false);
            if (eventSink != null) {
              if (urlForbidenErrorMap.containsKey(dataSource)){
                eventSink.error("403", "Video player had error " + error, null);
              } else {
                eventSink.error("VideoError", "Video player had error " + error, null);
              }

            }
          }
        });
  }

  void sendBufferingUpdate() {
    Map<String, Object> event = new HashMap<>();
    event.put("event", "bufferingUpdate");
    List<? extends Number> range = Arrays.asList(0, exoPlayer.getBufferedPosition());
    // iOS supports a list of buffered ranges, so here is a list with a single range.
    event.put("values", Collections.singletonList(range));
    eventSink.success(event);
  }

  @SuppressWarnings("deprecation")
  private static void setAudioAttributes(SimpleExoPlayer exoPlayer, boolean isMixMode) {
    exoPlayer.setAudioAttributes(
        new AudioAttributes.Builder().setContentType(C.CONTENT_TYPE_MOVIE).build(), !isMixMode);
  }

  void play() {
    exoPlayer.setPlayWhenReady(true);
  }

  void pause() {
    exoPlayer.setPlayWhenReady(false);
  }

  void setLooping(boolean value) {
    exoPlayer.setRepeatMode(value ? REPEAT_MODE_ALL : REPEAT_MODE_OFF);
  }

  void setVolume(double value) {
    float bracketedValue = (float) Math.max(0.0, Math.min(1.0, value));
    exoPlayer.setVolume(bracketedValue);
  }

  void setPlaybackSpeed(double value) {
    // We do not need to consider pitch and skipSilence for now as we do not handle them and
    // therefore never diverge from the default values.
    final PlaybackParameters playbackParameters = new PlaybackParameters(((float) value));

    exoPlayer.setPlaybackParameters(playbackParameters);
  }

  void seekTo(int location) {
    exoPlayer.seekTo(location);
  }

  long getPosition() {
    return exoPlayer.getCurrentPosition();
  }

  @SuppressWarnings("SuspiciousNameCombination")
  private void sendInitialized() {
    if (isInitialized) {
      Map<String, Object> event = new HashMap<>();
      event.put("event", "initialized");
      event.put("duration", exoPlayer.getDuration());

      if (exoPlayer.getVideoFormat() != null) {
        Format videoFormat = exoPlayer.getVideoFormat();
        int width = videoFormat.width;
        int height = videoFormat.height;
        int rotationDegrees = videoFormat.rotationDegrees;
        // Switch the width/height if video was taken in portrait mode
        if (rotationDegrees == 90 || rotationDegrees == 270) {
          width = exoPlayer.getVideoFormat().height;
          height = exoPlayer.getVideoFormat().width;
        }
        event.put("width", width);
        event.put("height", height);
      }
      eventSink.success(event);
    }
  }

  void dispose() {
    mainHandler.removeCallbacks(accessForbidenRunnable);
    if (isInitialized) {
      exoPlayer.stop();
    }
    textureEntry.release();
    eventChannel.setStreamHandler(null);
    if (surface != null) {
      surface.release();
    }
    if (exoPlayer != null) {
      exoPlayer.release();
    }
  }

  @Override
  public void onCacheAvailable(File cacheFile, String url, int percentsAvailable) {

  }

  @Override
  public void onUrlError(Exception error, String url) {
    if ((error instanceof ProxyCacheException)&& ((ProxyCacheException)error).errorCode == "403") {
      urlForbidenErrorMap.put(url, "403");
      if (eventSink != null){
        Map<String, Object> event = new HashMap<>();
        event.put("event","bufferingEnd");
        eventSink.success(event);
        eventSink.error("403", "Video player had error " + error, null);
      }
    }
  }
}
