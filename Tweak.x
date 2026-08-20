// CameraFilter — يضيف «صور الكاميرا» لقائمة تصفية تطبيق الصور (iOS 17, roothide)
// الكشف: نوع الملف HEIC/HEIF = صورة كاميرا آيفون. الجلب باستعلام واحد على مستوى قاعدة البيانات.
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

// ============================================================
//  كلاسات PhotosUICore الخاصة (من dump iOS 17)
// ============================================================
@interface PXContentFilterState : NSObject <NSCopying>
@property (nonatomic, copy) NSArray *uuids;
@property (nonatomic, readonly) PHPhotoLibrary *photoLibrary;
@end

@interface PXUpdater : NSObject
- (void)updateIfNeeded;   // يفرّغ التحديثات المعلّقة فوراً
@end

@interface PXCuratedLibraryViewModel : NSObject   // تبويب «المكتبة»
@property (nonatomic, copy) PXContentFilterState *allPhotosContentFilterState;
@property (nonatomic, readonly) PXContentFilterState *currentContentFilterState;
@property (nonatomic, readonly) PXUpdater *updater;
- (void)userDidSetAllPhotosContentFilterState:(id)state;
- (void)_setNeedsUpdate;
- (void)_invalidateAssetsDataSourceManager;
@end
@interface PXCuratedLibraryActionPerformer : NSObject
@property (nonatomic, readonly) PXCuratedLibraryViewModel *viewModel;
@end

@interface PXPhotosViewModel : NSObject           // الألبومات
@property (nonatomic, readonly) PXContentFilterState *contentFilterState;
@property (nonatomic, readonly) PXUpdater *updater;
- (void)setContentFilterState:(id)state;
- (void)_setNeedsUpdate;
- (void)_invalidateAssetsDataSourceManager;
@end

// إعادة رسم الشبكة فوراً بعد تغيير الفلتر (بدل انتظار لمسة المستخدم)
static void CFRefreshGrid(id vm) {
    // يمنع كراش عند إضافة/حذف صورة والفلتر شغّال (assert على predicate الفلتر المخصّص)
    @try { [vm setValue:@YES forKey:@"ignoreFilterPredicateAssert"]; } @catch (__unused id e) {}
    if ([vm respondsToSelector:@selector(_setNeedsUpdate)]) [vm _setNeedsUpdate];
    PXUpdater *up = [vm respondsToSelector:@selector(updater)] ? [vm updater] : nil;
    // لا تجبر التحديث إذا المُحدِّث مشغول (تفادي re-entrancy = كراش عند الضغط السريع)
    BOOL busy = NO;
    @try { busy = [[up valueForKey:@"isPerformingUpdates"] boolValue]; } @catch (__unused id e) {}
    if (!busy && [up respondsToSelector:@selector(updateIfNeeded)]) {
        @try { [up updateIfNeeded]; } @catch (__unused id e) {}
    }
}
@interface PXPhotosGridActionPerformer : NSObject
@property (nonatomic, readonly) PXPhotosViewModel *viewModel;
@end

// ============================================================
//  PhotoKit خاص
// ============================================================
@interface PHFetchOptions (CFPrivate)
@property (nonatomic, retain) PHPhotoLibrary *photoLibrary; // ربط الجلب بمكتبة (multi-library)
@end
@interface PHAsset (CFPrivate)
@property (nonatomic, readonly) NSString *uniformTypeIdentifier; // نوع الملف بلا قراءة بيانات
@property (nonatomic, readonly) NSString *px_make;               // صانع الكاميرا (Apple) من قاعدة البيانات
@end

// ============================================================
//  المُفهرِس: UUIDات صور الكاميرا (HEIC/HEIF)
// ============================================================
static NSString *CFCachePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/CameraFilterUUIDs.plist"];
}
// احتياط: HEIC/HEIF = صور كاميرا حصراً. (لا نضيف mov لأنه يمسك أي فيديو حتى المحمّل)
static BOOL CFUTIIsCamera(NSString *uti) {
    return uti.length && (
        [uti caseInsensitiveCompare:@"public.heic"] == NSOrderedSame ||
        [uti caseInsensitiveCompare:@"public.heif"] == NSOrderedSame);
}
static NSString *CFUUIDFromLocalId(NSString *lid) {
    return [lid componentsSeparatedByString:@"/"].firstObject; // "UUID/L0/001" -> "UUID"
}

@interface CFCameraIndex : NSObject
@property (atomic, strong) NSArray<NSString*> *uuids;
@property (atomic, assign) BOOL building;
+ (instancetype)shared;
- (void)buildWithLibrary:(PHPhotoLibrary *)lib completion:(void(^)(void))completion;
@end

@implementation CFCameraIndex
+ (instancetype)shared {
    static CFCameraIndex *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [CFCameraIndex new];
        s.uuids = [NSArray arrayWithContentsOfFile:CFCachePath()] ?: @[]; });
    return s;
}

- (void)buildWithLibrary:(PHPhotoLibrary *)lib completion:(void(^)(void))completion {
    if (self.building) { if (completion) completion(); return; }
    self.building = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *out = [NSMutableArray array];
        // لفّة واحدة: كاميرا = (Make == Apple) أو نوع كاميرا (HEIC/HEIF/mov) — مستقل عن التنسيق
        @try {
            PHFetchOptions *fo = [PHFetchOptions new];
            if (lib) fo.photoLibrary = lib;
            PHFetchResult *r = [PHAsset fetchAssetsWithOptions:fo];
            [r enumerateObjectsUsingBlock:^(PHAsset *a, NSUInteger i, BOOL *st) {
                @autoreleasepool {
                    if (a.mediaSubtypes & PHAssetMediaSubtypePhotoScreenshot) return; // سكرين شوت
                    BOOL cam = NO;
                    @try {                                    // Make من قاعدة البيانات (كل التنسيقات)
                        NSString *mk = a.px_make;
                        if (mk && [mk caseInsensitiveCompare:@"Apple"] == NSOrderedSame) cam = YES;
                    } @catch (__unused id e) {}
                    if (!cam) {                               // احتياط: نوع الملف
                        NSString *uti = nil; @try { uti = a.uniformTypeIdentifier; } @catch (__unused id e) {}
                        cam = CFUTIIsCamera(uti);
                    }
                    if (cam) { NSString *u = CFUUIDFromLocalId(a.localIdentifier); if (u.length) [out addObject:u]; }
                }
            }];
        } @catch (__unused NSException *ex) {}

        self.uuids = out;
        [out writeToFile:CFCachePath() atomically:YES];
        self.building = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(); });
    });
}
@end

// ============================================================
//  HUD بسيط أثناء التجهيز الأول
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
        w.rootViewController = [UIViewController new];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        blur.layer.cornerRadius = 14; blur.clipsToBounds = YES;
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        [w.rootViewController.view addSubview:blur];
        UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spin.color = UIColor.whiteColor; [spin startAnimating];
        spin.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *lbl = [UILabel new];
        lbl.text = text; lbl.textColor = UIColor.whiteColor; lbl.font = [UIFont systemFontOfSize:15];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [blur.contentView addSubview:spin]; [blur.contentView addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [blur.centerXAnchor constraintEqualToAnchor:w.rootViewController.view.centerXAnchor],
            [blur.centerYAnchor constraintEqualToAnchor:w.rootViewController.view.centerYAnchor],
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
//  محرّك تطبيق الفلتر (مشترك بين المكتبة والألبومات)
// ============================================================
static void CFRunCameraFilter(PXContentFilterState *current,
                              PHPhotoLibrary *lib,
                              PXContentFilterState *(^copyBase)(void),
                              void (^applyState)(PXContentFilterState *)) {
    // تبديل: مفعّل أصلاً -> إلغاء
    if (current && current.uuids.count > 0) {
        PXContentFilterState *st = copyBase();
        st.uuids = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ applyState(st); });
        return;
    }
    CFCameraIndex *idx = [CFCameraIndex shared];
    void (^apply)(void) = ^{
        PXContentFilterState *st = copyBase();
        if (!st) return;
        st.uuids = idx.uuids;
        dispatch_async(dispatch_get_main_queue(), ^{ applyState(st); });
    };
    if (idx.uuids.count > 0) {
        apply();                                       // فوري من الكاش
        [idx buildWithLibrary:lib completion:nil];     // تحديث صامت للمرّة الجاية
    } else {
        CFShowHUD(@"جاري تجهيز صور الكاميرا…");
        [idx buildWithLibrary:lib completion:^{ CFHideHUD(); apply(); }];
    }
}

// يضيف عنصر «صور الكاميرا» داخل قائمة تصفية
static id CFAppendCameraItem(id orig, BOOL on, void (^handler)(void)) {
    if (![orig isKindOfClass:UIMenu.class]) return orig;
    UIAction *cam = [UIAction actionWithTitle:@"من الكاميرا"
                                        image:[UIImage systemImageNamed:@"camera"]
                                   identifier:@"com.qatar.camerafilter.action"
                                      handler:^(__kindof UIAction *a) { handler(); }];
    if (on) cam.state = UIMenuElementStateOn;
    UIMenu *m = (UIMenu *)orig;
    NSMutableArray *kids = [m.children mutableCopy];
    NSUInteger idx = kids.count > 0 ? kids.count - 1 : 0; // قبل «كل الفلاتر» (آخر عنصر)
    [kids insertObject:cam atIndex:idx];
    return [m menuByReplacingChildren:kids];
}

// ============================================================
//  الهوكات
// ============================================================
%hook PXCuratedLibraryShowFiltersMenuActionPerformer   // المكتبة
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
            ^(PXContentFilterState *st){ [v userDidSetAllPhotosContentFilterState:st]; CFRefreshGrid(v); });
    });
}
%end

%hook PXPhotosGridShowFiltersMenuActionPerformer       // الألبومات
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
            ^(PXContentFilterState *st){ [v setContentFilterState:st]; CFRefreshGrid(v); });
    });
}
%end
