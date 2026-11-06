// Iridia Wii U: the Objective-C face of the Cemu core for the Swift app.
// Plain Objective-C (no C++ in this header) so Swift can import it through the bridging header.
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

@interface CemuTitle : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uint64_t titleId;
@property (nonatomic) uint16_t version;
@property (nonatomic, copy) NSString *format; // "wux", "wud", "folder", ...
@end

/// One second of numbers from the emulator (zero until a game is running).
@interface CemuPerf : NSObject
@property (nonatomic) uint32_t seq;
@property (nonatomic) float fps;
@property (nonatomic) uint32_t drawsPerFrame;
@property (nonatomic) uint32_t vsyncs;
@property (nonatomic) uint32_t flips;
@property (nonatomic) uint32_t vsyncWaitMs;
@property (nonatomic) uint32_t gpuWaitMs;
@property (nonatomic) float vblankLateMs;
@property (nonatomic) uint32_t gameplaySeconds;
@end

@interface CemuBridge : NSObject

/// Sets up paths, config and the core once. `userDir` holds settings, mlc01, keys, caches (hidden from
/// Files); `gamesDir` is scanned for games; `resourcesDir` holds Cemu's resources/ and gameProfiles/.
/// Returns nil on success, otherwise a message for the player.
+ (nullable NSString *)startWithUserDir:(NSString *)userDir
                               gamesDir:(NSString *)gamesDir
                           resourcesDir:(NSString *)resourcesDir;

/// Rescans the games folder and returns the base games found (updates and DLC are used automatically).
+ (NSArray<CemuTitle *> *)scanGames;

/// Starts a game drawing into `layer` (sized in points; the layer's contentsScale gives pixels).
/// Returns nil on success, otherwise a message for the player.
+ (nullable NSString *)launchTitle:(CemuTitle *)title layer:(CAMetalLayer *)layer width:(int)width height:(int)height;

/// Ends the running game and frees its memory and graphics. The next launchTitle starts fresh.
+ (void)stopGame;

/// Pauses the game: every emulated core stops at the end of its time slice and the sound is muted.
+ (void)setPaused:(BOOL)paused;
+ (BOOL)isPaused;

+ (void)resizeWidth:(int)width height:(int)height;
+ (BOOL)isRunning;

/// GamePad state from touch controls or a game controller. Buttons use the Wii U VPAD bits.
+ (void)setButtons:(uint32_t)buttons leftX:(float)lx leftY:(float)ly rightX:(float)rx rightY:(float)ry;

/// Shows the GamePad image instead of the TV image in the main view (for games played on the GamePad).
/// Can be called before launchTitle.
+ (void)setGamePadOnMainScreen:(BOOL)on;

/// Draws the GamePad image into a second layer (sized in points), or stops it when `layer` is nil.
/// Call after launchTitle. Returns nil on success, otherwise a message.
+ (nullable NSString *)setGamePadLayer:(nullable CAMetalLayer *)layer width:(int)width height:(int)height;
+ (void)resizeGamePadWidth:(int)width height:(int)height;

/// GamePad touch screen: x, y are 0..1 on the GamePad image (0,0 top left).
+ (void)setTouchDown:(BOOL)down x:(float)x y:(float)y;

+ (CemuPerf *)perf;

/// Runtime no-JIT check: scans the address space for executable memory outside the app's loaded images.
/// Returns "PASS ..." or "FAIL ...".
+ (NSString *)noJitSelfCheck;

/// The last error the core reported (e.g. "Unable to reserve 4GB of memory"), or nil.
+ (nullable NSString *)lastCoreError;

@end

NS_ASSUME_NONNULL_END
