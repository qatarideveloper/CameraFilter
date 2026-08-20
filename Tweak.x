// CameraFilter — يضيف «صور الكاميرا» لقائمة تصفية تطبيق الصور (iOS 17, roothide)
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>

// ==== كلاسات PhotosUICore الخاصة (من dump iOS 17) ====
@interface PXContentFilterState : NSObject <NSCopying>
@property (nonatomic, copy) NSArray *uuids;
@property (nonatomic, copy) NSArray *keywords;
@property (nonatomic) BOOL image;
@property (nonatomic) BOOL video;
@property (nonatomic) BOOL favorite;
@property (nonatomic) BOOL edited;
@property (nonatomic, readonly) BOOL isFiltering;
@end

@interface PXCuratedLibraryViewModel : NSObject
@property (nonatomic, copy) PXContentFilterState *allPhotosContentFilterState;
@property (nonatomic, readonly) PXContentFilterState *currentContentFilterState;
- (void)userDidSetAllPhotosContentFilterState:(id)state;
- (void)resetAllPhotosContentFilterState;
@end

@interface PXCuratedLibraryActionPerformer : NSObject
@property (nonatomic, readonly) PXCuratedLibraryViewModel *viewModel;
@end

// ============================================================
//  المُفهرِس: يحسب أي الصور مصوّرة بكاميرا Apple ويخزّنها بكاش
// ============================================================
static NSString *CFCachePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/CameraFilterCache.plist"];
}

@interface CFCameraIndex : NSObject
@property (atomic, strong) NSMutableDictionary<NSString*,NSNumber*> *cache; // localIdentifier -> 1/0
@property (atomic, assign) BOOL building;
+ (instancetype)shared;
- (NSArray<NSString*> *)cameraUUIDs;
- (void)buildIncremental:(void(^)(void))completion;
@end

@implementation CFCameraIndex
+ (instancetype)shared {
    static CFCameraIndex *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [CFCameraIndex new]; [s load]; });
    return s;
}
- (void)load {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:CFCachePath()];
    self.cache = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
- (void)save {
    [self.cache writeToFile:CFCachePath() atomically:YES];
}

// قراءة متدفّقة لأول جزء من الملف فقط (EXIF بالبداية) — ذاكرة قليلة وبلا PHImageManager
static BOOL CFMakeIsApple(NSData *buf) {
    if (buf.length < 64) return NO;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)buf,
        (__bridge CFDictionaryRef)@{(__bridge id)kCGImageSourceShouldCache:@NO});
    if (!src) return NO;
    BOOL isCam = NO;
    NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    NSDictionary *tiff = props[(__bridge NSString*)kCGImagePropertyTIFFDictionary];
    NSString *make = tiff[(__bridge NSString*)kCGImagePropertyTIFFMake];
    if (make && [make caseInsensitiveCompare:@"Apple"] == NSOrderedSame) isCam = YES;
    CFRelease(src);
    return isCam;
}

static BOOL CFAssetIsCamera(PHAsset *asset) {
    @try {
        if (asset.mediaSubtypes & PHAssetMediaSubtypePhotoScreenshot) return NO; // تخطٍّ رخيص
        PHAssetResource *photoRes = nil;
        for (PHAssetResource *r in [PHAssetResource assetResourcesForAsset:asset]) {
            if (r.type == PHAssetResourceTypePhoto) { photoRes = r; break; }
        }
        if (!photoRes) return NO;

        __block NSMutableData *buf = [NSMutableData data];
        __block BOOL enough = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        PHAssetResourceRequestOptions *o = [PHAssetResourceRequestOptions new];
        o.networkAccessAllowed = NO;
        [[PHAssetResourceManager defaultManager] requestDataForAssetResource:photoRes options:o
            dataReceivedHandler:^(NSData *chunk) {
                if (enough) return;              // تجاهل الباقي بعد ما نجمع كفاية
                [buf appendData:chunk];
                if (buf.length >= 512 * 1024) enough = YES; // سقف ٥١٢ك.ب
            }
            completionHandler:^(NSError *e) { dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
        return CFMakeIsApple(buf);
    } @catch (__unused NSException *ex) {
        return NO;
    }
}

- (void)buildIncremental:(void(^)(void))completion {
    if (self.building) { if (completion) completion(); return; }
    self.building = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            PHFetchOptions *fo = [PHFetchOptions new];
            fo.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeImage];
            PHFetchResult *r = [PHAsset fetchAssetsWithOptions:fo];
            NSMutableDictionary *cache = self.cache;
            __block int newCount = 0;
            [r enumerateObjectsUsingBlock:^(PHAsset *a, NSUInteger i, BOOL *stop) {
                @autoreleasepool {
                    NSString *lid = a.localIdentifier;
                    if (!lid || cache[lid] != nil) return;    // مفهرَس مسبقاً
                    BOOL cam = CFAssetIsCamera(a);
                    cache[lid] = @(cam);
                    newCount++;
                    if (newCount % 200 == 0) [self save];     // حفظ دوري
                }
            }];
            [self save];
        } @catch (__unused NSException *ex) {}
        self.building = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(); });
    });
}

- (NSArray<NSString*> *)cameraUUIDs {
    NSMutableArray *out = [NSMutableArray array];
    [self.cache enumerateKeysAndObjectsUsingBlock:^(NSString *lid, NSNumber *v, BOOL *stop) {
        if (v.boolValue) {
            NSString *uuid = [lid componentsSeparatedByString:@"/"].firstObject; // UUID فقط
            if (uuid.length) [out addObject:uuid];
        }
    }];
    return out;
}
@end

// ============================================================
//  HUD بسيط أثناء الفهرسة الأولى
// ============================================================
static UIWindow *gHUD;
static void CFShowHUD(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gHUD) return;
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene*)s; break; }
        UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel = UIWindowLevelStatusBar + 100;
        w.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [UIViewController new];
        w.rootViewController = vc;
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        blur.layer.cornerRadius = 14; blur.clipsToBounds = YES;
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:blur];
        UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spin.color = UIColor.whiteColor; [spin startAnimating];
        spin.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *lbl = [UILabel new];
        lbl.text = text; lbl.textColor = UIColor.whiteColor; lbl.font = [UIFont systemFontOfSize:15];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [blur.contentView addSubview:spin]; [blur.contentView addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [blur.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
            [blur.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
            [spin.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:16],
            [spin.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor],
            [lbl.leadingAnchor constraintEqualToAnchor:spin.trailingAnchor constant:10],
            [lbl.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-16],
            [lbl.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor constant:14],
            [lbl.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor constant:-14],
        ]];
        w.hidden = NO; gHUD = w;
    });
}
static void CFHideHUD(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ gHUD.hidden = YES; gHUD = nil; });
}

// ============================================================
//  تطبيق الفلتر على الشبكة الأصلية
// ============================================================
static void CFApplyCameraFilter(PXCuratedLibraryViewModel *vm) {
    if (!vm) return;
    // تبديل: إذا مفعّل أصلاً -> إلغاء
    PXContentFilterState *cur = vm.currentContentFilterState;
    if (cur && cur.uuids.count > 0) {
        [vm resetAllPhotosContentFilterState];
        return;
    }
    CFCameraIndex *idx = [CFCameraIndex shared];
    void (^apply)(void) = ^{
        NSArray *uuids = [idx cameraUUIDs];
        PXContentFilterState *base = vm.allPhotosContentFilterState ?: vm.currentContentFilterState;
        PXContentFilterState *st = [base copy];
        if (!st) return;
        st.uuids = uuids;
        dispatch_async(dispatch_get_main_queue(), ^{
            [vm userDidSetAllPhotosContentFilterState:st];
        });
    };
    if (idx.cache.count > 0 && !idx.building) {
        apply();
    } else {
        CFShowHUD(@"جاري فهرسة صور الكاميرا…");
        [idx buildIncremental:^{ CFHideHUD(); apply(); }];
    }
}

// ============================================================
//  حقن العنصر في قائمة «تصفية»
// ============================================================
%hook PXCuratedLibraryShowFiltersMenuActionPerformer
- (id)menuElement {
    id orig = %orig;
    PXCuratedLibraryViewModel *vm = ((PXCuratedLibraryActionPerformer *)self).viewModel;
    if (!vm || ![orig isKindOfClass:UIMenu.class]) return orig;

    __weak PXCuratedLibraryViewModel *wvm = vm;
    UIImage *img = [UIImage systemImageNamed:@"camera"];
    UIAction *cam = [UIAction actionWithTitle:@"صور الكاميرا"
                                        image:img
                                   identifier:@"com.qatar.camerafilter.action"
                                      handler:^(__kindof UIAction *a) {
        CFApplyCameraFilter(wvm);
    }];
    PXContentFilterState *cur = vm.currentContentFilterState;
    if (cur && cur.uuids.count > 0) cam.state = UIMenuElementStateOn;

    UIMenu *m = (UIMenu *)orig;
    return [m menuByReplacingChildren:[m.children arrayByAddingObject:cam]];
}
%end

// لا فهرسة تلقائية — تُبنى فقط عند الطلب (أول ضغطة على «صور الكاميرا»)
