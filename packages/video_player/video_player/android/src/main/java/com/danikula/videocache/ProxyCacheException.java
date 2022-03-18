package com.danikula.videocache;

import io.flutter.plugins.videoplayer.BuildConfig;

/**
 * Indicates any error in work of {@link ProxyCache}.
 *
 * @author Alexey Danilov
 */
public class ProxyCacheException extends Exception {

    private static final String LIBRARY_VERSION = ". Version: " + "2.2.10";

    public String errorCode = "";

    public ProxyCacheException(String message) {
        super(message + LIBRARY_VERSION);
    }

    public ProxyCacheException(String message, Throwable cause) {
        super(message + LIBRARY_VERSION, cause);
    }

    public ProxyCacheException(String message, Throwable cause, String errorCode) {
        super(message + LIBRARY_VERSION, cause);
        this.errorCode = errorCode;
    }
    public ProxyCacheException(Throwable cause) {
        super("No explanation error" + LIBRARY_VERSION, cause);
    }
}
