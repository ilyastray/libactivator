#import "libactivator.h"
#import "libactivator-private.h"
#import "LAToggleListener.h"
#import "LAMenuListener.h"
#import "LASimpleListener.h"

%config(generator=internal);

#import <CaptainHook/CaptainHook.h>
#import <SpringBoard/SpringBoard.h>

#include <dlfcn.h>

//static BOOL isInSleep;

static BOOL shouldInterceptMenuPresses;
static BOOL shouldSuppressMenuReleases;
static BOOL shouldSuppressLockSound;

static LASlideGestureWindow *leftSlideGestureWindow;
static LASlideGestureWindow *middleSlideGestureWindow;
static LASlideGestureWindow *rightSlideGestureWindow;

static LAQuickDoDelegate *sharedQuickDoDelegate;
static UIButton *quickDoButton;

__attribute__((always_inline))
static inline void LAAbortEvent(LAEvent *event)
{
	[LASharedActivator sendAbortToListener:event];
}

__attribute__((always_inline))
static inline id<LAListener> LAListenerForEventWithName(NSString *eventName)
{
	return [LASharedActivator listenerForEvent:[LAEvent eventWithName:eventName mode:[LASharedActivator currentEventMode]]];
}

@interface SpringBoard (OS40)
- (void)resetIdleTimerAndUndim;
@end

@interface SpringBoard (OS50)
- (NSArray *)appsRegisteredForVolumeEvents;
- (BOOL)isCameraApp;
@end

@interface SBAwayController (OS40)
- (void)_unlockWithSound:(BOOL)sound isAutoUnlock:(BOOL)unlock;
@end

@interface SBAlert (OS50)
- (BOOL)handleVolumeUpButtonPressed;
- (BOOL)handleVolumeDownButtonPressed;
@end

@interface VolumeControl (OS40)
+ (float)volumeStep;
- (void)_changeVolumeBy:(float)volumeAdjust;
- (void)hideVolumeHUDIfVisible;
@end

@interface SBIconController (OS40)
- (id)currentFolderIconList;
@end

@interface SBUIController (OS40)
- (BOOL)isSwitcherShowing;
@end

@interface SBUIController (OS50)
- (void)lockFromSource:(int)source;
@end

@interface SBAppSwitcherController : NSObject {
}
- (NSDictionary *)_currentIcons;
@end


#if __IPHONE_OS_VERSION_MAX_ALLOWED < __IPHONE_3_2
// Workaround to compile with 3.0 SDK
@interface SBVolumeHUDView : UIView {
}
@end
#endif

@interface SBRemoteLocalNotificationAlert : SBAlertItem {
}
+ (BOOL)isPlayingRingtone;
+ (void)stopPlayingAlertSoundOrRingtone;
@end

@interface SBAlertItemsController (OS40)
- (NSArray *)alertItemsOfClass:(Class)aClass;
@end

static void HideVolumeHUD(VolumeControl *volumeControl)
{
	if ([volumeControl respondsToSelector:@selector(hideVolumeHUDIfVisible)])
		[volumeControl hideVolumeHUDIfVisible];
	else
		[volumeControl hideHUD];
}

__attribute__((visibility("hidden")))
@interface LAVersionChecker : NSObject<UIAlertViewDelegate> {
}
@end

typedef enum {
	LASystemVersionStatusJustRight,
	LASystemVersionStatusTooCold,
	LASystemVersionStatusTooHot,
} LAVersionStatus;

@implementation LAVersionChecker

+ (LAVersionStatus)systemVersionStatus
{
	NSArray *components = [[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."];
	switch ([[components objectAtIndex:0] integerValue]) {
		case 0:
		case 1:
		case 2:
			return LASystemVersionStatusTooCold;
		case 3:
		case 4:
			return LASystemVersionStatusJustRight;
		case 5:
			return [[components objectAtIndex:1] integerValue] <= 0 ? LASystemVersionStatusJustRight : LASystemVersionStatusTooHot;
		default:
			return LASystemVersionStatusTooHot;
	}
}

+ (NSString *)versionKey
{
	return [@"LASystemVersionPrompt-" stringByAppendingString:[UIDevice currentDevice].systemVersion];
}

+ (void)checkVersion
{
	NSString *title;
	NSString *message;
	switch ([self systemVersionStatus]) {
		case LASystemVersionStatusTooCold:
			title = [LASharedActivator localizedStringForKey:@"OUT_OF_DATE_TITLE" value:@"System Version Out Of Date"];
			message = [LASharedActivator localizedStringForKey:@"OUT_OF_DATE_MESSAGE" value:@"Activator performs best on a modern version of iOS.\nPlease consider upgrading."];
			break;
		case LASystemVersionStatusTooHot:
			title = [LASharedActivator localizedStringForKey:@"TOO_NEW_TITLE" value:@"System Version Too New"];
			message = [LASharedActivator localizedStringForKey:@"TOO_NEW_MESSAGE" value:@"Activator has not been tested with this version of iOS.\nSome features may not work as intended."];
			break;
		default:
			return;
	}
	// Try to determine if we're locked, but be very careful not to call private APIs if they don't exist
	BOOL showMoreInfo = NO;
	if ([%c(SBAwayController) respondsToSelector:@selector(sharedAwayController)]) {
		SBAwayController *awayController = [%c(SBAwayController) sharedAwayController];
		if ([awayController respondsToSelector:@selector(isLocked)]) {
			if ([awayController isLocked]) {
				[self performSelector:@selector(checkVersion) withObject:nil afterDelay:0.1];
				return;
			} else {
				showMoreInfo = YES;
			}
		}
	}
	NSString *cancelButton;
	switch ([[LASharedActivator _getObjectForPreference:[self versionKey]] integerValue]) {
		case 0:
			cancelButton = [LASharedActivator localizedStringForKey:@"VERSION_PROMPT_CONTINUE" value:@"Continue"];
			break;
		case 1:
			cancelButton = [LASharedActivator localizedStringForKey:@"VERSION_PROMPT_IGNORE" value:@"Ignore"];
			break;
		default:
			return;
	}
	UIAlertView *av = [[UIAlertView alloc] init];
	av.title = title;
	av.message = message;
	av.delegate = self;
	if (showMoreInfo)
		[av addButtonWithTitle:[LASharedActivator localizedStringForKey:@"VERSION_PROMPT_MORE_INFO" value:@"More Info"]];
	[av setCancelButtonIndex:[av addButtonWithTitle:cancelButton]];
	[av show];
	[av release];
}

+ (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
	if (buttonIndex == alertView.cancelButtonIndex) {
		NSString *versionKey = [self versionKey];
		NSNumber *value = [LASharedActivator _getObjectForPreference:versionKey];
		value = [NSNumber numberWithInteger:[value integerValue]+1];
		[LASharedActivator _setObject:value forPreference:versionKey];
	} else {
		NSURL *url = [NSURL URLWithString:@"http://rpetri.ch/cydia/activator/systemversionfail/"];
		SpringBoard *app = (SpringBoard *)[UIApplication sharedApplication];
		if ([app respondsToSelector:@selector(applicationOpenURL:)])
			[app applicationOpenURL:url];
		else
			[app openURL:url];
	}
}

@end

@implementation LASlideGestureWindow

+ (LASlideGestureWindow *)leftWindow
{
	if (!leftSlideGestureWindow) {
		CGRect frame = [[UIScreen mainScreen] bounds];
		frame.origin.y += frame.size.height - kSlideGestureWindowHeight;
		frame.size.height = kSlideGestureWindowHeight;
		frame.size.width *= 0.25f;
		leftSlideGestureWindow = [[LASlideGestureWindow alloc] initWithFrame:frame eventName:LAEventNameSlideInFromBottomLeft];
	}
	return leftSlideGestureWindow;
}

+ (LASlideGestureWindow *)middleWindow
{
	if (!middleSlideGestureWindow) {
		CGRect frame = [[UIScreen mainScreen] bounds];
		frame.origin.y += frame.size.height - kSlideGestureWindowHeight;
		frame.size.height = kSlideGestureWindowHeight;
		frame.origin.x += frame.size.width * 0.25f;
		frame.size.width *= 0.5f;
		middleSlideGestureWindow = [[LASlideGestureWindow alloc] initWithFrame:frame eventName:LAEventNameSlideInFromBottom];
	}
	return middleSlideGestureWindow;
}

+ (LASlideGestureWindow *)rightWindow
{
	if (!rightSlideGestureWindow) {
		CGRect frame = [[UIScreen mainScreen] bounds];
		frame.origin.y += frame.size.height - kSlideGestureWindowHeight;
		frame.size.height = kSlideGestureWindowHeight;
		frame.origin.x += frame.size.width * 0.75f;
		frame.size.width *= 0.25f;
		rightSlideGestureWindow = [[LASlideGestureWindow alloc] initWithFrame:frame eventName:LAEventNameSlideInFromBottomRight];
	}
	return rightSlideGestureWindow;
}

+ (void)updateVisibility
{
	if (!quickDoButton) {
		[[LASlideGestureWindow leftWindow] updateVisibility];
		[[LASlideGestureWindow middleWindow] updateVisibility];
		[[LASlideGestureWindow rightWindow] updateVisibility];
	} else {
		[leftSlideGestureWindow setHidden:YES];
		[middleSlideGestureWindow setHidden:YES];
		[rightSlideGestureWindow setHidden:YES];
	}
}

- (id)initWithFrame:(CGRect)frame eventName:(NSString *)eventName
{
	if ((self = [super initWithFrame:frame])) {
		_eventName = [eventName copy];
		[self setWindowLevel:kWindowLevelTransparentTopMost];
		[self setBackgroundColor:kAlmostTransparentColor];
	}
	return self;
}

- (void)handleStatusBarChangeFromHeight:(CGFloat)fromHeight toHeight:(CGFloat)toHeight
{
	// Do Nothing
}

- (void)updateVisibility
{
	[self setHidden:[LASharedActivator assignedListenerNameForEvent:[LAEvent eventWithName:_eventName]] == nil];
}

- (void)dealloc
{
	[_eventName release];
	[super dealloc];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	hasSentSlideEvent = NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	if (!hasSentSlideEvent) {
		UITouch *touch = [touches anyObject];
		CGPoint location = [touch locationInView:self];
		if (location.y < -50.0f) {
			hasSentSlideEvent = YES;
			LASendEventWithName(_eventName);
		}
	}
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	if (hasSentSlideEvent)
		hasSentSlideEvent = NO;
	else {
		UITouch *touch = [touches anyObject];
		CGPoint location = [touch locationInView:self];
		if (location.y < -50.0f)
			LASendEventWithName(_eventName);
	}
}

@end

@implementation LAQuickDoDelegate

+ (id)sharedInstance
{
	if (!sharedQuickDoDelegate)
		sharedQuickDoDelegate = [[self alloc] init];
	return sharedQuickDoDelegate;
}

- (void)controlTouchesBegan:(UIControl *)control withEvent:(UIEvent *)event
{
	hasSentSlideEvent = NO;
}

- (void)controlTouchesMoved:(UIControl *)control withEvent:(UIEvent *)event
{
	if (!hasSentSlideEvent) {
		hasSentSlideEvent = YES;
		UITouch *touch = [[event allTouches] anyObject];
		CGFloat xFactor = [touch locationInView:control].x / [control bounds].size.width;
		if (xFactor < 0.25f)
			LASendEventWithName(LAEventNameSlideInFromBottomLeft);
		else if (xFactor < 0.75f)
			LASendEventWithName(LAEventNameSlideInFromBottom);
		else
			LASendEventWithName(LAEventNameSlideInFromBottomRight);
	}
}

- (void)controlTouchesEnded:(UIControl *)control withEvent:(UIEvent *)event
{
	hasSentSlideEvent = NO;
}

- (void)acceptEventsFromControl:(UIControl *)control
{
	[control addTarget:self action:@selector(controlTouchesBegan:withEvent:) forControlEvents:UIControlEventTouchDown];
	[control addTarget:self action:@selector(controlTouchesMoved:withEvent:) forControlEvents:UIControlEventTouchDragInside | UIControlEventTouchDragOutside];
	[control addTarget:self action:@selector(controlTouchesEnded:withEvent:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
}

@end

static LAVolumeTapWindow *volumeTapWindow;

static void ShowVolumeTapWindow(UIView *view)
{
	if ([LASharedActivator assignedListenerNameForEvent:[LAEvent eventWithName:LAEventNameVolumeDisplayTap]]) {
		UIWindow *window = [view window];
		CGRect frame = [view convertRect:view.bounds toView:window];
		CGPoint windowPosition = window.frame.origin;
		frame.origin.x += windowPosition.x;
		frame.origin.y += windowPosition.y;
		if (volumeTapWindow)
			volumeTapWindow.frame = frame;
		else {
			volumeTapWindow = [[LAVolumeTapWindow alloc] initWithFrame:frame];
			[volumeTapWindow setWindowLevel:kWindowLevelTransparentTopMost];
			[volumeTapWindow setBackgroundColor:kAlmostTransparentColor]; // Content seems to be required for swipe gestures to work in-app
		}
		[volumeTapWindow setHidden:NO];
	}
}

static void HideVolumeTapWindow()
{
	[volumeTapWindow setHidden:YES];
	[volumeTapWindow release];
	volumeTapWindow = nil;
}

@implementation LAVolumeTapWindow

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	HideVolumeTapWindow();
	if ([LASendEventWithName(LAEventNameVolumeDisplayTap) isHandled])
		HideVolumeHUD([%c(VolumeControl) sharedVolumeControl]);
}

@end

static CFAbsoluteTime lastRingerChangedTime;

%hook SpringBoard

- (void)ringerChanged:(int)newState
{
	CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
	BOOL shouldSendEvent = (currentTime - lastRingerChangedTime) < 1.0;
	lastRingerChangedTime = currentTime;
	if (shouldSendEvent) {
		%orig;
		LASendEventWithName(LAEventNameVolumeToggleMuteTwice);
	} else {
		%orig;
	}
}

static BOOL ignoreHeadsetButtonUp;

- (void)_performDelayedHeadsetAction
{
	if (LASendEventWithName(LAEventNameHeadsetButtonHoldShort).handled)
		ignoreHeadsetButtonUp = YES;
	else
		%orig;
}

- (void)headsetButtonDown:(GSEventRef)gsEvent
{
	ignoreHeadsetButtonUp = NO;
	if (LAListenerForEventWithName(LAEventNameHeadsetButtonHoldShort)) {
		%orig;
		// Require _performDelayedHeadsetAction timer, event when Voice Control isn't available
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_performDelayedHeadsetAction) object:nil];
		[self performSelector:@selector(_performDelayedHeadsetAction) withObject:nil afterDelay:0.8];
	} else {
		%orig;
	}
}

- (void)headsetButtonUp:(GSEventRef)gsEvent
{
	if (!ignoreHeadsetButtonUp) {
		LAEvent *event = [LAEvent eventWithName:LAEventNameHeadsetButtonPressSingle mode:[LASharedActivator currentEventMode]];
		[LASharedActivator sendDeactivateEventToListeners:event];
		if (!event.handled) {
			[LASharedActivator sendEventToListener:event];
			if (!event.handled) {
				%orig;
				return;
			}
		}
	}
	// Cleanup hold events
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_performDelayedHeadsetAction) object:nil];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_performDelayedHeadsetClickTimeout) object:nil];
}

- (void)_handleMenuButtonEvent
{
	if (!shouldSuppressMenuReleases) {
		// Unfortunately there isn't a better way of doing this :(
		shouldInterceptMenuPresses = YES;
		%orig;
		shouldInterceptMenuPresses = NO;
	}
}

- (BOOL)respondImmediatelyToMenuSingleTapAllowingDoubleTap:(BOOL *)allowDoubleTap
{
	// 3.2
	if (LAListenerForEventWithName(LAEventNameMenuPressDouble) || LAListenerForEventWithName(LAEventNameMenuPressTriple)) {
		%orig;
		if (allowDoubleTap)
			*allowDoubleTap = YES;
		return NO;
	} else {
		return %orig;
	}
}

- (BOOL)allowMenuDoubleTap
{
	// 3.0/3.1
	if (LAListenerForEventWithName(LAEventNameMenuPressDouble) || LAListenerForEventWithName(LAEventNameMenuPressTriple)) {
		%orig;
		return YES;
	} else {
		return %orig;
	}
}

static CFRunLoopTimerRef menuTripleTapTimer;

static void DestroyMenuTripleTapTimer()
{
	if (menuTripleTapTimer) {
		CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), menuTripleTapTimer, kCFRunLoopCommonModes);
		CFRelease(menuTripleTapTimer);
		menuTripleTapTimer = NULL;
	}
}

static void MenuTripleTapTimeoutCallback(CFRunLoopTimerRef timer, void *info);

static BOOL triplePressTimedOut;

- (void)handleMenuDoubleTap
{
	if (triplePressTimedOut) {
		triplePressTimedOut = NO;
		%orig;
	} else if ([self respondsToSelector:@selector(canShowNowPlayingHUD)] && [self canShowNowPlayingHUD]) {
		shouldAddNowPlayingButton = YES;
		%orig;
		shouldAddNowPlayingButton = NO;
	} else if (LAListenerForEventWithName(LAEventNameMenuPressTriple)) {
		shouldSuppressMenuReleases = YES;
		DestroyMenuTripleTapTimer();
		menuTripleTapTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kButtonHoldDelay, 0.0, 0, 0, MenuTripleTapTimeoutCallback, NULL);
		CFRunLoopAddTimer(CFRunLoopGetCurrent(), menuTripleTapTimer, kCFRunLoopCommonModes);
	} else if (LASendEventWithName(LAEventNameMenuPressDouble).handled) {
		shouldSuppressMenuReleases = YES;
	} else {
		%orig;
	}
}

static void MenuTripleTapTimeoutCallback(CFRunLoopTimerRef timer, void *info)
{
	DestroyMenuTripleTapTimer();
	if (!LASendEventWithName(LAEventNameMenuPressDouble).handled) {
		triplePressTimedOut = YES;
		[(SpringBoard *)UIApp handleMenuDoubleTap];
	}
}

static LAEvent *lockHoldEventToAbort;
static BOOL isWaitingForLockDoubleTap;
static NSString *formerLockEventMode;
static BOOL suppressIsLocked;

- (BOOL)isLocked
{
	if (suppressIsLocked) {
		%orig;
		return NO;
	} else {
		return %orig;
	}
}

- (void)lockButtonDown:(GSEventRef)event
{
	[self performSelector:@selector(activatorLockButtonHoldCompleted) withObject:nil afterDelay:kButtonHoldDelay];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(activatorLockButtonDoubleTapAborted) object:nil];
	if (!isWaitingForLockDoubleTap) {
		[formerLockEventMode release];
		formerLockEventMode = [[LASharedActivator currentEventMode] copy];
	}
	%orig;
}

%new
- (void)activatorFixStatusBar
{
	[[%c(SBStatusBarController) sharedStatusBarController] setIsLockVisible:NO isTimeVisible:YES];
}

static BOOL ignoreResetIdleTimerAndUndim;

- (void)resetIdleTimerAndUndim:(BOOL)something
{
	if (!ignoreResetIdleTimerAndUndim)
		%orig;
}

static void DisableLockTimer(SpringBoard *springBoard)
{
	if ([springBoard respondsToSelector:@selector(_setLockButtonTimer:)])
		[springBoard _setLockButtonTimer:nil];
	else {
		NSTimer **timer = CHIvarRef(springBoard, _lockButtonTimer, NSTimer *);
		if (timer) {
			[*timer invalidate];
			[*timer release];
			*timer = nil;
		}
	}
}

- (void)lockButtonUp:(GSEventRef)event
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(activatorLockButtonHoldCompleted) object:nil];
	if (lockHoldEventToAbort) {
		[lockHoldEventToAbort release];
		lockHoldEventToAbort = nil;
		DisableLockTimer(self);
	} else if (isWaitingForLockDoubleTap) {
		isWaitingForLockDoubleTap = NO;
		LAEvent *activatorEvent = [[[LAEvent alloc] initWithName:LAEventNameLockPressDouble mode:formerLockEventMode] autorelease];
		if ([LASharedActivator assignedListenerNameForEvent:activatorEvent] == nil)
			%orig;
		else {
			if (![formerLockEventMode isEqualToString:LAEventModeLockScreen]) {
				BOOL oldAnimationsEnabled = [UIView areAnimationsEnabled];
				[UIView setAnimationsEnabled:NO];
				SBAwayController *awayController = [%c(SBAwayController) sharedAwayController];
				[awayController setDeviceLocked:NO];
				ignoreResetIdleTimerAndUndim = YES;
				if ([awayController respondsToSelector:@selector(_unlockWithSound:isAutoUnlock:)])
					[awayController _unlockWithSound:NO isAutoUnlock:YES];
				else
					[awayController _unlockWithSound:NO];
				ignoreResetIdleTimerAndUndim = NO;
				[UIView setAnimationsEnabled:oldAnimationsEnabled];
			}
			suppressIsLocked = YES;
			[LASharedActivator sendEventToListener:activatorEvent];
			suppressIsLocked = NO;
			if ([activatorEvent isHandled]) {
				[self performSelector:@selector(activatorFixStatusBar) withObject:nil afterDelay:0.0f];
				DisableLockTimer(self);
				if ([self respondsToSelector:@selector(resetIdleTimerAndUndim)])
					[self resetIdleTimerAndUndim];
				else
					[self undim];
			} else {
				shouldSuppressLockSound = YES;
				SBUIController *uic = (SBUIController *)[%c(SBUIController) sharedInstance];
				if ([uic respondsToSelector:@selector(lockFromSource:)])
					[uic lockFromSource:0];
				else
					[uic lock];
				shouldSuppressLockSound = NO;
				%orig;
			}
		} 
	} else {
		[self performSelector:@selector(activatorLockButtonDoubleTapAborted) withObject:nil afterDelay:kButtonHoldDelay];
		isWaitingForLockDoubleTap = YES;
		%orig;
	}
}

- (void)lockButtonWasHeld
{
	if (lockHoldEventToAbort) {
		LAAbortEvent(lockHoldEventToAbort);
		[lockHoldEventToAbort release];
		lockHoldEventToAbort = nil;
	}
	%orig;
}

%new
- (void)activatorLockButtonHoldCompleted
{
	[lockHoldEventToAbort release];
	lockHoldEventToAbort = nil;
	LAEvent *event = LASendEventWithName(LAEventNameLockHoldShort);
	if ([event isHandled])
		lockHoldEventToAbort = [event retain];
}

%new
- (void)activatorLockButtonDoubleTapAborted
{
	isWaitingForLockDoubleTap = NO;
}

static CFAbsoluteTime lastShakeEventSentAt;

- (void)_showEditAlertView
{
	// iOS3.x
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (lastShakeEventSentAt + kShakeIgnoreTimeout < now) {
		if ([LASendEventWithName(LAEventNameMotionShake) isHandled]) {
			lastShakeEventSentAt = now;
			return;
		}
	}
	%orig;
}

- (void)_sendMotionEnded:(int)subtype
{
	// iOS4.0+
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (lastShakeEventSentAt + kShakeIgnoreTimeout < now) {
		if ([LASendEventWithName(LAEventNameMotionShake) isHandled]) {
			lastShakeEventSentAt = now;
			return;
		}
	}
	%orig;
}

static LAEvent *menuEventToAbort;
static BOOL justTookScreenshot;

- (void)menuButtonDown:(GSEventRef)event
{
	[self performSelector:@selector(activatorMenuButtonTimerCompleted) withObject:nil afterDelay:kButtonHoldDelay];
	justTookScreenshot = NO;
	shouldSuppressMenuReleases = NO;
	%orig;
}

- (void)menuButtonUp:(GSEventRef)event
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(activatorMenuButtonTimerCompleted) object:nil];
	if (menuTripleTapTimer) {
		DestroyMenuTripleTapTimer();
		LASendEventWithName(LAEventNameMenuPressTriple);
		NSTimer **timer = CHIvarRef(self, _menuButtonTimer, NSTimer *);
		if (timer) {
			[*timer invalidate];
			[*timer release];
			*timer = nil;
		}
	} else if (justTookScreenshot) {
		LAAbortEvent(menuEventToAbort);
		[menuEventToAbort release];
		menuEventToAbort = nil;
		%orig;
		justTookScreenshot = NO;
	} else if (menuEventToAbort || shouldSuppressMenuReleases) {
		[menuEventToAbort release];
		menuEventToAbort = nil;
		NSTimer **timer = CHIvarRef(self, _menuButtonTimer, NSTimer *);
		if (timer) {
			[*timer invalidate];
			[*timer release];
			*timer = nil;
		}
	} else {
		%orig;
	}
}

- (void)menuButtonWasHeld
{
	if (menuEventToAbort) {
		LAAbortEvent(menuEventToAbort);
		[menuEventToAbort release];
		menuEventToAbort = nil;
	}
	%orig;
}

- (void)_menuButtonWasHeld
{
	if (menuEventToAbort) {
		LAAbortEvent(menuEventToAbort);
		[menuEventToAbort release];
		menuEventToAbort = nil;
	}
	%orig;
}

%new
- (void)activatorMenuButtonTimerCompleted
{
	[menuEventToAbort release];
	LAEvent *event = LASendEventWithName(LAEventNameMenuHoldShort);
	menuEventToAbort = event.handled ? [event retain] : nil;
}

static NSUInteger lastVolumeEvent;
static CFAbsoluteTime volumeChordBeganTime;
static BOOL suppressVolumeButtonUp;
static CFRunLoopTimerRef volumeButtonUpTimer;
static BOOL isVolumeButtonDown;
static BOOL performedFirstHoldEvent;

static inline void IncreaseVolumeStep(VolumeControl *volumeControl)
{
	// MobileVolumeSound requires increaseVolume message be sent
	/*if ([volumeControl respondsToSelector:@selector(_changeVolumeBy:)] && [%c(VolumeControl) respondsToSelector:@selector(volumeStep)])
		[volumeControl _changeVolumeBy:[%c(VolumeControl) volumeStep]];
	else {*/
		[volumeControl increaseVolume];
		[volumeControl cancelVolumeEvent];
	//}
}

static inline void DecreaseVolumeStep(VolumeControl *volumeControl)
{
	// MobileVolumeSound requires decreaseVolume message be sent
	/*if ([volumeControl respondsToSelector:@selector(_changeVolumeBy:)] && [%c(VolumeControl) respondsToSelector:@selector(volumeStep)])
		[volumeControl _changeVolumeBy:-[%c(VolumeControl) volumeStep]];
	else {*/
		[volumeControl decreaseVolume];
		[volumeControl cancelVolumeEvent];
	//}
}

static void DestroyCurrentVolumeButtonUpTimer()
{
	if (volumeButtonUpTimer) {
		CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), volumeButtonUpTimer, kCFRunLoopCommonModes);
		CFRelease(volumeButtonUpTimer);
		volumeButtonUpTimer = NULL;
	}
}

static void SetupVolumeRepeatTimer(CFRunLoopTimerCallBack callback, void *info, NSTimeInterval timeInterval)
{
	DestroyCurrentVolumeButtonUpTimer();
	CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
	volumeButtonUpTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, currentTime + timeInterval, 0.0, 0, 0, callback, info);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), volumeButtonUpTimer, kCFRunLoopCommonModes);
}

static void StandardVolumeUpRepeat(CFRunLoopTimerRef timer, void *info)
{
	IncreaseVolumeStep([%c(VolumeControl) sharedVolumeControl]);
	SetupVolumeRepeatTimer(StandardVolumeUpRepeat, info, kVolumeRepeatDelay);
}

static void VolumeUpButtonHeldCallback(CFRunLoopTimerRef timer, void *info)
{
	performedFirstHoldEvent = YES;
	VolumeControl *volumeControl = [%c(VolumeControl) sharedVolumeControl];
	if ([LASendEventWithName(LAEventNameVolumeUpHoldShort) isHandled]) {
		suppressVolumeButtonUp = YES;
		HideVolumeHUD(volumeControl);
	} else {
		IncreaseVolumeStep(volumeControl);
		SetupVolumeRepeatTimer(StandardVolumeUpRepeat, info, kVolumeRepeatDelay);
	}
}

static void StandardVolumeDownRepeat(CFRunLoopTimerRef timer, void *info)
{
	DecreaseVolumeStep([%c(VolumeControl) sharedVolumeControl]);
	SetupVolumeRepeatTimer(StandardVolumeDownRepeat, info, kVolumeRepeatDelay);
}

static void VolumeDownButtonHeldCallback(CFRunLoopTimerRef timer, void *info)
{
	performedFirstHoldEvent = YES;
	DestroyCurrentVolumeButtonUpTimer();
	VolumeControl *volumeControl = [%c(VolumeControl) sharedVolumeControl];
	if ([LASendEventWithName(LAEventNameVolumeDownHoldShort) isHandled]) {
		suppressVolumeButtonUp = YES;
		HideVolumeHUD(volumeControl);
	} else {
		DecreaseVolumeStep(volumeControl);
		SetupVolumeRepeatTimer(StandardVolumeDownRepeat, info, kVolumeRepeatDelay);
	}
}

static BOOL justSuppressedNotificationSound;

- (void)volumeChanged:(GSEventRef)gsEvent
{
	if ([self respondsToSelector:@selector(appsRegisteredForVolumeEvents)]) {
		if ([[self appsRegisteredForVolumeEvents] count]) {
			%orig;
			return;
		}
	}
	if ([self respondsToSelector:@selector(isCameraApp)]) {
		if ([self isCameraApp]) {
			%orig;
			return;
		}
	}
	// Suppress ringtone
	if ([%c(SBAlert) respondsToSelector:@selector(alertWindow)]) {
		id alertWindow = [%c(SBAlert) alertWindow];
		if ([alertWindow respondsToSelector:@selector(currentDisplay)]) {
			id alertDisplay = [alertWindow currentDisplay];
			if ([alertDisplay respondsToSelector:@selector(handleVolumeEvent:)]) {
				[alertDisplay handleVolumeEvent:gsEvent];
				return;
			} else if ([alertDisplay respondsToSelector:@selector(alert)]) {
				SBAlert *alert = [alertDisplay alert];
				if ([alert respondsToSelector:@selector(handleVolumeDownButtonPressed)]) {
					switch (GSEventGetType(gsEvent)) {
						case kGSEventVolumeUpButtonDown:
							if ([alert handleVolumeUpButtonPressed]) {
								suppressVolumeButtonUp = YES;
								return;
							}
							break;
						case kGSEventVolumeDownButtonDown:
							if ([alert handleVolumeDownButtonPressed]) {
								suppressVolumeButtonUp = YES;
								return;
							}
							break;
						default:
							break;
					}
				}
			}
		}
	}
	VolumeControl *volumeControl = [%c(VolumeControl) sharedVolumeControl];
	switch (GSEventGetType(gsEvent)) {
		case kGSEventVolumeUpButtonDown: {
			if (isVolumeButtonDown) {
				DestroyCurrentVolumeButtonUpTimer();
				suppressVolumeButtonUp = YES;
				if ([LASendEventWithName(LAEventNameVolumeBothPress) isHandled])
					HideVolumeHUD(volumeControl);
				break;
			}
			isVolumeButtonDown = YES;
			suppressVolumeButtonUp = NO;
			performedFirstHoldEvent = NO;
			SetupVolumeRepeatTimer(VolumeUpButtonHeldCallback, NULL, kButtonHoldDelay);
			break;
		}
		case kGSEventVolumeUpButtonUp: {
			isVolumeButtonDown = NO;
			if (suppressVolumeButtonUp) {
				DestroyCurrentVolumeButtonUpTimer();
				volumeChordBeganTime = 0.0;
				HideVolumeHUD(volumeControl);
				break;
			}
			%orig;
			CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
			if ((currentTime - volumeChordBeganTime) > kButtonHoldDelay) {
				lastVolumeEvent = kGSEventVolumeUpButtonUp;
				volumeChordBeganTime = currentTime;
				if (!performedFirstHoldEvent) {
					if (!LASendEventWithName(LAEventNameVolumeUpPress).handled)
						IncreaseVolumeStep(volumeControl);
				}
			} else if (lastVolumeEvent == kGSEventVolumeDownButtonUp) {
				lastVolumeEvent = 0;
				LASendEventWithName(LAEventNameVolumeDownUp);
			} else {
				lastVolumeEvent = 0;
				if (!performedFirstHoldEvent)
					IncreaseVolumeStep(volumeControl);
			}
			DestroyCurrentVolumeButtonUpTimer();
			break;
		}
		case kGSEventVolumeDownButtonDown: {
			// Suppress notification alert sounds
			if ([%c(SBRemoteLocalNotificationAlert) respondsToSelector:@selector(isPlayingRingtone)] && [%c(SBRemoteLocalNotificationAlert) isPlayingRingtone]) {
				NSArray *notificationAlerts = [(SBAlertItemsController *)[%c(SBAlertItemsController) sharedInstance] alertItemsOfClass:%c(SBRemoteLocalNotificationAlert)];
				[notificationAlerts makeObjectsPerformSelector:@selector(snoozeIfPossible)];
				if ([%c(SBRemoteLocalNotificationAlert) respondsToSelector:@selector(stopPlayingAlertSoundOrRingtone)]) {
					[%c(SBRemoteLocalNotificationAlert) stopPlayingAlertSoundOrRingtone];
				}
				justSuppressedNotificationSound = YES;
				break;
			}
			if (isVolumeButtonDown) {
				DestroyCurrentVolumeButtonUpTimer();
				suppressVolumeButtonUp = YES;
				if ([LASendEventWithName(LAEventNameVolumeBothPress) isHandled])
					HideVolumeHUD(volumeControl);
				break;
			}
			isVolumeButtonDown = YES;
			suppressVolumeButtonUp = NO;
			performedFirstHoldEvent = NO;
			SetupVolumeRepeatTimer(VolumeDownButtonHeldCallback, NULL, kButtonHoldDelay);
			break;
		}
		case kGSEventVolumeDownButtonUp: {
			if (justSuppressedNotificationSound) {
				justSuppressedNotificationSound = NO;
				break;
			}
			isVolumeButtonDown = NO;
			if (suppressVolumeButtonUp) {
				DestroyCurrentVolumeButtonUpTimer();
				volumeChordBeganTime = 0.0;
				HideVolumeHUD(volumeControl);
				break;
			}
			%orig;
			CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
			if ((currentTime - volumeChordBeganTime) > kButtonHoldDelay) {
				lastVolumeEvent = kGSEventVolumeDownButtonUp;
				volumeChordBeganTime = currentTime;
				if (!performedFirstHoldEvent) {
					if (!LASendEventWithName(LAEventNameVolumeDownPress).handled)
						DecreaseVolumeStep(volumeControl);
				}
			} else if (lastVolumeEvent == kGSEventVolumeUpButtonUp) {
				lastVolumeEvent = 0;
				LASendEventWithName(LAEventNameVolumeUpDown);
			} else {
				lastVolumeEvent = 0;
				if (!performedFirstHoldEvent)
					DecreaseVolumeStep(volumeControl);
			}
			DestroyCurrentVolumeButtonUpTimer();
			break;
		}
		default:
			%orig;
			break;
	}
}

%end

%hook SBUIController

- (BOOL)clickedMenuButton
{
	if (menuEventToAbort || justTookScreenshot)
		return YES;
	NSString *mode = [LASharedActivator currentEventMode];
	LAEvent *event = [LAEvent eventWithName:LAEventNameMenuPressSingle mode:mode];
	[LASharedActivator sendDeactivateEventToListeners:event];
	if ([event isHandled])
		return YES;
	if (mode == LAEventModeSpringBoard) {
		SBIconController *iconController = (SBIconController *)[%c(SBIconController) sharedInstance];
		if ([iconController isEditing] || ([iconController respondsToSelector:@selector(currentFolderIconList)] && [iconController currentFolderIconList]))
			return %orig;
	}
	if ([%c(SBUIController) instancesRespondToSelector:@selector(isSwitcherShowing)] && [(SBUIController *)[%c(SBUIController) sharedInstance] isSwitcherShowing])
		return %orig;
	[LASharedActivator sendEventToListener:event];
	if (![event isHandled])
		return %orig;
	if ([mode isEqualToString:LAEventModeApplication]) {
		NSString *listenerName = [LASharedActivator assignedListenerNameForEvent:event];
		if (![[LASharedActivator infoDictionaryValueOfKey:@"receives-raw-events" forListenerWithName:listenerName] boolValue])
			%orig;
	}
	return YES;
}

- (void)finishLaunching
{
	[LASimpleListener sharedInstance];
	[LAToggleListener sharedInstance];
	[LAMenuListener sharedMenuListener];
	%orig;
	[LASlideGestureWindow performSelector:@selector(updateVisibility) withObject:nil afterDelay:1.0];
}

- (void)tearDownIconListAndBar
{
	%orig;
	[LASlideGestureWindow updateVisibility];
	[(LASpringBoardActivator *)LASharedActivator _eventModeChanged];
}

- (void)restoreIconList:(BOOL)animate
{
	%orig;
	[LASlideGestureWindow updateVisibility];
	[(LASpringBoardActivator *)LASharedActivator _eventModeChanged];
}

- (void)lock
{
	%orig;
	[LASlideGestureWindow updateVisibility];
	[(LASpringBoardActivator *)LASharedActivator _eventModeChanged];
}

- (void)lockFromSource:(int)source
{
	%orig;
	[LASlideGestureWindow updateVisibility];
	[(LASpringBoardActivator *)LASharedActivator _eventModeChanged];
}

- (void)_toggleSwitcher
{
	if (![self isSwitcherShowing]) {
		LAEvent *event = [LAEvent eventWithName:LAEventNameMenuPressSingle mode:LASharedActivator.currentEventMode];
		[LASharedActivator sendDeactivateEventToListeners:event];
	}
	%orig;
}

- (void)ACPowerChanged
{
	%orig;
	if ([self respondsToSelector:@selector(isOnAC)])
		LASendEventWithName([self isOnAC] ? LAEventNamePowerConnected : LAEventNamePowerDisconnected);
}

%end

%hook SBScreenShotter

- (void)saveScreenshot:(BOOL)something
{
	justTookScreenshot = YES;
	%orig;
}

%end

%hook SBIconController

- (void)scrollToIconListAtIndex:(NSInteger)index animate:(BOOL)animate
{
	if (shouldInterceptMenuPresses) {
		shouldInterceptMenuPresses = NO;
		if ([LASendEventWithName(LAEventNameMenuPressSingle) isHandled])
			return;
	}
	%orig;
}

%end

static BOOL hasSentPinchSpread;

%hook SBIconScrollView

- (id)initWithFrame:(CGRect)frame
{
	if ((self = %orig)) {
		// Add Pinch Gesture by allowing a nonstandard zoom (reuse the existing gesture)
		[self setMinimumZoomScale:0.95f];
	}
	return self;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	hasSentPinchSpread = NO;
	%orig;
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinchGesture
{
	if (!hasSentPinchSpread) {
		CGFloat scale = [pinchGesture scale];
		if (scale < kSpringBoardPinchThreshold) {
			hasSentPinchSpread = YES;
			LASendEventWithName(LAEventNameSpringBoardPinch);
		} else if (scale > kSpringBoardSpreadThreshold) {
			hasSentPinchSpread = YES;
			LASendEventWithName(LAEventNameSpringBoardSpread);
		}
	}
}

%end

%hook SBIcon

- (id)initWithDefaultSize
{
	// Enable multitouch
	if ((self = %orig)) {
		[self setMultipleTouchEnabled:YES];
	}
	return self;
}

// SBIcons don't seem to respond to the pinch gesture (and eat it for pinch gestures on superviews), so this hack is necessary. Hopefully something better can be found
static NSInteger lastTouchesCount;
static CGFloat startingDistanceSquared;

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	lastTouchesCount = 1;
	NSArray *switcherIcons = [[(SBAppSwitcherController *)[%c(SBAppSwitcherController) sharedInstance] _currentIcons] allValues];
	hasSentPinchSpread = switcherIcons && ([switcherIcons indexOfObjectIdenticalTo:self] != NSNotFound);
	%orig;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	if (!hasSentPinchSpread) {
		NSArray *allTouches = [[event allTouches] allObjects];
		NSInteger allTouchesCount = [allTouches count];
		if (allTouchesCount == 2) {
			UIWindow *window = [self window];
			UITouch *firstTouch = [allTouches objectAtIndex:0];
			UITouch *secondTouch = [allTouches objectAtIndex:1];
			CGPoint firstPoint = [firstTouch locationInView:window];
			CGPoint secondPoint = [secondTouch locationInView:window];
			CGFloat deltaX = firstPoint.x - secondPoint.x;
			CGFloat deltaY = firstPoint.y - secondPoint.y;
			CGFloat currentDistanceSquared = deltaX * deltaX + deltaY * deltaY;
			if (lastTouchesCount != 2)
				startingDistanceSquared = currentDistanceSquared;
			else if (currentDistanceSquared < startingDistanceSquared * (kSpringBoardPinchThreshold * kSpringBoardPinchThreshold)) {
				hasSentPinchSpread = YES;
				LASendEventWithName(LAEventNameSpringBoardPinch);
			} else if (currentDistanceSquared > startingDistanceSquared * (kSpringBoardSpreadThreshold * kSpringBoardSpreadThreshold)) {
				hasSentPinchSpread = YES;
				LASendEventWithName(LAEventNameSpringBoardSpread);
			}
		}
		lastTouchesCount = allTouchesCount;
	}
	%orig;
}

%end

static CGPoint statusBarTouchDown;
static BOOL hasSentStatusBarEvent;
static CFRunLoopTimerRef statusBarHoldTimer;
static CFRunLoopTimerRef statusBarTapTimer;

static void DestroyCurrentStatusBarHoldTimer()
{
	if (statusBarHoldTimer) {
		CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), statusBarHoldTimer, kCFRunLoopCommonModes);
		CFRelease(statusBarHoldTimer);
		statusBarHoldTimer = NULL;
	}
}

static void StatusBarHeldCallback(CFRunLoopTimerRef timer, void *info)
{
	DestroyCurrentStatusBarHoldTimer();
	if (!hasSentStatusBarEvent) {
		hasSentStatusBarEvent = YES;
		LASendEventWithName(LAEventNameStatusBarHold);
	}
}

static void DestroyCurrentStatusBarTapTimer()
{
	if (statusBarTapTimer) {
		CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), statusBarTapTimer, kCFRunLoopCommonModes);
		CFRelease(statusBarTapTimer);
		statusBarTapTimer = NULL;
	}
}

static void StatusBarTapCallback(CFRunLoopTimerRef timer, void *info)
{
	DestroyCurrentStatusBarTapTimer();
	if (!hasSentStatusBarEvent) {
		hasSentStatusBarEvent = YES;
		LASendEventWithName(LAEventNameStatusBarTapSingle);
	}
}

%hook SBStatusBar

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	DestroyCurrentStatusBarHoldTimer();
	DestroyCurrentStatusBarTapTimer();
	statusBarHoldTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kStatusBarHoldDelay, 0.0, 0, 0, StatusBarHeldCallback, NULL);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), statusBarHoldTimer, kCFRunLoopCommonModes);
	statusBarTouchDown = [[touches anyObject] locationInView:self];
	hasSentStatusBarEvent = NO;
	%orig;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	if (!hasSentStatusBarEvent) {
		DestroyCurrentStatusBarHoldTimer();
		DestroyCurrentStatusBarTapTimer();
		CGPoint currentPosition = [[touches anyObject] locationInView:self];
		CGFloat deltaX = currentPosition.x - statusBarTouchDown.x;
		CGFloat deltaY = currentPosition.y - statusBarTouchDown.y;
		if ((deltaX * deltaX) > (deltaY * deltaY)) {
			if (deltaX > kStatusBarHorizontalSwipeThreshold) {
				hasSentStatusBarEvent = YES;
				LASendEventWithName(LAEventNameStatusBarSwipeRight);
			} else if (deltaX < -kStatusBarHorizontalSwipeThreshold) {
				hasSentStatusBarEvent = YES;
				LASendEventWithName(LAEventNameStatusBarSwipeLeft);
			}
		} else {
			if (deltaY > kStatusBarVerticalSwipeThreshold) {
				hasSentStatusBarEvent = YES;
				LASendEventWithName(LAEventNameStatusBarSwipeDown);
			}
		}
	}
	%orig;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	DestroyCurrentStatusBarHoldTimer();
	DestroyCurrentStatusBarTapTimer();
	if (!hasSentStatusBarEvent) {
		if ([[touches anyObject] tapCount] == 2)
			LASendEventWithName(LAEventNameStatusBarTapDouble);
		else {
			statusBarTapTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + kStatusBarTapDelay, 0.0, 0, 0, StatusBarTapCallback, NULL);
			CFRunLoopAddTimer(CFRunLoopGetCurrent(), statusBarTapTimer, kCFRunLoopCommonModes);
		}
	}
	%orig;
}

%end

static NSInteger nowPlayingButtonIndex;

%hook SBNowPlayingAlertItem

- (UIAlertView *)createFrontAlertSheet
{
	nowPlayingButtonIndex = -1000;
	return %orig;
}

- (void)configure:(BOOL)front requirePasscodeForActions:(BOOL)requirePasscode
{
	if (shouldAddNowPlayingButton && nowPlayingButtonIndex == -1000) {
		LAEvent *event = [LAEvent eventWithName:LAEventNameMenuPressDouble];
		NSString *listenerName = [LASharedActivator assignedListenerNameForEvent:event];
		if (listenerName && ![listenerName isEqualToString:@"libactivator.ipod.music-controls"]) {
			%orig;
			NSString *listenerName = [LASharedActivator assignedListenerNameForEvent:event];
			NSString *title = [LASharedActivator localizedTitleForListenerName:listenerName];
			id alertSheet = [self alertSheet];
			//[alertSheet setNumberOfRows:2];
			if ([[LASharedActivator currentEventMode] isEqualToString:LAEventModeLockScreen]) {
				[[[alertSheet buttons] objectAtIndex:1] setTitle:title];
				nowPlayingButtonIndex = 1;
			} else {
				nowPlayingButtonIndex = [alertSheet addButtonWithTitle:title];
			}
			return;
		}
	}
	nowPlayingButtonIndex = -1000;
	if ([[LASharedActivator currentEventMode] isEqualToString:LAEventModeLockScreen]) {
		%orig;
		[[[[self alertSheet] buttons] objectAtIndex:1] setHidden:YES];
	} else {
		%orig;
	}
}

- (void)configureFront:(BOOL)front requirePasscodeForActions:(BOOL)requirePasscode
{
	if (shouldAddNowPlayingButton && nowPlayingButtonIndex == -1000) {
		LAEvent *event = [LAEvent eventWithName:LAEventNameMenuPressDouble];
		NSString *listenerName = [LASharedActivator assignedListenerNameForEvent:event];
		if (listenerName && ![listenerName isEqualToString:@"libactivator.ipod.music-controls"]) {
			%orig;
			NSString *listenerName = [LASharedActivator assignedListenerNameForEvent:event];
			NSString *title = [LASharedActivator localizedTitleForListenerName:listenerName];
			id alertSheet = [self alertSheet];
			//[alertSheet setNumberOfRows:2];
			if ([[LASharedActivator currentEventMode] isEqualToString:LAEventModeLockScreen]) {
				[[[alertSheet buttons] objectAtIndex:1] setTitle:title];
				nowPlayingButtonIndex = 1;
			} else {
				nowPlayingButtonIndex = [alertSheet addButtonWithTitle:title];
			}
			return;
		}
	}
	nowPlayingButtonIndex = -1000;
	if ([[LASharedActivator currentEventMode] isEqualToString:LAEventModeLockScreen]) {
		%orig;
		[[[[self alertSheet] buttons] objectAtIndex:1] setHidden:YES];
	} else {
		%orig;
	}
}

- (void)alertSheet:(id)sheet buttonClicked:(NSInteger)buttonIndex
{
	if (buttonIndex == nowPlayingButtonIndex + 1)
		LASendEventWithName(LAEventNameMenuPressDouble);
	else
		%orig;
}

%end

%hook SBVoiceControlAlert

- (id)initFromMenuButton
{
	if (menuEventToAbort) {
		LAAbortEvent(menuEventToAbort);
		[menuEventToAbort release];
		menuEventToAbort = nil;
	}
	return %orig;
}

%end

%hook SBAwayController

- (void)playLockSound
{
	if (!shouldSuppressLockSound)
		%orig;
}

- (BOOL)handleMenuButtonTap
{
	NSString *mode = [LASharedActivator currentEventMode];
	LAEvent *event = [LAEvent eventWithName:LAEventNameMenuPressSingle mode:mode];
	[LASharedActivator sendDeactivateEventToListeners:event];
	if ([event isHandled])
		return YES;
	[LASharedActivator sendEventToListener:event];
	if ([event isHandled])
		return YES;
	return %orig;
}

- (void)_sendLockStateChangedNotification
{
	[LASlideGestureWindow updateVisibility];
	%orig;
}

%end

static CFAbsoluteTime lastAwayDateLastTime;
static NSInteger lastAwayDateTapCount;

%hook SBAwayDateView

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
	if (lastAwayDateLastTime + 0.333 < currentTime)
		lastAwayDateTapCount = 0;
	lastAwayDateTapCount++;
	lastAwayDateLastTime = currentTime;
	%orig;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	lastAwayDateTapCount = 0;
	lastAwayDateLastTime = 0.0;
	%orig;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
	if (lastAwayDateLastTime + 0.333 < currentTime) {
		lastAwayDateTapCount = 0;
		lastAwayDateLastTime = 0.0;
	} else {
		lastAwayDateLastTime = currentTime;
		if (lastAwayDateTapCount == 2)
			LASendEventWithName(LAEventNameLockScreenClockDoubleTap);
	}
	%orig;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
	lastAwayDateTapCount = 0;
	lastAwayDateLastTime = 0.0;
	%orig;
}

%end

%hook VolumeControl

- (void)_createUI
{
	if (LAListenerForEventWithName(LAEventNameVolumeDisplayTap)) {
		%orig;
		UIView **view = CHIvarRef(self, _volumeView, UIView *);
		if (view && *view) {
			ShowVolumeTapWindow(*view);
		} else {
			UIWindow *window = CHIvar(self, _volumeWindow, UIWindow *);
			if (window)
				ShowVolumeTapWindow(window);
		}
	} else {
		%orig;
	}
}

- (void)_tearDown
{
	HideVolumeTapWindow();
	%orig;
}

%end

%hook SBVolumeHUDView

- (void)didMoveToWindow
{
	UIWindow *window = [self window];
	if (window)
		ShowVolumeTapWindow(self);
	else
		HideVolumeTapWindow();
	%orig;
}

%end

%hook UIFenceController

- (NSSet *)_fenceableWindows
{
	// Don't fence our slider windows that way rotation animation will be immediate
	NSMutableSet *result = [[%orig mutableCopy] autorelease];
	if (leftSlideGestureWindow)
		[result removeObject:leftSlideGestureWindow];
	if (middleSlideGestureWindow)
		[result removeObject:middleSlideGestureWindow];
	if (rightSlideGestureWindow)
		[result removeObject:rightSlideGestureWindow];
	return result;
}

%end

%ctor
{
	%init(SBIcon = objc_getClass("SBIconView") ?: objc_getClass("SBIcon"));
	[[LASpringBoardActivator alloc] init];
	[LADefaultEventDataSource sharedInstance];
	[[LAVersionChecker class] performSelector:@selector(checkVersion) withObject:nil afterDelay:0.1];
}
