// CPSRuntime: host CarPlay "finto" per eseguire app CarPlay caricate a runtime.
//
// - CPSInterfaceController / CPSTemplateApplicationScene sono sottoclassi di quelle di CarPlay.framework:
//   l'app ospite le riceve come se fosse collegata a un'auto vera, e lo stack di template finisce qui.
// - CPSHooks intercetta MPRemoteCommandCenter, NSBundle.mainBundle e i metodi di CPMapTemplate /
//   CPNavigationSession / CPNowPlayingTemplate che normalmente parlano con l'auto.
// - CPSObjC racchiude le chiamate al codice ospite (eccezioni Objective-C, objc_msgSend tipizzati).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>
#import <MapKit/MapKit.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const CPSStateDidChangeNotification NS_SWIFT_NAME(cpsStateDidChange);

#pragma mark - Chiamate sicure

@interface CPSObjC : NSObject

/// Esegue il blocco; se il codice ospite lancia un'eccezione Objective-C la restituisce come testo.
+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block NS_SWIFT_NAME(catching(_:));

/// Getter che restituisce un oggetto (nil se il selettore non esiste).
+ (nullable id)get:(id)target selector:(SEL)sel NS_SWIFT_NAME(get(_:_:));

+ (void)send:(id)target selector:(SEL)sel NS_SWIFT_NAME(send(_:_:));
+ (void)send:(id)target selector:(SEL)sel object:(nullable id)a NS_SWIFT_NAME(send(_:_:_:));
+ (void)send:(id)target selector:(SEL)sel object:(nullable id)a object:(nullable id)b NS_SWIFT_NAME(send(_:_:_:_:));
+ (void)send:(id)target selector:(SEL)sel object:(nullable id)a object:(nullable id)b object:(nullable id)c NS_SWIFT_NAME(send(_:_:_:_:_:));
+ (void)send:(id)target selector:(SEL)sel object:(nullable id)a flag:(BOOL)flag NS_SWIFT_NAME(send(_:_:_:flag:));
+ (void)send:(id)target selector:(SEL)sel object:(nullable id)a integer:(NSInteger)value NS_SWIFT_NAME(send(_:_:_:integer:));
+ (void)send:(id)target selector:(SEL)sel integer:(NSInteger)value NS_SWIFT_NAME(send(_:_:integer:));
+ (void)send:(id)target selector:(SEL)sel object:(nullable id)a region:(MKCoordinateRegion)region NS_SWIFT_NAME(send(_:_:_:region:));
+ (BOOL)sendLaunch:(id)target selector:(SEL)sel application:(UIApplication *)app NS_SWIFT_NAME(sendLaunch(_:_:application:));

/// Blocco "handler" di un oggetto CarPlay (proprietà pubblica o ivar privata `_handler`).
+ (nullable id)handlerOf:(nullable id)object NS_SWIFT_NAME(handler(of:));
+ (void)invokeBlock:(id)block withObject:(nullable id)object NS_SWIFT_NAME(invoke(block:object:));
+ (void)invokeBlock:(id)block withObject:(nullable id)object integer:(NSInteger)value NS_SWIFT_NAME(invoke(block:object:integer:));

/// Blocchi di completamento da passare al codice ospite.
+ (id)makeListCompletion:(void (^)(NSArray *items))handler NS_SWIFT_NAME(makeListCompletion(_:));
+ (id)makeVoidCompletion:(void (^)(void))handler NS_SWIFT_NAME(makeVoidCompletion(_:));

/// Nomi delle classi Objective-C/Swift definite nell'immagine Mach-O caricata da `path`.
+ (NSArray<NSString *> *)classNamesInImageAtPath:(NSString *)path NS_SWIFT_NAME(classNames(inImageAtPath:));
+ (BOOL)isClass:(Class)cls conformingTo:(Protocol *)proto NS_SWIFT_NAME(isClass(_:conformingTo:));
+ (nullable id)instantiate:(Class)cls NS_SWIFT_NAME(instantiate(_:));
/// Selettori implementati direttamente da una classe (diagnostica).
+ (NSArray<NSString *> *)methodNamesOfClass:(Class)cls NS_SWIFT_NAME(methodNames(of:));

/// Crea la finestra dell'auto (CPWindow se disponibile, altrimenti UIWindow).
+ (UIWindow *)makeCarWindowWithFrame:(CGRect)frame NS_SWIFT_NAME(makeCarWindow(frame:));

@end

#pragma mark - Interfaccia CarPlay finta

@interface CPSInterfaceController : CPInterfaceController
+ (instancetype)makeController NS_SWIFT_NAME(make());
@property (nonatomic, copy, nullable) void (^cps_onChange)(void);
/// Registro delle chiamate dell'app al controller (diagnostica).
@property (nonatomic, copy, nullable) void (^cps_onLog)(NSString *message);
@property (nonatomic, readonly) NSArray<CPTemplate *> *cps_stack;
@property (nonatomic, readonly, nullable) CPTemplate *cps_presented;
/// Indietro / chiudi, come se l'utente toccasse i pulsanti di sistema.
- (void)cps_userPop;
- (void)cps_userDismiss;
@end

@interface CPSTemplateApplicationScene : CPTemplateApplicationScene
+ (instancetype)makeSceneWithController:(CPSInterfaceController *)controller
                                 window:(UIWindow *)window NS_SWIFT_NAME(make(controller:window:));
@property (nonatomic, strong, nullable) id cps_delegate;
@end

#pragma mark - Dashboard CarPlay

/// CPDashboardController simulato: conserva le scorciatoie impostate dall'app.
@interface CPSDashboardController : CPDashboardController
+ (instancetype)makeController NS_SWIFT_NAME(make());
@end

/// Scena Dashboard simulata (CPTemplateApplicationDashboardScene).
@interface CPSDashboardScene : CPTemplateApplicationDashboardScene
+ (instancetype)makeSceneWithController:(CPSDashboardController *)controller
                                 window:(UIWindow *)window NS_SWIFT_NAME(make(controller:window:));
@property (nonatomic, strong, nullable) id cps_delegate;
@end

#pragma mark - Hook

@interface CPSHooks : NSObject
+ (void)install;
@property (class, nonatomic, strong, nullable) NSBundle *guestBundle;
@property (class, nonatomic, readonly) NSBundle *hostBundle;
/// Da qui in poi i comandi remoti registrati appartengono alle app ospiti.
+ (void)markGuestEpoch;

+ (BOOL)invokeRemoteCommand:(MPRemoteCommand *)command NS_SWIFT_NAME(invoke(_:));
+ (BOOL)invokeChangePlaybackPosition:(NSTimeInterval)position NS_SWIFT_NAME(invokeChangePlaybackPosition(_:));
+ (BOOL)hasGuestHandlerForCommand:(MPRemoteCommand *)command NS_SWIFT_NAME(hasGuestHandler(for:));

+ (NSArray<CPTrip *> *)tripPreviewsForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(tripPreviews(for:));
+ (nullable CPTripPreviewTextConfiguration *)tripTextConfigurationForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(tripTextConfiguration(for:));
+ (nullable CPNavigationSession *)navigationSessionForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(navigationSession(for:));
+ (BOOL)isPanningForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(isPanning(for:));
+ (nullable CPNavigationAlert *)navigationAlertForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(navigationAlert(for:));
+ (void)clearNavigationAlertForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(clearNavigationAlert(for:));
+ (nullable CPTravelEstimates *)tripEstimatesForTemplate:(CPMapTemplate *)t NS_SWIFT_NAME(tripEstimates(for:));
+ (nullable CPTravelEstimates *)estimatesForManeuver:(CPManeuver *)maneuver NS_SWIFT_NAME(estimates(for:));
+ (NSArray *)nowPlayingObservers;
@end

#pragma mark - Firma tramite LiveContainer

/// Quando CarPlayss gira dentro LiveContainer (modalità JIT-less) usa ZSign.dylib e il certificato
/// di LiveContainer per firmare le app importate, esattamente come LiveContainer firma le sue app.
@interface CPSLiveContainer : NSObject
@property (class, nonatomic, readonly) BOOL isHostedInLiveContainer;
/// nil se la firma è possibile, altrimenti il motivo.
@property (class, nonatomic, readonly, nullable) NSString *signingUnavailableReason;
/// Fa puntare @executable_path all'eseguibile dell'app ospite (overwriteExecPath di LiveContainer).
/// Restituisce NO se non è disponibile (CarPlayss fuori da LiveContainer).
+ (BOOL)setExecutablePath:(NSString *)path NS_SWIFT_NAME(setExecutablePath(_:));
+ (void)signAppAtPath:(NSString *)path
           completion:(void (^)(BOOL success, NSString *_Nullable error))completion NS_SWIFT_NAME(signApp(atPath:completion:));
@end

#pragma mark - Registro crash

/// Scrive su file eccezioni Objective-C e segnali fatali (con lo stack), per mostrarli al riavvio.
@interface CPSCrashReporter : NSObject
+ (void)installWithPath:(NSString *)path NS_SWIFT_NAME(install(path:));
/// Testo aggiunto al rapporto (es. app e fase di caricamento in corso).
+ (void)setContext:(NSString *)context NS_SWIFT_NAME(setContext(_:));
@end

NS_ASSUME_NONNULL_END
