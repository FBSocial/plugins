//
//  DVAsserLoaderHelpers.c
//
//  Created by Vladislav Dugnist on 31/12/2017.
//  Copyright © 2017 vdugnist. All rights reserved.
//

#import "DVAssetLoaderHelpers.h"

NSString *rangeFromRequest(NSURLRequest *request) {
    return [[request.allHTTPHeaderFields[@"Range"] componentsSeparatedByString:@"="] lastObject];
}

NSString *rangeFromResponse(NSHTTPURLResponse *response) {
    return [[[[response.allHeaderFields[@"Content-Range"] componentsSeparatedByString:@"/"] firstObject] componentsSeparatedByString:@" "] lastObject];
}

NSString *concatedDataFromRanges(NSDictionary<NSValue *, NSString *> *dataRanges, long long fullLength) {
    NSRange lastRange = NSMakeRange(0, 0);
    
    while (lastRange.location + lastRange.length != fullLength) {
        NSRange currentRange = lastRange;
        for (NSValue *range in dataRanges.allKeys) {
            NSUInteger location = range.rangeValue.location;
            NSUInteger length = range.rangeValue.length;
            if (location <= lastRange.location + lastRange.length && location + length > currentRange.location + currentRange.length) {
                currentRange.location = location;
                currentRange.length = length;
            }
        }

        if (currentRange.location == lastRange.location && currentRange.length == lastRange.length) {
            return nil;
        }
        lastRange.location = currentRange.location;
        lastRange.length = currentRange.length;
    }
    
    NSString *segFileName = [[NSUUID UUID] UUIDString];
    NSString *segFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:segFileName];
    [[NSFileManager defaultManager] createFileAtPath:segFilePath contents:nil attributes:nil];
    lastRange = NSMakeRange(0, 0);
    while (lastRange.location + lastRange.length != fullLength) {
        NSRange currentRange = lastRange;
        for (NSValue *range in dataRanges.allKeys) {
            NSUInteger location = range.rangeValue.location;
            NSUInteger length = range.rangeValue.length;
            if (location <= lastRange.location + lastRange.length && location + length > currentRange.location + currentRange.length) {
                currentRange.location = location;
                currentRange.length = length;
            }
        }

        if (currentRange.location == lastRange.location && currentRange.length == lastRange.length) {
            [[NSFileManager defaultManager] removeItemAtPath:segFilePath error:nil];
            return nil;
        }

        NSUInteger offset = (lastRange.location + lastRange.length) - currentRange.location;
        NSData *subdata = [NSData dataWithContentsOfFile:dataRanges[[NSValue valueWithRange:currentRange]]];
        subdata = [subdata subdataWithRange:NSMakeRange(offset, subdata.length - offset)];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:segFilePath];
        [handle seekToEndOfFile];
        [handle writeData:subdata];
        [handle closeFile];

        lastRange.location = currentRange.location;
        lastRange.length = currentRange.length;
    }

    return segFilePath;
}
