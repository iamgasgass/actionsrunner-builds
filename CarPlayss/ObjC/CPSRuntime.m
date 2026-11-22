#import "CPSRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>

NSNotificationName const CPSStateDidChangeNotification = @"CPSStateDidChangeNotification";

static void CPSPostChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CPSStateDidChangeNotification object:nil];
    });
}

#pragma mark - CPSObjC

@implementation CPSObjC

+ (NSString *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
    } @catch (id other) {
        return [NSString stringWithFormat:@"%@", other];
    }
}

+ (id)get:(id)target selector:(SEL)sel {
    // Solo metodi realmente implementati: alcuni template CarPlay dichiarano protocolli
    // (es. CPBarButtonProviding) senza implementarne tutti i metodi.
    if (!target || !class_getInstanceMethod(object_getClass(target), sel)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (id e) {
        return nil;
    }
}

+ (void)send:(id)target selector:(SEL)sel {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

+ (void)send:(id)target selector:(SEL)sel object:(id)a {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, a);
}

+ (void)send:(id)target selector:(SEL)sel object:(id)a object:(id)b {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, a, b);
}

+ (void)send:(id)target selector:(SEL)sel object:(id)a object:(id)b object:(id)c {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(target, sel, a, b, c);
}

+ (void)send:(id)target selector:(SEL)sel object:(id)a flag:(BOOL)flag {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(target, sel, a, flag);
}

+ (void)send:(id)target selector:(SEL)sel object:(id)a integer:(NSInteger)value {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(target, sel, a, value);
}

+ (void)send:(id)target selector:(SEL)sel integer:(NSInteger)value {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, sel, value);
}

+ (void)send:(id)target selector:(SEL)sel object:(id)a region:(MKCoordinateRegion)region {
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, MKCoordinateRegion))objc_msgSend)(target, sel, a, region);
}

+ (BOOL)sendLaunch:(id)target selector:(SEL)sel application:(UIApplication *)app {
    if (!target || ![target respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(target, sel, app, @{});
}

+ (id)handlerOf:(id)object {
    if (!object) return nil;
    SEL sel = NSSelectorFromString(@"handler");
    if ([object respondsToSelector:sel]) {
        id h = ((id (*)(id, SEL))objc_msgSend)(object, sel);
        if (h) return h;
    }
    Ivar ivar = class_getInstanceVariable([object class], "_handler");
    if (ivar) return object_getIvar(object, ivar);
    return nil;
}

+ (void)invokeBlock:(id)block withObject:(id)object {
    if (!block) return;
    ((void (^)(id))block)(object);
}

+ (void)invokeBlock:(id)block withObject:(id)object integer:(NSInteger)value {
    if (!block) return;
    ((void (^)(id, NSInteger))block)(object, value);
}

+ (id)makeListCompletion:(void (^)(NSArray *))handler {
    void (^copy)(NSArray *) = [handler copy];
    return [^(NSArray *items) {
        dispatch_async(dispatch_get_main_queue(), ^{ copy(items ?: @[]); });
    } copy];
}

+ (id)makeVoidCompletion:(void (^)(void))handler {
    void (^copy)(void) = [handler copy];
    return [^{
        dispatch_async(dispatch_get_main_queue(), ^{ copy(); });
    } copy];
}

static NSString *CPSNormalizedPath(NSString *path) {
    NSString *p = [path stringByResolvingSymlinksInPath];
    if ([p hasPrefix:@"/private/"]) p = [p substringFromIndex:8];
    return p;
}

+ (NSArray<NSString *> *)classNamesInImageAtPath:(NSString *)path {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSString *wanted = CPSNormalizedPath(path);
    NSString *tail = [[path.stringByDeletingLastPathComponent lastPathComponent]
                      stringByAppendingPathComponent:path.lastPathComponent];
    const char *imageName = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *candidate = @(name);
        if ([CPSNormalizedPath(candidate) isEqualToString:wanted] || [candidate hasSuffix:tail]) {
            imageName = name;
            break;
        }
    }
    if (!imageName) return result;
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(imageName, &count);
    for (unsigned int i = 0; i < count; i++) {
        [result addObject:@(names[i])];
    }
    free((void *)names);
    return result;
}

+ (BOOL)isClass:(Class)cls conformingTo:(Protocol *)proto {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        if (class_conformsToProtocol(c, proto)) return YES;
    }
    return NO;
}

+ (id)instantiate:(Class)cls {
    if (!cls) return nil;
    return [[cls alloc] init];
}

+ (UIWindow *)makeCarWindowWithFrame:(CGRect)frame {
    UIWindow *window = nil;
    Class cls = NSClassFromString(@"CPWindow");
    if (cls) {
        @try {
            window = [(UIWindow *)[cls alloc] initWithFrame:frame];
        } @catch (id e) {
            window = nil;
        }
    }
    if (!window) window = [[UIWindow alloc] initWithFrame:frame];
    window.backgroundColor = UIColor.blackColor;
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    window.hidden = NO;
    return window;
}

@end

#pragma mark - CPSInterfaceController

static void CPSCallAppearance(id delegate, NSString *selName, CPTemplate *t, BOOL animated) {
    if (!delegate || !t) return;
    SEL sel = NSSelectorFromString(selName);
    if (![delegate respondsToSelector:sel]) return;
    @try {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(delegate, sel, t, animated);
    } @catch (id e) {}
}

static void CPSComplete(void (^completion)(BOOL, NSError *)) {
    if (!completion) return;
    void (^copy)(BOOL, NSError *) = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{ copy(YES, nil); });
}

@implementation CPSInterfaceController {
    NSMutableArray<CPTemplate *> *_cpsStack;
    CPTemplate *_cpsPresented;
    __weak id<CPInterfaceControllerDelegate> _cpsDelegate;
    BOOL _cpsPrefersDark;
}

+ (instancetype)makeController {
    // CPInterfaceController non ha un init pubblico: alloc senza init (NSObject non richiede altro).
    CPSInterfaceController *controller = [self alloc];
    [controller cps_setup];
    return controller;
}

- (void)cps_setup {
    _cpsStack = [NSMutableArray array];
    _cpsPrefersDark = YES;
}

- (void)cps_changed {
    void (^cb)(void) = self.cps_onChange;
    dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(); });
    CPSPostChange();
}

- (NSArray<CPTemplate *> *)cps_stack { return [_cpsStack copy]; }
- (CPTemplate *)cps_presented { return _cpsPresented; }

#pragma mark Proprietà di CPInterfaceController

- (id<CPInterfaceControllerDelegate>)delegate { return _cpsDelegate; }
- (void)setDelegate:(id<CPInterfaceControllerDelegate>)delegate { _cpsDelegate = delegate; }
- (BOOL)prefersDarkUserInterfaceStyle { return _cpsPrefersDark; }
- (void)setPrefersDarkUserInterfaceStyle:(BOOL)value { _cpsPrefersDark = value; [self cps_changed]; }
- (NSArray<CPTemplate *> *)templates { return [_cpsStack copy]; }
- (CPTemplate *)rootTemplate { return _cpsStack.firstObject; }
- (CPTemplate *)topTemplate { return _cpsStack.lastObject; }
- (CPTemplate *)presentedTemplate { return _cpsPresented; }

- (UITraitCollection *)carTraitCollection {
    return [UITraitCollection traitCollectionWithTraitsFromCollections:@[
        [UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomCarPlay],
        [UITraitCollection traitCollectionWithDisplayScale:2.0],
        [UITraitCollection traitCollectionWithUserInterfaceStyle:(_cpsPrefersDark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified)]
    ]];
}

#pragma mark Stack

- (void)setRootTemplate:(CPTemplate *)rootTemplate animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    if (!rootTemplate) { CPSComplete(completion); return; }
    CPTemplate *old = _cpsStack.lastObject;
    CPSCallAppearance(_cpsDelegate, @"templateWillDisappear:animated:", old, animated);
    CPSCallAppearance(_cpsDelegate, @"templateWillAppear:animated:", rootTemplate, animated);
    [_cpsStack removeAllObjects];
    [_cpsStack addObject:rootTemplate];
    [self cps_changed];
    CPSCallAppearance(_cpsDelegate, @"templateDidDisappear:animated:", old, animated);
    CPSCallAppearance(_cpsDelegate, @"templateDidAppear:animated:", rootTemplate, animated);
    CPSComplete(completion);
}

- (void)setRootTemplate:(CPTemplate *)rootTemplate animated:(BOOL)animated {
    [self setRootTemplate:rootTemplate animated:animated completion:nil];
}

- (void)pushTemplate:(CPTemplate *)templateToPush animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    if (!templateToPush) { CPSComplete(completion); return; }
    CPTemplate *old = _cpsStack.lastObject;
    CPSCallAppearance(_cpsDelegate, @"templateWillDisappear:animated:", old, animated);
    CPSCallAppearance(_cpsDelegate, @"templateWillAppear:animated:", templateToPush, animated);
    [_cpsStack addObject:templateToPush];
    [self cps_changed];
    CPSCallAppearance(_cpsDelegate, @"templateDidDisappear:animated:", old, animated);
    CPSCallAppearance(_cpsDelegate, @"templateDidAppear:animated:", templateToPush, animated);
    CPSComplete(completion);
}

- (void)pushTemplate:(CPTemplate *)templateToPush animated:(BOOL)animated {
    [self pushTemplate:templateToPush animated:animated completion:nil];
}

- (void)cps_popTo:(NSUInteger)count animated:(BOOL)animated {
    if (_cpsStack.count <= 1 || count >= _cpsStack.count) return;
    CPTemplate *old = _cpsStack.lastObject;
    CPTemplate *next = _cpsStack[count - 1];
    CPSCallAppearance(_cpsDelegate, @"templateWillDisappear:animated:", old, animated);
    CPSCallAppearance(_cpsDelegate, @"templateWillAppear:animated:", next, animated);
    [_cpsStack removeObjectsInRange:NSMakeRange(count, _cpsStack.count - count)];
    [self cps_changed];
    CPSCallAppearance(_cpsDelegate, @"templateDidDisappear:animated:", old, animated);
    CPSCallAppearance(_cpsDelegate, @"templateDidAppear:animated:", next, animated);
}

- (void)popTemplateAnimated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    [self cps_popTo:_cpsStack.count - 1 animated:animated];
    CPSComplete(completion);
}

- (void)popTemplateAnimated:(BOOL)animated {
    [self popTemplateAnimated:animated completion:nil];
}

- (void)popToRootTemplateAnimated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    [self cps_popTo:1 animated:animated];
    CPSComplete(completion);
}

- (void)popToRootTemplateAnimated:(BOOL)animated {
    [self popToRootTemplateAnimated:animated completion:nil];
}

- (void)popToTemplate:(CPTemplate *)targetTemplate animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    NSUInteger idx = [_cpsStack indexOfObjectIdenticalTo:targetTemplate];
    if (idx != NSNotFound) [self cps_popTo:idx + 1 animated:animated];
    CPSComplete(completion);
}

- (void)popToTemplate:(CPTemplate *)targetTemplate animated:(BOOL)animated {
    [self popToTemplate:targetTemplate animated:animated completion:nil];
}

- (void)presentTemplate:(CPTemplate *)templateToPresent animated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    if (!templateToPresent) { CPSComplete(completion); return; }
    CPSCallAppearance(_cpsDelegate, @"templateWillAppear:animated:", templateToPresent, animated);
    _cpsPresented = templateToPresent;
    [self cps_changed];
    CPSCallAppearance(_cpsDelegate, @"templateDidAppear:animated:", templateToPresent, animated);
    CPSComplete(completion);
}

- (void)presentTemplate:(CPTemplate *)templateToPresent animated:(BOOL)animated {
    [self presentTemplate:templateToPresent animated:animated completion:nil];
}

- (void)dismissTemplateAnimated:(BOOL)animated completion:(void (^)(BOOL, NSError *))completion {
    CPTemplate *old = _cpsPresented;
    if (old) {
        CPSCallAppearance(_cpsDelegate, @"templateWillDisappear:animated:", old, animated);
        _cpsPresented = nil;
        [self cps_changed];
        CPSCallAppearance(_cpsDelegate, @"templateDidDisappear:animated:", old, animated);
    }
    CPSComplete(completion);
}

- (void)dismissTemplateAnimated:(BOOL)animated {
    [self dismissTemplateAnimated:animated completion:nil];
}

- (void)cps_userPop {
    [self popTemplateAnimated:YES completion:nil];
}

- (void)cps_userDismiss {
    [self dismissTemplateAnimated:YES completion:nil];
}

@end

#pragma mark - CPSTemplateApplicationScene

@implementation CPSTemplateApplicationScene {
    CPSInterfaceController *_cpsController;
    UIWindow *_cpsWindow;
}

+ (instancetype)makeSceneWithController:(CPSInterfaceController *)controller window:(UIWindow *)window {
    // Nessuna UISceneSession reale: alloc senza init, il codice ospite usa solo i getter qui sotto.
    CPSTemplateApplicationScene *scene = [self alloc];
    scene->_cpsController = controller;
    scene->_cpsWindow = window;
    return scene;
}

- (CPInterfaceController *)interfaceController { return _cpsController; }
- (CPWindow *)carWindow { return (CPWindow *)_cpsWindow; }
- (id<UISceneDelegate>)delegate { return self.cps_delegate; }
- (void)setDelegate:(id<UISceneDelegate>)delegate { self.cps_delegate = delegate; }
- (UISceneActivationState)activationState { return UISceneActivationStateForegroundActive; }
- (CPContentStyle)contentStyle { return CPContentStyleDark; }
- (NSString *)title { return @"CarPlay"; }
- (void)setTitle:(NSString *)title {}
- (NSString *)description { return @"<CPTemplateApplicationScene (CarPlayss)>"; }

@end

#pragma mark - Dashboard

@implementation CPSDashboardController {
    NSArray<CPDashboardButton *> *_cpsButtons;
}

+ (instancetype)makeController {
    return [self alloc];
}

- (NSArray<CPDashboardButton *> *)shortcutButtons { return _cpsButtons ?: @[]; }

- (void)setShortcutButtons:(NSArray<CPDashboardButton *> *)shortcutButtons {
    _cpsButtons = [shortcutButtons copy];
    CPSPostChange();
}

@end

@implementation CPSDashboardScene {
    CPSDashboardController *_cpsController;
    UIWindow *_cpsWindow;
}

+ (instancetype)makeSceneWithController:(CPSDashboardController *)controller window:(UIWindow *)window {
    CPSDashboardScene *scene = [self alloc];
    scene->_cpsController = controller;
    scene->_cpsWindow = window;
    return scene;
}

- (CPDashboardController *)dashboardController { return _cpsController; }
- (UIWindow *)dashboardWindow { return _cpsWindow; }
- (id<UISceneDelegate>)delegate { return self.cps_delegate; }
- (void)setDelegate:(id<UISceneDelegate>)delegate { self.cps_delegate = delegate; }
- (UISceneActivationState)activationState { return UISceneActivationStateForegroundActive; }
- (NSString *)title { return @"Dashboard"; }
- (void)setTitle:(NSString *)title {}

@end

#pragma mark - CPSHooks

static NSBundle *gGuestBundle;
static NSBundle *gHostBundle;
static IMP gOrigMainBundle;

static NSMutableArray<NSDictionary *> *gRemoteRecords;
static NSUInteger gRemoteSeq = 0;
static NSUInteger gGuestEpoch = NSUIntegerMax;

static NSMapTable *gMapState;          // CPMapTemplate (weak) -> NSMutableDictionary
static NSMapTable *gSessionOwner;      // CPNavigationSession (weak) -> CPMapTemplate (weak)
static NSMapTable *gManeuverEstimates; // CPManeuver (weak) -> CPTravelEstimates
static NSHashTable *gNowPlayingObservers;

static IMP o_addHandler, o_addTargetAction, o_removeTarget, o_removeTargetAction;
static IMP o_showTrips, o_showTripsSelected, o_hideTrips, o_startNav, o_showPan, o_dismissPan;
static IMP o_presentAlert, o_dismissAlert, o_updateTripEstimates, o_updateTripEstimatesColor;
static IMP o_sessionManeuverEstimates, o_sessionFinish, o_sessionCancel;
static IMP o_npAddObserver, o_npRemoveObserver;

static NSMutableDictionary *CPSMapStateFor(id t) {
    NSMutableDictionary *d = [gMapState objectForKey:t];
    if (!d) {
        d = [NSMutableDictionary dictionary];
        [gMapState setObject:d forKey:t];
    }
    return d;
}

static void CPSSwizzle(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *original = method_setImplementation(m, replacement);
}

// NSBundle +mainBundle

static NSBundle *h_mainBundle(id self, SEL _cmd) {
    if (gGuestBundle) return gGuestBundle;
    return ((NSBundle *(*)(id, SEL))gOrigMainBundle)(self, _cmd);
}

// MPRemoteCommand

static void CPSRecordRemote(MPRemoteCommand *cmd, NSDictionary *extra) {
    NSMutableDictionary *rec = [extra mutableCopy];
    rec[@"cmd"] = cmd;
    rec[@"seq"] = @(gRemoteSeq++);
    @synchronized (gRemoteRecords) { [gRemoteRecords addObject:rec]; }
}

static id h_addHandler(MPRemoteCommand *self, SEL _cmd, id handler) {
    id token = ((id (*)(id, SEL, id))o_addHandler)(self, _cmd, handler);
    if (handler) CPSRecordRemote(self, @{ @"handler": [handler copy], @"token": token ?: [NSNull null] });
    return token;
}

static void h_addTargetAction(MPRemoteCommand *self, SEL _cmd, id target, SEL action) {
    ((void (*)(id, SEL, id, SEL))o_addTargetAction)(self, _cmd, target, action);
    if (target && action) CPSRecordRemote(self, @{ @"target": target, @"action": NSStringFromSelector(action), @"token": target });
}

static void CPSRemoveRemote(MPRemoteCommand *cmd, id token) {
    @synchronized (gRemoteRecords) {
        NSIndexSet *idx = [gRemoteRecords indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
            return r[@"cmd"] == cmd && (token == nil || r[@"token"] == token);
        }];
        [gRemoteRecords removeObjectsAtIndexes:idx];
    }
}

static void h_removeTarget(MPRemoteCommand *self, SEL _cmd, id target) {
    ((void (*)(id, SEL, id))o_removeTarget)(self, _cmd, target);
    CPSRemoveRemote(self, target);
}

static void h_removeTargetAction(MPRemoteCommand *self, SEL _cmd, id target, SEL action) {
    ((void (*)(id, SEL, id, SEL))o_removeTargetAction)(self, _cmd, target, action);
    CPSRemoveRemote(self, target);
}

// CPMapTemplate

static void h_showTrips(id self, SEL _cmd, NSArray *trips, id config) {
    NSMutableDictionary *s = CPSMapStateFor(self);
    s[@"trips"] = trips ?: @[];
    if (config) s[@"tripConfig"] = config; else [s removeObjectForKey:@"tripConfig"];
    CPSPostChange();
    @try { ((void (*)(id, SEL, id, id))o_showTrips)(self, _cmd, trips, config); } @catch (id e) {}
}

static void h_showTripsSelected(id self, SEL _cmd, NSArray *trips, id selected, id config) {
    NSMutableDictionary *s = CPSMapStateFor(self);
    s[@"trips"] = trips ?: @[];
    if (config) s[@"tripConfig"] = config; else [s removeObjectForKey:@"tripConfig"];
    CPSPostChange();
    @try { ((void (*)(id, SEL, id, id, id))o_showTripsSelected)(self, _cmd, trips, selected, config); } @catch (id e) {}
}

static void h_hideTrips(id self, SEL _cmd) {
    [CPSMapStateFor(self) removeObjectForKey:@"trips"];
    CPSPostChange();
    @try { ((void (*)(id, SEL))o_hideTrips)(self, _cmd); } @catch (id e) {}
}

static id h_startNav(id self, SEL _cmd, CPTrip *trip) {
    id session = nil;
    @try { session = ((id (*)(id, SEL, id))o_startNav)(self, _cmd, trip); } @catch (id e) { session = nil; }
    if (!session) {
        Class cls = NSClassFromString(@"CPNavigationSession");
        session = [cls alloc];
        Ivar iv = class_getInstanceVariable(cls, "_trip");
        if (iv && trip) object_setIvar(session, iv, trip);
    }
    NSMutableDictionary *s = CPSMapStateFor(self);
    s[@"session"] = session;
    [s removeObjectForKey:@"trips"];
    [gSessionOwner setObject:self forKey:session];
    CPSPostChange();
    return session;
}

/// Notifica asincrona al mapDelegate, come fa CarPlay dopo le transizioni dell'interfaccia.
static void CPSNotifyMapDelegate(id mapTemplate, NSString *selectorName) {
    __weak id weakTemplate = mapTemplate;
    dispatch_async(dispatch_get_main_queue(), ^{
        id t = weakTemplate;
        if (!t) return;
        id delegate = [CPSObjC get:t selector:NSSelectorFromString(@"mapDelegate")];
        SEL sel = NSSelectorFromString(selectorName);
        if (!delegate || ![delegate respondsToSelector:sel]) return;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, t); } @catch (id e) {}
    });
}

static void h_showPan(id self, SEL _cmd, BOOL animated) {
    CPSMapStateFor(self)[@"panning"] = @YES;
    CPSPostChange();
    @try { ((void (*)(id, SEL, BOOL))o_showPan)(self, _cmd, animated); } @catch (id e) {}
    CPSNotifyMapDelegate(self, @"mapTemplateDidShowPanningInterface:");
}

static void h_dismissPan(id self, SEL _cmd, BOOL animated) {
    CPSMapStateFor(self)[@"panning"] = @NO;
    CPSPostChange();
    CPSNotifyMapDelegate(self, @"mapTemplateWillDismissPanningInterface:");
    @try { ((void (*)(id, SEL, BOOL))o_dismissPan)(self, _cmd, animated); } @catch (id e) {}
    CPSNotifyMapDelegate(self, @"mapTemplateDidDismissPanningInterface:");
}

static void h_presentAlert(id self, SEL _cmd, id alert, BOOL animated) {
    if (alert) CPSMapStateFor(self)[@"alert"] = alert;
    CPSPostChange();
}

static void h_dismissAlert(id self, SEL _cmd, BOOL animated, void (^completion)(BOOL)) {
    [CPSMapStateFor(self) removeObjectForKey:@"alert"];
    CPSPostChange();
    if (completion) {
        void (^copy)(BOOL) = [completion copy];
        dispatch_async(dispatch_get_main_queue(), ^{ copy(YES); });
    }
}

static void h_updateTripEstimates(id self, SEL _cmd, id estimates, id trip) {
    if (estimates) CPSMapStateFor(self)[@"estimates"] = estimates;
    CPSPostChange();
    @try { ((void (*)(id, SEL, id, id))o_updateTripEstimates)(self, _cmd, estimates, trip); } @catch (id e) {}
}

static void h_updateTripEstimatesColor(id self, SEL _cmd, id estimates, id trip, NSInteger color) {
    if (estimates) CPSMapStateFor(self)[@"estimates"] = estimates;
    CPSPostChange();
    @try { ((void (*)(id, SEL, id, id, NSInteger))o_updateTripEstimatesColor)(self, _cmd, estimates, trip, color); } @catch (id e) {}
}

// CPNavigationSession

static void h_sessionManeuverEstimates(id self, SEL _cmd, id estimates, id maneuver) {
    if (estimates && maneuver) [gManeuverEstimates setObject:estimates forKey:maneuver];
    CPSPostChange();
    @try { ((void (*)(id, SEL, id, id))o_sessionManeuverEstimates)(self, _cmd, estimates, maneuver); } @catch (id e) {}
}

static void CPSEndSession(id session) {
    id owner = [gSessionOwner objectForKey:session];
    if (owner) {
        NSMutableDictionary *s = CPSMapStateFor(owner);
        if (s[@"session"] == session) [s removeObjectForKey:@"session"];
        [s removeObjectForKey:@"estimates"];
    }
    CPSPostChange();
}

static void h_sessionFinish(id self, SEL _cmd) {
    CPSEndSession(self);
    @try { ((void (*)(id, SEL))o_sessionFinish)(self, _cmd); } @catch (id e) {}
}

static void h_sessionCancel(id self, SEL _cmd) {
    CPSEndSession(self);
    @try { ((void (*)(id, SEL))o_sessionCancel)(self, _cmd); } @catch (id e) {}
}

// CPNowPlayingTemplate

static void h_npAddObserver(id self, SEL _cmd, id observer) {
    if (observer) [gNowPlayingObservers addObject:observer];
    @try { ((void (*)(id, SEL, id))o_npAddObserver)(self, _cmd, observer); } @catch (id e) {}
}

static void h_npRemoveObserver(id self, SEL _cmd, id observer) {
    if (observer) [gNowPlayingObservers removeObject:observer];
    @try { ((void (*)(id, SEL, id))o_npRemoveObserver)(self, _cmd, observer); } @catch (id e) {}
}

#pragma mark Selettori mancanti in CarPlay.framework

// Alcune combinazioni SDK/iOS di CarPlay.framework chiamano metodi che non esistono
// (es. -[CPNavigationWaypoint setNameVariants:] dal setter di CPTrip.destinationNameVariants).
// Per le classi di CarPlay i setter/getter sconosciuti vengono assorbiti invece di far crashare l'app.

static IMP gNSObjectMethodSignature;

static NSMethodSignature *h_cpMethodSignature(id self, SEL _cmd, SEL selector) {
    NSMethodSignature *sig = ((NSMethodSignature *(*)(id, SEL, SEL))gNSObjectMethodSignature)(self, _cmd, selector);
    if (sig) return sig;
    NSString *name = NSStringFromSelector(selector);
    NSUInteger colons = [[name componentsSeparatedByString:@":"] count] - 1;
    if ([name hasPrefix:@"set"] && colons == 1) return [NSMethodSignature signatureWithObjCTypes:"v@:@"];
    if (colons == 0) return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    return nil;
}

static void h_cpForwardInvocation(id self, SEL _cmd, NSInvocation *invocation) {
    NSLog(@"[CarPlayss] ignorato -[%@ %@] (non esiste in questa versione di CarPlay)",
          NSStringFromClass(object_getClass(self)), NSStringFromSelector(invocation.selector));
    if (invocation.methodSignature.methodReturnLength > 0 && invocation.methodSignature.methodReturnType[0] == '@') {
        id nothing = nil;
        [invocation setReturnValue:&nothing];
    }
}

static void CPSInstallCarPlayForwarding(void) {
    gNSObjectMethodSignature = class_getMethodImplementation([NSObject class], @selector(methodSignatureForSelector:));
    const char *carplayImage = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "/CarPlay.framework/CarPlay")) { carplayImage = n; break; }
    }
    if (!carplayImage) return;
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(carplayImage, &count);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls || class_getSuperclass(cls) != [NSObject class]) continue;
        class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)h_cpMethodSignature, "@@::");
        class_addMethod(cls, @selector(forwardInvocation:), (IMP)h_cpForwardInvocation, "v@:@");
    }
    free((void *)names);
}

@implementation CPSHooks

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHostBundle = [NSBundle mainBundle];
        gRemoteRecords = [NSMutableArray array];
        gMapState = [NSMapTable weakToStrongObjectsMapTable];
        gSessionOwner = [NSMapTable weakToWeakObjectsMapTable];
        gManeuverEstimates = [NSMapTable weakToStrongObjectsMapTable];
        gNowPlayingObservers = [NSHashTable weakObjectsHashTable];

        Method mb = class_getClassMethod([NSBundle class], @selector(mainBundle));
        if (mb) gOrigMainBundle = method_setImplementation(mb, (IMP)h_mainBundle);

        Class rc = [MPRemoteCommand class];
        CPSSwizzle(rc, @selector(addTargetWithHandler:), (IMP)h_addHandler, &o_addHandler);
        CPSSwizzle(rc, @selector(addTarget:action:), (IMP)h_addTargetAction, &o_addTargetAction);
        CPSSwizzle(rc, @selector(removeTarget:), (IMP)h_removeTarget, &o_removeTarget);
        CPSSwizzle(rc, @selector(removeTarget:action:), (IMP)h_removeTargetAction, &o_removeTargetAction);

        Class mt = NSClassFromString(@"CPMapTemplate");
        CPSSwizzle(mt, NSSelectorFromString(@"showTripPreviews:textConfiguration:"), (IMP)h_showTrips, &o_showTrips);
        CPSSwizzle(mt, NSSelectorFromString(@"showTripPreviews:selectedTrip:textConfiguration:"), (IMP)h_showTripsSelected, &o_showTripsSelected);
        CPSSwizzle(mt, NSSelectorFromString(@"hideTripPreviews"), (IMP)h_hideTrips, &o_hideTrips);
        CPSSwizzle(mt, NSSelectorFromString(@"startNavigationSessionForTrip:"), (IMP)h_startNav, &o_startNav);
        CPSSwizzle(mt, NSSelectorFromString(@"showPanningInterfaceAnimated:"), (IMP)h_showPan, &o_showPan);
        CPSSwizzle(mt, NSSelectorFromString(@"dismissPanningInterfaceAnimated:"), (IMP)h_dismissPan, &o_dismissPan);
        CPSSwizzle(mt, NSSelectorFromString(@"presentNavigationAlert:animated:"), (IMP)h_presentAlert, &o_presentAlert);
        CPSSwizzle(mt, NSSelectorFromString(@"dismissNavigationAlertAnimated:completion:"), (IMP)h_dismissAlert, &o_dismissAlert);
        CPSSwizzle(mt, NSSelectorFromString(@"updateTravelEstimates:forTrip:"), (IMP)h_updateTripEstimates, &o_updateTripEstimates);
        CPSSwizzle(mt, NSSelectorFromString(@"updateTravelEstimates:forTrip:withTimeRemainingColor:"), (IMP)h_updateTripEstimatesColor, &o_updateTripEstimatesColor);

        Class ns = NSClassFromString(@"CPNavigationSession");
        CPSSwizzle(ns, NSSelectorFromString(@"updateTravelEstimates:forManeuver:"), (IMP)h_sessionManeuverEstimates, &o_sessionManeuverEstimates);
        CPSSwizzle(ns, NSSelectorFromString(@"finishTrip"), (IMP)h_sessionFinish, &o_sessionFinish);
        CPSSwizzle(ns, NSSelectorFromString(@"cancelTrip"), (IMP)h_sessionCancel, &o_sessionCancel);

        CPSInstallCarPlayForwarding();

        Class np = NSClassFromString(@"CPNowPlayingTemplate");
        CPSSwizzle(np, NSSelectorFromString(@"addObserver:"), (IMP)h_npAddObserver, &o_npAddObserver);
        CPSSwizzle(np, NSSelectorFromString(@"removeObserver:"), (IMP)h_npRemoveObserver, &o_npRemoveObserver);
    });
}

+ (NSBundle *)guestBundle { return gGuestBundle; }
+ (void)setGuestBundle:(NSBundle *)bundle { gGuestBundle = bundle; }
+ (NSBundle *)hostBundle { return gHostBundle ?: [NSBundle mainBundle]; }

+ (void)markGuestEpoch {
    if (gGuestEpoch == NSUIntegerMax) gGuestEpoch = gRemoteSeq;
}

+ (NSDictionary *)latestGuestRecordFor:(MPRemoteCommand *)command {
    if (gGuestEpoch == NSUIntegerMax) return nil;
    @synchronized (gRemoteRecords) {
        for (NSDictionary *r in gRemoteRecords.reverseObjectEnumerator) {
            if (r[@"cmd"] == command && [r[@"seq"] unsignedIntegerValue] >= gGuestEpoch) return r;
        }
    }
    return nil;
}

+ (BOOL)hasGuestHandlerForCommand:(MPRemoteCommand *)command {
    return [self latestGuestRecordFor:command] != nil && command.enabled;
}

+ (BOOL)invoke:(MPRemoteCommand *)command position:(NSTimeInterval)position {
    NSDictionary *rec = [self latestGuestRecordFor:command];
    if (!rec) return NO;

    Class evClass = [MPRemoteCommandEvent class];
    if ([command isKindOfClass:[MPChangePlaybackPositionCommand class]]) evClass = [MPChangePlaybackPositionCommandEvent class];
    else if ([command isKindOfClass:[MPSkipIntervalCommand class]]) evClass = [MPSkipIntervalCommandEvent class];

    // MPRemoteCommandEvent non ha init pubblico: istanza grezza + ivar valorizzate.
    id event = [evClass alloc];
    Ivar ci = class_getInstanceVariable(evClass, "_command");
    if (ci) object_setIvar(event, ci, command);
    Ivar ti = class_getInstanceVariable(evClass, "_timestamp");
    if (ti) *(double *)((uint8_t *)(__bridge void *)event + ivar_getOffset(ti)) = [NSProcessInfo processInfo].systemUptime;
    Ivar pi = class_getInstanceVariable(evClass, "_positionTime");
    if (pi) *(double *)((uint8_t *)(__bridge void *)event + ivar_getOffset(pi)) = position;
    Ivar ii = class_getInstanceVariable(evClass, "_interval");
    if (ii && [command isKindOfClass:[MPSkipIntervalCommand class]]) {
        NSNumber *n = ((MPSkipIntervalCommand *)command).preferredIntervals.firstObject;
        *(double *)((uint8_t *)(__bridge void *)event + ivar_getOffset(ii)) = n ? n.doubleValue : 15.0;
    }

    id handler = rec[@"handler"];
    @try {
        if (handler) {
            ((MPRemoteCommandHandlerStatus (^)(id))handler)(event);
        } else {
            id target = rec[@"target"];
            SEL action = NSSelectorFromString(rec[@"action"]);
            if ([target respondsToSelector:action]) ((void (*)(id, SEL, id))objc_msgSend)(target, action, event);
        }
    } @catch (id e) {
        return NO;
    }
    return YES;
}

+ (BOOL)invokeRemoteCommand:(MPRemoteCommand *)command {
    return [self invoke:command position:0];
}

+ (BOOL)invokeChangePlaybackPosition:(NSTimeInterval)position {
    return [self invoke:[MPRemoteCommandCenter sharedCommandCenter].changePlaybackPositionCommand position:position];
}

+ (NSArray<CPTrip *> *)tripPreviewsForTemplate:(CPMapTemplate *)t { return [gMapState objectForKey:t][@"trips"] ?: @[]; }
+ (CPTripPreviewTextConfiguration *)tripTextConfigurationForTemplate:(CPMapTemplate *)t { return [gMapState objectForKey:t][@"tripConfig"]; }
+ (CPNavigationSession *)navigationSessionForTemplate:(CPMapTemplate *)t { return [gMapState objectForKey:t][@"session"]; }
+ (BOOL)isPanningForTemplate:(CPMapTemplate *)t { return [[gMapState objectForKey:t][@"panning"] boolValue]; }
+ (CPNavigationAlert *)navigationAlertForTemplate:(CPMapTemplate *)t { return [gMapState objectForKey:t][@"alert"]; }
+ (void)clearNavigationAlertForTemplate:(CPMapTemplate *)t { [[gMapState objectForKey:t] removeObjectForKey:@"alert"]; CPSPostChange(); }
+ (CPTravelEstimates *)tripEstimatesForTemplate:(CPMapTemplate *)t { return [gMapState objectForKey:t][@"estimates"]; }
+ (CPTravelEstimates *)estimatesForManeuver:(CPManeuver *)maneuver { return [gManeuverEstimates objectForKey:maneuver]; }
+ (NSArray *)nowPlayingObservers { return gNowPlayingObservers.allObjects; }

@end

#pragma mark - CPSLiveContainer

@implementation CPSLiveContainer

+ (BOOL)isHostedInLiveContainer {
    return NSClassFromString(@"LCSharedUtils") != nil;
}

/// Bundle di LiveContainer.app (NSBundle.mainBundle è stato sostituito con quello di CarPlayss).
+ (NSBundle *)lcMainBundle {
    SEL sel = NSSelectorFromString(@"lcMainBundle");
    if ([NSUserDefaults respondsToSelector:sel]) {
        NSBundle *b = ((id (*)(id, SEL))objc_msgSend)([NSUserDefaults class], sel);
        if (b) return b;
    }
    const char *exec = _dyld_get_image_name(0);
    if (!exec) return nil;
    NSString *path = [@(exec) stringByDeletingLastPathComponent];
    if ([path hasSuffix:@".appex"]) path = [[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    return [NSBundle bundleWithPath:path];
}

+ (NSString *)lcBundlePath {
    NSString *path = [self lcMainBundle].bundlePath;
    // LiveProcess (multitasking) gira dall'estensione: risali a LiveContainer.app
    if ([path hasSuffix:@".appex"]) path = [[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    return path;
}

+ (NSUserDefaults *)lcSharedDefaults {
    SEL sel = NSSelectorFromString(@"lcSharedDefaults");
    if ([NSUserDefaults respondsToSelector:sel]) {
        NSUserDefaults *d = ((id (*)(id, SEL))objc_msgSend)([NSUserDefaults class], sel);
        if (d) return d;
    }
    Class utils = NSClassFromString(@"LCSharedUtils");
    SEL groupSel = NSSelectorFromString(@"appGroupID");
    if (utils && [utils respondsToSelector:groupSel]) {
        NSString *group = ((id (*)(id, SEL))objc_msgSend)(utils, groupSel);
        if (group.length) return [[NSUserDefaults alloc] initWithSuiteName:group];
    }
    return nil;
}

+ (NSData *)certificateData {
    id value = [[self lcSharedDefaults] objectForKey:@"LCCertificateData"];
    return [value isKindOfClass:[NSData class]] ? value : nil;
}

+ (NSString *)certificatePassword {
    Class utils = NSClassFromString(@"LCSharedUtils");
    SEL sel = NSSelectorFromString(@"certificatePassword");
    if (utils && [utils respondsToSelector:sel]) {
        NSString *p = ((id (*)(id, SEL))objc_msgSend)(utils, sel);
        if (p) return p;
    }
    id value = [[self lcSharedDefaults] objectForKey:@"LCCertificatePassword"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (BOOL)loadZSign:(NSString **)error {
    if (NSClassFromString(@"ZSigner")) return YES;
    NSString *lc = [self lcBundlePath];
    NSArray *candidates = @[
        [lc stringByAppendingPathComponent:@"Frameworks/ZSign.dylib"],
        [lc stringByAppendingPathComponent:@"Frameworks/ZSign.framework/ZSign"]
    ];
    NSString *lastError = nil;
    // @rpath di ZSign punta a @executable_path/Frameworks, che dentro LiveContainer è la cartella di CarPlayss:
    // precarichiamo le sue dipendenze (es. OpenSSL.framework) dal percorso assoluto di LiveContainer.app.
    NSString *frameworks = [lc stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *dep in @[@"OpenSSL.framework/OpenSSL"]) {
        NSString *depPath = [frameworks stringByAppendingPathComponent:dep];
        if ([[NSFileManager defaultManager] fileExistsAtPath:depPath]) dlopen(depPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_LAZY);
    }
    for (NSString *path in candidates) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        for (int attempt = 0; attempt < 8; attempt++) {
            void *handle = dlopen(path.fileSystemRepresentation, RTLD_GLOBAL | RTLD_LAZY);
            if (handle && NSClassFromString(@"ZSigner")) return YES;
            const char *e = dlerror();
            lastError = e ? @(e) : @"errore sconosciuto";
            // "Library not loaded: @rpath/X.framework/X" -> carica X da LiveContainer.app/Frameworks e riprova
            NSRange r = [lastError rangeOfString:@"Library not loaded: @rpath/"];
            if (r.location == NSNotFound) break;
            NSString *rest = [lastError substringFromIndex:NSMaxRange(r)];
            NSString *missing = [[rest componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] firstObject];
            if (!missing.length) break;
            NSString *missingPath = [frameworks stringByAppendingPathComponent:missing];
            if (![[NSFileManager defaultManager] fileExistsAtPath:missingPath]) break;
            if (!dlopen(missingPath.fileSystemRepresentation, RTLD_GLOBAL | RTLD_LAZY)) {
                const char *e2 = dlerror();
                lastError = [NSString stringWithFormat:@"%@ (dipendenza %@: %s)", lastError, missing, e2 ?: "?"];
                break;
            }
        }
    }
    if (error) *error = lastError ?: [NSString stringWithFormat:@"ZSign.dylib non trovato in %@", lc];
    return NO;
}

+ (NSString *)signingUnavailableReason {
    if (![self isHostedInLiveContainer]) return @"CarPlayss non sta girando dentro LiveContainer.";
    if (![self certificateData] || ![self certificatePassword]) {
        return @"LiveContainer non ha un certificato JIT-less. In LiveContainer apri Impostazioni → JIT-Less e tocca \"Import Certificate from SideStore\" (o \"Import Certificate\").";
    }
    NSString *err = nil;
    if (![self loadZSign:&err]) return [NSString stringWithFormat:@"Impossibile caricare ZSign di LiveContainer: %@", err];
    return nil;
}

+ (BOOL)setExecutablePath:(NSString *)path {
    void (*overwrite)(const char *) = (void (*)(const char *))dlsym(RTLD_DEFAULT, "overwriteExecPath");
    if (!overwrite) return NO;
    // dyld conserva il puntatore: la stringa deve restare valida per sempre
    const char *copy = strdup(path.fileSystemRepresentation);
    @try { overwrite(copy); } @catch (id e) { return NO; }
    const char **(*processPath)(void) = (const char **(*)(void))dlsym(RTLD_DEFAULT, "_CFGetProcessPath");
    if (processPath) { const char **p = processPath(); if (p) *p = copy; }
    return YES;
}

+ (void)signAppAtPath:(NSString *)path completion:(void (^)(BOOL, NSString *))completion {
    NSString *reason = [self signingUnavailableReason];
    if (reason) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, reason); });
        return;
    }
    Class signer = NSClassFromString(@"ZSigner");
    SEL sel = NSSelectorFromString(@"signWithAppPath:bundleId:cert:pass:completionHandler:");
    if (![signer respondsToSelector:sel]) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"Versione di ZSign non supportata."); });
        return;
    }
    NSString *bundleId = [self lcMainBundle].bundleIdentifier ?: @"com.kdt.livecontainer";
    void (^handler)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, success ? nil : (error.localizedDescription ?: @"Firma non riuscita."));
        });
    };
    @try {
        ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(signer, sel, path, bundleId,
                                                           [self certificateData], [self certificatePassword], handler);
    } @catch (NSException *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e.reason ?: e.name); });
    }
}

@end

#pragma mark - CPSCrashReporter

static char gCrashPath[1024];
static char gCrashContext[2048];
static NSUncaughtExceptionHandler *gPreviousExceptionHandler;
static struct sigaction gPreviousSignal[32];

static void CPSWriteAll(int fd, const char *text) {
    if (!text) return;
    size_t len = strlen(text);
    while (len > 0) {
        ssize_t w = write(fd, text, len);
        if (w <= 0) return;
        text += w;
        len -= (size_t)w;
    }
}

static void CPSExceptionHandler(NSException *exception) {
    @try {
        NSMutableString *report = [NSMutableString string];
        [report appendFormat:@"%s\nEccezione: %@\nMotivo: %@\n\n", gCrashContext, exception.name, exception.reason];
        for (NSString *line in exception.callStackSymbols) [report appendFormat:@"%@\n", line];
        [report writeToFile:@(gCrashPath) atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
    if (gPreviousExceptionHandler) gPreviousExceptionHandler(exception);
}

static void CPSSignalHandler(int sig, siginfo_t *info, void *uap) {
    int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        CPSWriteAll(fd, gCrashContext);
        CPSWriteAll(fd, "\nSegnale: ");
        const char *name = sig == SIGSEGV ? "SIGSEGV (accesso a memoria non valida)" :
                           sig == SIGBUS ? "SIGBUS" :
                           sig == SIGABRT ? "SIGABRT (abort / fatalError / eccezione)" :
                           sig == SIGILL ? "SIGILL" :
                           sig == SIGTRAP ? "SIGTRAP (errore Swift: nil forzato, indice fuori range, fatalError…)" :
                           sig == SIGFPE ? "SIGFPE" : "altro";
        CPSWriteAll(fd, name);
        CPSWriteAll(fd, "\n\n");
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    // ripristina il gestore precedente (LiveContainer / sistema) e rilancia il segnale
    if (sig > 0 && sig < 32) sigaction(sig, &gPreviousSignal[sig], NULL);
    raise(sig);
}

@implementation CPSCrashReporter

+ (void)installWithPath:(NSString *)path {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strlcpy(gCrashPath, path.fileSystemRepresentation, sizeof(gCrashPath));
        gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&CPSExceptionHandler);
        int signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
        for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_sigaction = CPSSignalHandler;
            sa.sa_flags = SA_SIGINFO;
            sigemptyset(&sa.sa_mask);
            sigaction(signals[i], &sa, &gPreviousSignal[signals[i]]);
        }
    });
}

+ (void)setContext:(NSString *)context {
    strlcpy(gCrashContext, context.UTF8String ?: "", sizeof(gCrashContext));
}

@end
