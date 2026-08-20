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
@property (nonatomic, readonly) PHPhotoLibrary *photoLibrary; // مكتبة التطبيق (multi-library)
@end

// PHFetchOptions.photoLibrary خاص — يربط الجلب بمكتبة محددة
@interface PHFetchOptions (CFPrivate)
@property (nonatomic, retain) PHPhotoLibrary *photoLibrary;
@end

// PHAsset.uniformTypeIdentifier خاص — نوع الملف بلا قراءة بيانات
@interface PHAsset (CFPrivate)
- (NSString *)uniformTypeIdentifier;
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

// مسار الألبومات (PXPhotosGrid)
@interface PXPhotosViewModel : NSObject
@property (nonatomic, readonly) PXContentFilterState *contentFilterState;
- (void)setContentFilterState:(id)state;
@end

@interface PXPhotosGridActionPerformer : NSObject
@property (nonatomic, readonly) PXPhotosViewModel *viewModel;
@property (nonatomic, readonly) PXContentFilterState *currentContentFilterState;
@end

// ============================================================
//  المُفهرِس: يحسب أي الصور مصوّرة بكاميرا Apple ويخزّنها بكاش
// ============================================================
static NSString *CFCachePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/CameraFilterCache.plist"];
}

// عدّادات تشخيص مؤقّتة
static long gDbgAuth = -1, gDbgAll = -1, gDbgImg = -1;
static NSString *gDbgErr = nil, *gDbgResErr = nil;

@interface CFCameraIndex : NSObject
@property (atomic, strong) NSMutableDictionary<NSString*,NSNumber*> *cache; // localIdentifier -> 1/0
@property (atomic, assign) BOOL building;
+ (instancetype)shared;
- (NSArray<NSString*> *)cameraUUIDs;
- (void)buildWithLibrary:(PHPhotoLibrary *)lib completion:(void(^)(void))completion;
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

// كشف سريع بلا قراءة بيانات: نوع الملف HEIC/HEIF = كاميرا آيفون غالباً
static BOOL CFUTIIsCamera(NSString *uti) {
    if (!uti.length) return NO;
    return ([uti caseInsensitiveCompare:@"public.heic"] == NSOrderedSame ||
            [uti caseInsensitiveCompare:@"public.heif"] == NSOrderedSame);
}

static BOOL CFAssetIsCamera(PHAsset *asset) {
    @try {
        if (asset.mediaSubtypes & PHAssetMediaSubtypePhotoScreenshot) return NO; // سكرين شوت
        // 1) UTI مباشرة من PHAsset (خاص) — أسرع، بلا قراءة بيانات
        NSString *uti = nil;
        if ([asset respondsToSelector:@selector(uniformTypeIdentifier)])
            uti = [asset uniformTypeIdentifier];
        if (uti.length) return CFUTIIsCamera(uti);
        // 2) fallback: نوع أول resource صورة (رخيص، بلا بيانات بكسل)
        for (PHAssetResource *r in [PHAssetResource assetResourcesForAsset:asset]) {
            if (r.type == PHAssetResourceTypePhoto) return CFUTIIsCamera(r.uniformTypeIdentifier);
        }
        return NO;
    } @catch (NSException *ex) {
        if (!gDbgResErr) gDbgResErr = ex.reason ?: ex.name;
        return NO;
    }
}

- (void)buildWithLibrary:(PHPhotoLibrary *)lib completion:(void(^)(void))completion {
    if (self.building) { if (completion) completion(); return; }
    self.building = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            gDbgAuth = (long)[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
            PHFetchOptions *fo = [PHFetchOptions new];
            if (lib) fo.photoLibrary = lib;          // ربط الجلب بمكتبة التطبيق (multi-library)
            PHFetchResult *r = [PHAsset fetchAssetsWithOptions:fo];
            gDbgAll = (long)r.count;
            NSMutableDictionary *cache = self.cache;
            __block int newCount = 0, imgCount = 0;
            [r enumerateObjectsUsingBlock:^(PHAsset *a, NSUInteger i, BOOL *stop) {
                @autoreleasepool {
                    if (a.mediaType != PHAssetMediaTypeImage) return; // صور فقط (بالكود)
                    imgCount++;
                    NSString *lid = a.localIdentifier;
                    if (!lid || cache[lid] != nil) return;
                    BOOL cam = CFAssetIsCamera(a);
                    cache[lid] = @(cam);
                    newCount++;
                    if (newCount % 200 == 0) [self save];
                }
            }];
            gDbgImg = (long)imgCount;
            [self save];
        } @catch (NSException *ex) { gDbgErr = ex.reason ?: ex.name; }
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

// تشخيص مؤقّت: يعرض أرقام الفهرسة وصيغة الـUUID الفعلية
static UIWindow *gAlertWin;
static void CFShowDebug(CFCameraIndex *idx, NSArray *uuids, void (^then)(void)) {
    __block int cam = 0, non = 0; __block NSString *sampleLid = nil;
    [idx.cache enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSNumber *v, BOOL *s) {
        if (v.boolValue) { cam++; if (!sampleLid) sampleLid = k; } else non++;
    }];
    NSString *msg = [NSString stringWithFormat:
        @"auth: %ld | كل الأصول: %ld | صور: %ld\nخطأ الجلب: %@\nخطأ القراءة: %@\nمفهرَس: %d | كاميرا: %d | غير: %d\nUUID: %@\nعدد uuids: %lu",
        gDbgAuth, gDbgAll, gDbgImg, gDbgErr ?: @"—", gDbgResErr ?: @"—",
        cam + non, cam, non, uuids.firstObject ?: @"(فاضي)", (unsigned long)uuids.count];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene*)s; break; }
        UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel = UIWindowLevelStatusBar + 200;
        w.rootViewController = [UIViewController new];
        w.hidden = NO; gAlertWin = w;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"CameraFilter تشخيص" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"تطبيق" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            gAlertWin.hidden = YES; gAlertWin = nil; if (then) then();
        }]];
        [w.rootViewController presentViewController:ac animated:YES completion:nil];
    });
}

// ============================================================
//  محرّك تطبيق الفلتر (مشترك بين المكتبة والألبومات)
// ============================================================
// current: الحالة الحالية | copyBase: نسخة قابلة للتعديل | applyState: تطبيقها | resetFilter: إلغاء
static void CFRunCameraFilter(PXContentFilterState *current,
                              PHPhotoLibrary *lib,
                              PXContentFilterState *(^copyBase)(void),
                              void (^applyState)(PXContentFilterState *)) {
    // تبديل: إذا مفعّل أصلاً بصور الكاميرا -> إلغاء
    if (current && current.uuids.count > 0) {
        PXContentFilterState *st = copyBase();
        st.uuids = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ applyState(st); });
        return;
    }
    CFCameraIndex *idx = [CFCameraIndex shared];
    void (^apply)(void) = ^{
        NSArray *uuids = [idx cameraUUIDs];
        PXContentFilterState *st = copyBase();
        if (!st) return;
        st.uuids = uuids;
        CFShowDebug(idx, uuids, ^{   // تشخيص مؤقّت — يُزال بعد ما نعرف الصيغة
            dispatch_async(dispatch_get_main_queue(), ^{ applyState(st); });
        });
    };
    if (idx.cache.count > 0 && !idx.building) {
        apply();
    } else {
        CFShowHUD(@"جاري فهرسة صور الكاميرا…");
        [idx buildWithLibrary:lib completion:^{ CFHideHUD(); apply(); }];
    }
}

// يضيف عنصر «صور الكاميرا» داخل قائمة تصفية
static id CFAppendCameraItem(id orig, BOOL on, void (^handler)(void)) {
    if (![orig isKindOfClass:UIMenu.class]) return orig;
    UIAction *cam = [UIAction actionWithTitle:@"صور الكاميرا"
                                        image:[UIImage systemImageNamed:@"camera"]
                                   identifier:@"com.qatar.camerafilter.action"
                                      handler:^(__kindof UIAction *a) { handler(); }];
    if (on) cam.state = UIMenuElementStateOn;
    UIMenu *m = (UIMenu *)orig;
    return [m menuByReplacingChildren:[m.children arrayByAddingObject:cam]];
}

// ============================================================
//  حقن العنصر — مسار المكتبة (CuratedLibrary)
// ============================================================
%hook PXCuratedLibraryShowFiltersMenuActionPerformer
- (id)menuElement {
    id orig = %orig;
    PXCuratedLibraryViewModel *vm = ((PXCuratedLibraryActionPerformer *)self).viewModel;
    if (!vm) return orig;
    __weak PXCuratedLibraryViewModel *wvm = vm;
    BOOL on = (vm.currentContentFilterState.uuids.count > 0);
    return CFAppendCameraItem(orig, on, ^{
        PXCuratedLibraryViewModel *v = wvm; if (!v) return;
        PHPhotoLibrary *lib = v.currentContentFilterState.photoLibrary ?: v.allPhotosContentFilterState.photoLibrary;
        CFRunCameraFilter(v.currentContentFilterState, lib,
            ^{ return (PXContentFilterState *)[(v.allPhotosContentFilterState ?: v.currentContentFilterState) copy]; },
            ^(PXContentFilterState *st){ [v userDidSetAllPhotosContentFilterState:st]; });
    });
}
%end

// ============================================================
//  حقن العنصر — مسار الألبومات (PXPhotosGrid)
// ============================================================
%hook PXPhotosGridShowFiltersMenuActionPerformer
- (id)menuElement {
    id orig = %orig;
    PXPhotosViewModel *vm = ((PXPhotosGridActionPerformer *)self).viewModel;
    if (!vm) return orig;
    __weak PXPhotosViewModel *wvm = vm;
    BOOL on = (vm.contentFilterState.uuids.count > 0);
    return CFAppendCameraItem(orig, on, ^{
        PXPhotosViewModel *v = wvm; if (!v) return;
        PHPhotoLibrary *lib = v.contentFilterState.photoLibrary;
        CFRunCameraFilter(v.contentFilterState, lib,
            ^{ return (PXContentFilterState *)[v.contentFilterState copy]; },
            ^(PXContentFilterState *st){ [v setContentFilterState:st]; });
    });
}
%end

// لا فهرسة تلقائية — تُبنى فقط عند الطلب (أول ضغطة على «صور الكاميرا»)
