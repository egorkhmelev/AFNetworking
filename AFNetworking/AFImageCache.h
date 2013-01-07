//
//  AFImageCache.h
//  Newfork
//
//  Created by Egor Khmelev on 07.01.13.
//  Copyright (c) 2013 Cruzeiro Marketing Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AFImageCache : NSObject

+ (AFImageCache *)sharedImageCache;
- (id)initWithNamespace:(NSString *)ns;

- (void)cacheRequest:(NSURLRequest *)request permanent:(BOOL)permanent;

- (void)cacheImage:(UIImage *)image forRequest:(NSURLRequest *)request;
- (void)cacheImage:(UIImage *)image forRequest:(NSURLRequest *)request permanent:(BOOL)permanent;

- (void)cachedImageForRequest:(NSURLRequest *)request done:(void (^)(NSURLRequest *request, UIImage *image))doneBlock;
- (void)removeImageForRequest:(NSURLRequest *)request;

- (void)flushMemory;
- (void)flushDisk;

@end
