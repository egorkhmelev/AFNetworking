//
//  AFImageCache.m
//  Newfork
//
//  Created by Egor Khmelev on 07.01.13.
//  Copyright (c) 2013 Cruzeiro Marketing Ltd. All rights reserved.
//

#import "AFImageCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <mach/mach_host.h>

static inline NSString * AFImageCacheKeyFromURLRequest(NSURLRequest *request) {
    return [[request URL] absoluteString];
}

static inline NSString * AFImageCacheFilenameFromURLRequest(NSURLRequest *request) {
    const char *str = [AFImageCacheKeyFromURLRequest(request) UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
}

@interface AFImageCache()
    @property (assign, nonatomic) dispatch_queue_t ioQueue;
    @property (strong, nonatomic) NSCache *memoryCache;
    @property (strong, nonatomic) NSURL *permanentCacheURL;
    @property (strong, nonatomic) NSOperationQueue *imageRequestOperationQueue;
@end

@implementation AFImageCache

+ (AFImageCache *)sharedImageCache
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    return [self initWithNamespace:@"default"];
}

- (id)initWithNamespace:(NSString *)ns
{
    if ((self = [super init]))
    {
        NSString *fullNamespace = [@"com.application.AFImageCache." stringByAppendingString:ns];
        
        _ioQueue = dispatch_queue_create("com.application.AFImageCache", DISPATCH_QUEUE_SERIAL);
        
        _imageRequestOperationQueue = [[NSOperationQueue alloc] init];
        [_imageRequestOperationQueue setMaxConcurrentOperationCount:NSOperationQueueDefaultMaxConcurrentOperationCount];
        
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.name = fullNamespace;
        
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        
        NSString *permanentNamespace = [fullNamespace stringByAppendingString:@".permanent"];
        NSURL *applicationSupportDirectory = [fileManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        _permanentCacheURL = [applicationSupportDirectory URLByAppendingPathComponent:permanentNamespace isDirectory:YES];
        
#if TARGET_OS_IPHONE
        // Subscribe to memory warning event
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(flushMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
#endif
        
    }
    return self;
}

- (void)cacheRequest:(NSURLRequest *)request permanent:(BOOL)permanent
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSURL *cachedFileURL = [self.permanentCacheURL URLByAppendingPathComponent:AFImageCacheFilenameFromURLRequest(request) isDirectory:NO];
    
    // Check whether request already cached
    if (permanent && [fileManager fileExistsAtPath:[cachedFileURL path]]) {
        // Request already cached permanently
        return;
    } else if (!permanent && [self.memoryCache objectForKey:AFImageCacheKeyFromURLRequest(request)]) {
        // Request already cached in-memory, and user asks for only in-memory cache
        return;
    }
    
    AFImageRequestOperation *requestOperation = [[AFImageRequestOperation alloc] initWithRequest:request];
    [requestOperation setQueuePriority:NSOperationQueuePriorityLow];
    [requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
        [self cacheImage:responseObject forRequest:request permanent:permanent];
    } failure:nil];
    
    [self.imageRequestOperationQueue addOperation:requestOperation];
}

- (void)cacheImage:(UIImage *)image forRequest:(NSURLRequest *)request
{
    [self cacheImage:image forRequest:request permanent:NO];
}

- (void)cacheImage:(UIImage *)image forRequest:(NSURLRequest *)request permanent:(BOOL)permanent
{
    if (!image || !request) {
        return;
    }
    
    [self.memoryCache setObject:image forKey:AFImageCacheKeyFromURLRequest(request) cost:image.size.height * image.size.width * image.scale];
    
    if (!permanent) {
        return;
    }
    
    dispatch_async(self.ioQueue, ^{
        NSData *data = UIImageJPEGRepresentation(image, (CGFloat)1.0);
        
        if (data) {
            // Can't use defaultManager in another thread
            NSFileManager *fileManager = [[NSFileManager alloc] init];
            
            if (![fileManager fileExistsAtPath:[self.permanentCacheURL path]]) {
                [fileManager createDirectoryAtURL:self.permanentCacheURL withIntermediateDirectories:YES attributes:nil error:NULL];
                
                // Mark directory for iCloud as "do not back up"
                [self.permanentCacheURL setResourceValue:[NSNumber numberWithBool:YES]
                                                  forKey:NSURLIsExcludedFromBackupKey error:nil];
                
            }
            
            NSURL *cachedFileURL = [self.permanentCacheURL URLByAppendingPathComponent:AFImageCacheFilenameFromURLRequest(request) isDirectory:NO];
            [fileManager createFileAtPath:[cachedFileURL path] contents:data attributes:nil];
        }
        
    });
}

- (void)cachedImageForRequest:(NSURLRequest *)request done:(void (^)(NSURLRequest *request, UIImage *image))doneBlock
{
    switch ([request cachePolicy]) {
        case NSURLRequestReloadIgnoringCacheData:
        case NSURLRequestReloadIgnoringLocalAndRemoteCacheData:
            doneBlock(request, nil);
            return;
        default:
            break;
    }
    
    // Checking in-memory cache
    UIImage *image = [self.memoryCache objectForKey:AFImageCacheKeyFromURLRequest(request)];
    if (image) {
        doneBlock(request, image);
        return;
    }
    
    // Checking permanent cache
    dispatch_async(self.ioQueue, ^{
        NSURL *cachedFileURL = [self.permanentCacheURL URLByAppendingPathComponent:AFImageCacheFilenameFromURLRequest(request) isDirectory:NO];
        NSData *data = [NSData dataWithContentsOfURL:cachedFileURL];
        UIImage *diskImage = [UIImage imageWithData:data];
        
        // Load image in memory for future use
        if (diskImage) {
            [self.memoryCache setObject:diskImage forKey:AFImageCacheKeyFromURLRequest(request) cost:image.size.height * image.size.width * image.scale];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            doneBlock(request, diskImage);
        });
    });
}

- (void)removeImageForRequest:(NSURLRequest *)request
{
    [self.memoryCache removeObjectForKey:AFImageCacheKeyFromURLRequest(request)];
    dispatch_async(self.ioQueue, ^{
        NSURL *cachedFileURL = [self.permanentCacheURL URLByAppendingPathComponent:AFImageCacheFilenameFromURLRequest(request) isDirectory:NO];

        NSFileManager *fileManager = [[NSFileManager alloc] init];
        [fileManager removeItemAtURL:cachedFileURL error:nil];
    });
}

- (void)flushMemory
{
    [self.memoryCache removeAllObjects];
}

- (void)flushDisk
{
    dispatch_async(self.ioQueue, ^{
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        [fileManager removeItemAtURL:self.permanentCacheURL error:nil];
    });
}

@end
