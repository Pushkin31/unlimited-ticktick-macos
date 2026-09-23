#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>

// This file is compiled without ARC (-fno-objc-arc in patch.sh), so:
// - __weak / __strong qualifiers are unavailable: keep static ownership
//   explicit with retain/release where an object outlives one call;
// - autoreleased results assigned to statics must be retained or they
//   dangle after the enclosing autorelease pool drains.

// TickTick 8.0.80 added a runtime tamper/piracy check, independent of the
// isPro state itself, that pops an "Application Not Licensed" NSAlert
// ("We detected that you are using a pirated TickTick application...").
// We couldn't find or reverse the exact check that decides to show it (the
// binary is fully stripped, no local symbols left to search), so instead of
// chasing that we suppress it at its single, guaranteed choke point: every
// alert - regardless of what triggers it - has to go through NSAlert's
// presentation methods to ever become visible.
// All 41 localized titles of the piracy alert, as compile-time NSString
// literals. Literals are statically allocated constants - they live for the
// whole process and need no retain/release. That matters here because this
// file is built with -fno-objc-arc: an autoreleased NSSet (setWithObjects:)
// assigned to a static would dangle after the autorelease pool drains (seen
// as EXC_BAD_ACCESS / PAC failure in objc_msgSend(containsObject:) on 8.2.20
// and 8.2.10). Do NOT "optimize" this back into an NSSet.
static NSString *const kPatchZeroPiracyTitles[] = {
    @"Anwendung nicht lizenziert.",
    @"Aplicació no llicenciada.",
    @"Aplicación no autorizada",
    @"Aplicativo não licenciado",
    @"Aplicația nu este licențiată.",
    @"Aplikace není licencována.",
    @"Aplikacija ni licencirana.",
    @"Aplikacija nije licencirana.",
    @"Aplikasi Tidak Berlisensi.",
    @"Aplikasi Tidak Dilisensikan",
    @"Aplikácia nie je licencovaná.",
    @"Application Not Licensed",
    @"Application non licence",
    @"Applicazione non autorizzata.",
    @"Applikasjon ikke lisensiert",
    @"Applikationen er ikke licenseret.",
    @"Applikationen är inte licensierad.",
    @"Az alkalmazás nincs engedélyezve.",
    @"Ostrzeżenie o nielegalnej kopii aplikacji",
    @"Programa neleisti.",
    @"Programma nav licencēta.",
    @"Rhybudd Dros Fersiwn Anghyfreithlon",
    @"Sovellusta ei ole lisensoitu",
    @"Toepassing niet gelicentieerd",
    @"Uygulama Lisanslı Değil.",
    @"Προειδοποίηση για παραβίαση πνευματικών δικαιωμάτων",
    @"Попередження про порушення авторських прав.",
    @"Праграма не ліцэнзавана",
    @"Приложение не лицензировано",
    @"Приложението не е лицензирано.",
    @"אזהרת פרצות זכויות יוצרים",
    @"برنامہ لائسنس نہیں ہے۔",
    @"تحذير القرصنة",
    @"هشدار قانونی نسخه‌ی غیرمجاز",
    @"பிரதியேக உரிமை இல்லாத பயன்பாடு",
    @"แจ้งเตือนการละเมิดลิขสิทธิ์",
    @"Ứng dụng không được cấp phép",
    @"ライセンスされていないアプリケーション",
    @"盗版警告",
    @"盜版警告",
    @"해적판을 경고",
    nil, // array terminator
};

static BOOL patchzero_alert_is_piracy_warning(NSAlert *alert) {
    NSString *title = alert.messageText ?: @"";
    NSString *info = alert.informativeText ?: @"";

    for (NSUInteger i = 0; kPatchZeroPiracyTitles[i] != nil; i++) {
        if ([title isEqualToString:kPatchZeroPiracyTitles[i]]) {
            return YES;
        }
    }

    // Fallbacks: the piracy wording in the informative body plus the
    // "Download TickTick" button are the two distinguishing features of this
    // alert. Cover the Latin/Cyrillic/CJK keywords present in 8.2.10.
    NSString *lowerTitle = title.lowercaseString;
    NSString *lowerInfo = info.lowercaseString;
    BOOL mentionsTickTickInInfo = [lowerInfo containsString:@"ticktick"];
    BOOL piracyKeyword = [lowerInfo containsString:@"pirat"]
        || [lowerInfo containsString:@"пират"]
        || [lowerInfo containsString:@"raubkopiert"]
        || [lowerInfo containsString:@"bajak"]
        || [lowerInfo containsString:@"illegal"]
        || [lowerInfo containsString:@"nelegal"]
        || [lowerInfo containsString:@"盗版"]
        || [lowerInfo containsString:@"海賊"]
        || [lowerInfo containsString:@"해적"]
        || [lowerTitle containsString:@"licens"]
        || [lowerTitle containsString:@"лицензирован"];
    if (mentionsTickTickInInfo && piracyKeyword) {
        return YES;
    }

    return NO;
}

// Answering either button on the alert (verified by hand for Cancel, and by
// log for "Download TickTick" - no crash report either time, just a clean
// exit) is followed by the app quitting on its own shortly after. That means
// this isn't the alert's response causing it - something unconditionally
// terminates the process once the tamper check has run, regardless of what
// the user chooses. Block termination for a short window after we see the
// alert so that call fails silently instead, then let it work normally again
// so a real user quit (Cmd+Q, Dock menu) still works.
//
// This check re-runs periodically in the background (observed ~6 times over
// 2 minutes of idling, roughly every 20s), re-closing every window each
// time. An earlier 15s block window was long enough to routinely still be
// active when a real Cmd+Q/red-close-button happened, making quit look
// randomly broken. The actual close/terminate calls land within
// milliseconds of the alert being answered (observed 2ms later in testing),
// so a couple of seconds of margin is plenty and leaves far less window for
// collateral blocking of a genuine user quit.
static volatile BOOL patchzero_block_termination = NO;

static void patchzero_start_termination_block_window(void) {
    patchzero_block_termination = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_block_termination = NO;
    });
}

// The tamper check closes/hides every window as part of its own shutdown
// sequence before calling terminate:, which we block. Trying to also block
// the window close/orderOut itself was tried and made things much worse: the
// check re-runs periodically, and blocking its close made it retry in a
// tight ~200-300ms loop (observed directly in the log) instead of its normal
// ~20s cadence, pegging the main thread - that's what was actually causing
// Cmd+Q and the menu bar icon to just beep, not anything inherently broken.
// So instead: let close/orderOut proceed normally (satisfies whatever the
// check's own bookkeeping expects, avoiding the retry storm) and re-show the
// window a moment afterward.
// Window number of the last suppressed piracy alert, kept so the reopen pass
// below does not raise an empty NSAlert window over the app's real UI.
// Stored as an integer (not a pointer): the build uses manual reference
// counting (-fno-objc-arc), where __weak is unavailable, and a raw pointer
// could dangle; a window number is just a scalar and never dangles.
static NSInteger gPatchZeroSuppressedWindowNumber = 0;

// Main menu bar protection: the tamper check (or our own window juggling)
// can leave the app's main menu cleared, which is what makes "About
// TickTick", "Close" and every other menu item dead. Every legit menu
// operation goes through setMainMenu:; we let non-empty replacements
// through (app might legitimately rebuild menus) but reject nil and empty
// menus, and immediately restore a captured copy so the bar never goes
// permanently dead.
static NSMenu *gPatchZeroProtectedMenu = nil; // strong; set once, never released (process lifetime)

@implementation NSApplication (PatchZeroProtectMainMenu)

- (void)patched_setMainMenu:(NSMenu *)menu {
    if (menu == nil || menu.numberOfItems == 0) {
        if (gPatchZeroProtectedMenu != nil && [self mainMenu] != gPatchZeroProtectedMenu) {
            NSLog(@"[PatchZero] Blocked clearing of main menu (tamper check), restoring.");
            [self patched_setMainMenu:gPatchZeroProtectedMenu];
        }
        return; // refuse to clear the menu
    }
    if (gPatchZeroProtectedMenu == nil) {
        gPatchZeroProtectedMenu = [menu retain];
    }
    [self patched_setMainMenu:menu];
}

@end

// Re-enable every menu item that has an action (recursively through
// submenus). The tamper check disables items via setEnabled:NO; this is
// called on each suppression so the menu bar comes back alive. Items
// without actions are left untouched.
static void patchzero_enable_menu_items(NSMenu *menu) {
    if (menu == nil) {
        return;
    }
    for (NSMenuItem *item in [menu itemArray]) {
        if (item.hasSubmenu) {
            patchzero_enable_menu_items(item.submenu);
        }
        if (item.action != NULL) {
            item.enabled = YES;
        }
    }
}

// Hook setActivationPolicy: so the tamper check cannot demote the app to
// Prohibited/Accessory (which removes the global menu bar and makes dock
// clicks misbehave). Legit app usage of Accessory (e.g. hiding to the
// menu bar extra) would be blocked too, but TickTick runs as a regular
// windowed app, so pin it to Regular.
@implementation NSApplication (PatchZeroProtectActivationPolicy)

- (void)patched_setActivationPolicy:(NSApplicationActivationPolicy)policy {
    if (policy != NSApplicationActivationPolicyRegular) {
        NSLog(@"[PatchZero] Blocked setActivationPolicy:%ld (tamper check), keeping Regular.", (long)policy);
        policy = NSApplicationActivationPolicyRegular;
    }
    [self patched_setActivationPolicy:policy];
}

@end

static void patchzero_install_menu_protection(void) {
    Class cls = [NSApplication class];
    Method origMainMenu = class_getInstanceMethod(cls, @selector(setMainMenu:));
    Method replMainMenu = class_getInstanceMethod(cls, @selector(patched_setMainMenu:));
    Method origPolicy = class_getInstanceMethod(cls, @selector(setActivationPolicy:));
    Method replPolicy = class_getInstanceMethod(cls, @selector(patched_setActivationPolicy:));
    if (origMainMenu && replMainMenu) {
        method_exchangeImplementations(origMainMenu, replMainMenu);
        // Seed the protected menu with whatever the app has right now.
        if (gPatchZeroProtectedMenu == nil) {
            gPatchZeroProtectedMenu = [[NSApplication sharedApplication].mainMenu retain];
        }
        NSLog(@"[PatchZero] Hooked setMainMenu: (menu bar protection).");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook setMainMenu:.");
    }
    if (origPolicy && replPolicy) {
        method_exchangeImplementations(origPolicy, replPolicy);
        NSLog(@"[PatchZero] Hooked setActivationPolicy: (pinned to Regular).");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook setActivationPolicy:.");
    }
}

// Rolling snapshot of window numbers that are actually visible and not
// miniaturized, refreshed every 0.5s. The reopen pass below uses this to
// distinguish "windows the tamper check just hid" (show them again) from
// "windows the user closed/minimized on purpose" (leave them alone).
#define kPatchZeroMaxTrackedWindows 64
static NSInteger gPatchZeroTrackedWindowNumbers[kPatchZeroMaxTrackedWindows];
static int gPatchZeroTrackedWindowCount = 0;

static void patchzero_snapshot_visible_windows(void) {
    gPatchZeroTrackedWindowCount = 0;
    for (NSWindow *window in [NSApplication sharedApplication].windows) {
        if (!window.isVisible || window.isMiniaturized) {
            continue;
        }
        if (gPatchZeroTrackedWindowCount >= kPatchZeroMaxTrackedWindows) {
            break;
        }
        gPatchZeroTrackedWindowNumbers[gPatchZeroTrackedWindowCount++] = window.windowNumber;
    }
}

static BOOL patchzero_is_window_number_tracked(NSInteger windowNumber) {
    for (int i = 0; i < gPatchZeroTrackedWindowCount; i++) {
        if (gPatchZeroTrackedWindowNumbers[i] == windowNumber) {
            return YES;
        }
    }
    return NO;
}

static void patchzero_restore_activation_and_menu(void) {
    NSApplication *app = [NSApplication sharedApplication];
    if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
        NSLog(@"[PatchZero] Tamper check left app non-regular activation policy, restoring.");
        app.activationPolicy = NSApplicationActivationPolicyRegular;
    }
    if (gPatchZeroProtectedMenu != nil && app.mainMenu != gPatchZeroProtectedMenu) {
        NSLog(@"[PatchZero] Main menu was swapped out, restoring captured menu.");
        [app setMainMenu:gPatchZeroProtectedMenu];
    }
    patchzero_enable_menu_items(gPatchZeroProtectedMenu);
}

static void patchzero_reopen_windows_shortly(void) {
    BOOL snapshotEmpty = (gPatchZeroTrackedWindowCount == 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_restore_activation_and_menu();
        // The tamper check can hide the whole app (NSApp hide:) instead of
        // just windows; bring it back so the UI actually reappears.
        if ([[NSApplication sharedApplication] isHidden]) {
            NSLog(@"[PatchZero] App hidden by tamper check, unhiding.");
            [[NSApplication sharedApplication] unhide:nil];
        }
        for (NSWindow *window in [NSApplication sharedApplication].windows) {
            // Skip the suppressed piracy alert's own (empty) window - it is
            // created as a side effect of the alert lifecycle and would
            // otherwise pop up blank right after we suppressed the alert.
            if ([window windowNumber] == gPatchZeroSuppressedWindowNumber) {
                continue;
            }
            // Normal path: only windows that were visible right before the
            // tamper tick get re-shown (user-closed windows fall out of the
            // snapshot). If the snapshot is still empty (very first tamper
            // tick arrives before the 0.5s snapshot timer has run), fall
            // back to re-showing every window that is either still visible
            // or minimized - minimize() does not always leave isVisible=YES
            // so both flags are checked; only fully closed windows (both
            // NO) are left alone.
            if (!snapshotEmpty && !patchzero_is_window_number_tracked(window.windowNumber)) {
                continue;
            }
            if (snapshotEmpty && !window.isVisible && !window.isMiniaturized) {
                continue;
            }
            // The tamper check minimizes windows it hides. Bring them back
            // out of the Dock instead of leaving them collapsed on first
            // launch.
            if (window.isMiniaturized) {
                [window deminiaturize:nil];
            }
            // Show without touching the key window: makeKeyAndOrderFront
            // here stole focus from a window the user just opened (e.g. the
            // premium page - the alert is intercepted before that window
            // becomes key, and the deferred reopen then yanks focus back to
            // the previously-key one).
            [window orderFront:nil];
        }
        // Reactivate only if the app was already active: unconditional
        // activateIgnoringOtherApps:YES stole focus from the user's frontmost
        // app on every tamper tick (flicker).
        if ([[NSApplication sharedApplication] isActive]) {
            [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
        }
    });
}

// Minimization guard: the tamper check minimizes the main window
// asynchronously (often AFTER our 0.4s reopen has already run), so the
// window ends up collapsed on first launch with no reopen scheduled for
// ~20s. While the guard is armed, any window that gets miniaturized is
// immediately restored. Armed right after each alert suppression (the
// check minimizes right after it alerts) and for the first seconds after
// launch.
static volatile BOOL gPatchZeroMinimizeGuardArmed = NO;

static void patchzero_arm_minimize_guard(double seconds) {
    gPatchZeroMinimizeGuardArmed = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gPatchZeroMinimizeGuardArmed = NO;
    });
}

// Block minimize: while the guard is armed, refuse miniaturize: outright
// (returns without calling the original). Blocking BEFORE the animation
// runs is what actually stops the flicker - restoring after
// NSWindowDidMiniaturizeNotification (previous approach) still shows the
// collapse/restore cycle as a visible flicker.
@implementation NSWindow (PatchZeroBlockMinimize)

- (void)patched_miniaturize:(id)sender {
    if (gPatchZeroMinimizeGuardArmed) {
        NSLog(@"[PatchZero] Minimize guard: blocked miniaturize: on window %ld.", (long)[self windowNumber]);
        return;
    }
    [self patched_miniaturize:sender];
}

@end

// Tamper check hides windows via orderOut:/close: right after the alert
// (log evidence: zero miniaturize: calls, visible flicker). Blocking those
// outright provokes a 200-300ms retry storm (observed by the original
// author), so instead: let the hide happen (the check's bookkeeping is
// satisfied, no storm) and orderFront the window in the SAME call, before
// the next display refresh - no frame is ever rendered without the window,
// so nothing visibly blinks. Only while the guard is armed.
//
// Restore conditions: guard armed; a real on-screen window (number >= 0);
// not the suppressed alert's own window; and it was visible (in the recent
// snapshot or on screen right now). The alert's window reports windowNumber
// -1 before it is ever shown - "restoring" it pops the piracy alert back
// up (seen in the 8.2.20 log: "ordered out window -1" at suppression time
// was our OWN hide call being instant-restored).
@implementation NSWindow (PatchZeroInstantRestore)

- (void)patched_orderOut:(id)sender {
    if (gPatchZeroMinimizeGuardArmed
        && [self windowNumber] >= 0
        && [self windowNumber] != gPatchZeroSuppressedWindowNumber
        && (patchzero_is_window_number_tracked([self windowNumber]) || self.isVisible)) {
        NSLog(@"[PatchZero] Tamper check ordered out window %ld; restoring same turn.", (long)[self windowNumber]);
        [self patched_orderOut:sender];
        [self orderFront:nil];
        return;
    }
    [self patched_orderOut:sender];
}

- (void)patched_close:(id)sender {
    if (gPatchZeroMinimizeGuardArmed
        && [self windowNumber] >= 0
        && [self windowNumber] != gPatchZeroSuppressedWindowNumber
        && (patchzero_is_window_number_tracked([self windowNumber]) || self.isVisible)) {
        NSLog(@"[PatchZero] Tamper check closed window %ld; restoring same turn.", (long)[self windowNumber]);
        [self patched_close:sender];
        if (self.isMiniaturized) {
            [self deminiaturize:nil];
        }
        [self orderFront:nil];
        return;
    }
    [self patched_close:sender];
}

@end

static void patchzero_install_minimize_blocker(void) {
    Class cls = [NSWindow class];
    Method orig = class_getInstanceMethod(cls, @selector(miniaturize:));
    Method repl = class_getInstanceMethod(cls, @selector(patched_miniaturize:));
    if (orig && repl) {
        method_exchangeImplementations(orig, repl);
        NSLog(@"[PatchZero] Hooked NSWindow miniaturize: (block-while-armed).");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook NSWindow miniaturize:.");
    }
    Method origOut = class_getInstanceMethod(cls, @selector(orderOut:));
    Method replOut = class_getInstanceMethod(cls, @selector(patched_orderOut:));
    if (origOut && replOut) {
        method_exchangeImplementations(origOut, replOut);
        NSLog(@"[PatchZero] Hooked NSWindow orderOut: (instant restore).");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook NSWindow orderOut:.");
    }
    Method origClose = class_getInstanceMethod(cls, @selector(close));
    Method replClose = class_getInstanceMethod(cls, @selector(patched_close:));
    if (origClose && replClose) {
        method_exchangeImplementations(origClose, replClose);
        NSLog(@"[PatchZero] Hooked NSWindow close (instant restore).");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook NSWindow close.");
    }
}

static void patchzero_install_minimize_guard(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidMiniaturizeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (!gPatchZeroMinimizeGuardArmed) {
            return;
        }
        NSWindow *window = [note object];
        if (![window isKindOfClass:[NSWindow class]] || !window.isMiniaturized) {
            return;
        }
        if ([window windowNumber] == gPatchZeroSuppressedWindowNumber) {
            return; // still the alert's own window; let it be
        }
        NSLog(@"[PatchZero] Minimize guard: restoring window %ld minimized by tamper check.", (long)[window windowNumber]);
        [window deminiaturize:nil];
        [window orderFront:nil];
    }];
    NSLog(@"[PatchZero] Installed window minimize guard.");
}

@interface NSAlert (PatchZeroWindowAccess)
- (NSWindow *)window;
@end

static void patchzero_hide_suppressed_alert_window(NSAlert *alert) {
    NSWindow *alertWindow = nil;
    if ([alert respondsToSelector:@selector(window)]) {
        @try {
            alertWindow = [alert window];
        } @catch (NSException *exception) {
            alertWindow = nil;
        }
    }
    if (alertWindow) {
        [alertWindow orderOut:nil];
        gPatchZeroSuppressedWindowNumber = [alertWindow windowNumber];
    }
}

// Confirmed by hand: clicking "Cancel" on this alert quits the app outright.
// The only other button is "Download TickTick" (opens the App Store page),
// which is the one path the alert's own text implies exists ("Continue using
// untrusted app may result in a loss of data" - wording that only makes
// sense if some button lets the session keep running). Answering with that
// button instead of Cancel.
@implementation NSAlert (PatchZeroSuppressPiracyWarning)

- (NSModalResponse)patched_runModal {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (runModal), answering Download TickTick.");
        patchzero_hide_suppressed_alert_window(self);
        patchzero_start_termination_block_window();
        patchzero_arm_minimize_guard(3.0);
        patchzero_reopen_windows_shortly();
        return NSAlertFirstButtonReturn;
    }
    return [self patched_runModal];
}

- (void)patched_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (sheet), answering Download TickTick.");
        patchzero_hide_suppressed_alert_window(self);
        patchzero_start_termination_block_window();
        patchzero_arm_minimize_guard(3.0);
        patchzero_reopen_windows_shortly();
        if (handler) {
            handler(NSAlertFirstButtonReturn);
        }
        return;
    }
    [self patched_beginSheetModalForWindow:sheetWindow completionHandler:handler];
}

@end

@implementation NSApplication (PatchZeroBlockForcedQuit)

- (void)patched_terminate:(id)sender {
    if (patchzero_block_termination) {
        NSLog(@"[PatchZero] Blocked an app termination request during the post-tamper-check window.");
        return;
    }
    [self patched_terminate:sender];
}

@end

// Since Cmd+Q and the menu bar icon reportedly stopped working reliably
// (both beep instead of doing anything - a symptom of a disabled/broken menu
// item or action, not something our blocking above would itself cause), add
// a hard fallback: if Cmd+Q is pressed and the process is still alive a
// second later, force-exit directly rather than depend on whatever's wired
// up (and possibly broken) in the app's own quit path. If the app's normal
// quit already succeeded in that second, the process is gone and this never
// fires.
static void patchzero_install_quit_safety_valve(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        BOOL isCommandQ = (event.modifierFlags & NSEventModifierFlagCommand)
            && [event.charactersIgnoringModifiers isEqualToString:@"q"];
        if (isCommandQ) {
            NSLog(@"[PatchZero] Cmd+Q seen; will force-quit in 1s if the app hasn't quit by itself.");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSLog(@"[PatchZero] App still alive 1s after Cmd+Q; forcing exit.");
                exit(0);
            });
        }
        return event;
    }];
}

// "Download TickTick" opens the App Store page in the default browser as a
// side effect. Swallow just that one URL so launching doesn't also pop open
// a browser tab every time; everything else still opens normally.
@implementation NSWorkspace (PatchZeroSuppressAppStoreLink)

- (BOOL)patched_openURL:(NSURL *)url {
    if ([url.host containsString:@"apps.apple.com"] || [url.host containsString:@"itunes.apple.com"]) {
        NSLog(@"[PatchZero] Suppressed opening App Store URL: %@", url);
        return YES;
    }
    return [self patched_openURL:url];
}

@end

static void patchzero_install_piracy_warning_suppression(void) {
    Class cls = [NSAlert class];
    SEL originalSelectors[] = {
        @selector(runModal),
        @selector(beginSheetModalForWindow:completionHandler:)
    };
    SEL patchedSelectors[] = {
        @selector(patched_runModal),
        @selector(patched_beginSheetModalForWindow:completionHandler:)
    };
    for (int i = 0; i < 2; i++) {
        Method originalMethod = class_getInstanceMethod(cls, originalSelectors[i]);
        Method patchedMethod = class_getInstanceMethod(cls, patchedSelectors[i]);
        if (originalMethod && patchedMethod) {
            method_exchangeImplementations(originalMethod, patchedMethod);
        }
    }

    Class workspaceCls = [NSWorkspace class];
    Method originalOpenURL = class_getInstanceMethod(workspaceCls, @selector(openURL:));
    Method patchedOpenURL = class_getInstanceMethod(workspaceCls, @selector(patched_openURL:));
    if (originalOpenURL && patchedOpenURL) {
        method_exchangeImplementations(originalOpenURL, patchedOpenURL);
    }

    Class appCls = [NSApplication class];
    Method originalTerminate = class_getInstanceMethod(appCls, @selector(terminate:));
    Method patchedTerminate = class_getInstanceMethod(appCls, @selector(patched_terminate:));
    if (originalTerminate && patchedTerminate) {
        method_exchangeImplementations(originalTerminate, patchedTerminate);
    }

    NSLog(@"[PatchZero] Hooked NSAlert to suppress the piracy warning.");
}

@interface TTUserModel : NSObject
- (void)setIsPro:(BOOL)isPro;
- (BOOL)isPro;
- (void)setProEndDate:(NSDate *)date;
- (NSDate *)proEndDate;
@end

@implementation NSObject (TTUserModelPatch)

- (void)patched_setIsPro:(BOOL)isPro {
    // Always set as true (or false based on the prompt "pro=false / proEndDate=1990" - the Frida script sets args[2] = proValue (which is 1), so passing true. Wait, the Frida log says "-> false" but proValue is 0x1, which is true! Let's set it to YES for pro).
    // Actually the prompt says "isPro] ... -> false" in the log but `ptr('0x1')` is YES in Objective-C. Let's force it to YES to simulate Pro, or NO to simulate non-pro. 
    // Wait, the frida script: `const proValue = ptr('0x1');` `args[2] = proValue;` `retval.replace(proValue);` - that means it forces it to `1` which is `YES`/`true`. The console log just hardcoded the string "false" by mistake in the original script!
    [self patched_setIsPro:YES]; 
}

- (BOOL)patched_isPro {
    return YES;
}

- (void)patched_setProEndDate:(NSDate *)date {
    NSDate *forcedDate = [NSDate dateWithTimeIntervalSince1970:4070908800]; // 2098 or so
    [self patched_setProEndDate:forcedDate];
}

- (NSDate *)patched_proEndDate {
    return [NSDate dateWithTimeIntervalSince1970:4070908800];
}

@end

// Recent TickTick builds moved user/subscription state off the
// TTUserModel/TTUser Objective-C model (GRDB.framework / TTGRDBPod.framework
// are now bundled) and its isPro/proEndDate accessors are no longer visible
// to the Objective-C runtime, so the method-swizzle above can silently
// become a no-op. Every server response still lands here first though, since
// the app parses JSON via NSJSONSerialization (Alamofire/SwiftyJSON/
// TTJSONMappingPod all reference it) before mapping it into whatever model
// currently backs it. Patching the parsed JSON in place keeps this working
// even if the internal model class is renamed or restructured again.
static const double kPatchZeroForcedProEndDateSeconds = 4070908800.0; // ~2098

static id patchzero_patch_json_object(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dict.count];
        for (id key in dict) {
            result[key] = patchzero_patch_json_object(dict[key]);
        }

        for (NSString *proKey in @[@"isPro", @"isTeamPro", @"isActiveTeamUser"]) {
            if (result[proKey] != nil && ![result[proKey] isEqual:@YES]) {
                NSLog(@"[PatchZero] Patched JSON field %@: %@ -> true", proKey, result[proKey]);
                result[proKey] = @YES;
            }
        }

        for (NSString *dateKey in @[@"proEndDate", @"vipEndDate"]) {
            id original = result[dateKey];
            if ([original isKindOfClass:[NSString class]]) {
                NSLog(@"[PatchZero] Patched JSON field %@: %@ -> 2098-12-13", dateKey, original);
                result[dateKey] = @"2098-12-13T00:00:00.000+0000";
            } else if ([original isKindOfClass:[NSNumber class]]) {
                double magnitude = [original doubleValue];
                BOOL looksLikeMilliseconds = fabs(magnitude) > 1e11;
                NSLog(@"[PatchZero] Patched JSON field %@: %@ -> 2098-12-13", dateKey, original);
                result[dateKey] = looksLikeMilliseconds
                    ? @(kPatchZeroForcedProEndDateSeconds * 1000.0)
                    : @(kPatchZeroForcedProEndDateSeconds);
            }
        }

        return result;
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)obj;
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:array.count];
        for (id item in array) {
            [result addObject:patchzero_patch_json_object(item)];
        }
        return result;
    }

    return obj;
}

@implementation NSJSONSerialization (PatchZeroJSON)

+ (id)patched_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable __autoreleasing *)error {
    id result = [self patched_JSONObjectWithData:data options:opt error:error];
    return patchzero_patch_json_object(result);
}

@end

static void patchzero_install_json_patch(void) {
    Class cls = [NSJSONSerialization class];
    Method orig = class_getClassMethod(cls, @selector(JSONObjectWithData:options:error:));
    Method repl = class_getClassMethod(cls, @selector(patched_JSONObjectWithData:options:error:));
    if (orig && repl) {
        method_exchangeImplementations(orig, repl);
        NSLog(@"[PatchZero] Hooked NSJSONSerialization JSONObjectWithData:options:error:");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook NSJSONSerialization.");
    }
}

// The JSON patch above only affects data as it comes off the wire. Once it's
// merged into the local Core Data store (ZTTUSER.ZISPRO / ZPROENDDATE), any
// later read of that row - whether from a resync, a cache refresh, or code
// we haven't found - sees whatever the server last wrote. Patch reads at the
// SQLite layer instead, since GRDB/Core Data both ultimately go through
// libsqlite3's C API to load rows. This makes isPro effectively immutable
// from the app's point of view: whatever gets written, every read comes back
// patched.
// DIAGNOSTIC: disabled so we can bisect the "tasks not rendering on folder
// switch" bug. The sqlite interpose rewrites column TYPES/VALUES on every
// local-DB read (folder lists are read from the local store, not the wire,
// so the JSON patch above never sees them). If Core Data gets a wrong column
// type for a date/null column, row drawing stalls exactly like the reported
// symptom. Force this matcher to always miss -> the whole sqlite layer is a
// no-op -> premium dates come from the JSON patch only for this test.
static BOOL patchzero_sqlite_patch_disabled = YES;

static BOOL patchzero_column_name_is_one_of(sqlite3_stmt *stmt, int col, NSArray<NSString *> *names) {
    if (patchzero_sqlite_patch_disabled) {
        return NO;
    }
    const char *rawName = sqlite3_column_name(stmt, col);
    if (!rawName) {
        return NO;
    }
    NSString *name = [NSString stringWithUTF8String:rawName];
    for (NSString *candidate in names) {
        if ([name caseInsensitiveCompare:candidate] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *patchzero_pro_bool_columns(void) {
    return @[@"ZISPRO", @"ZISTEAMPRO", @"ZISACTIVETEAMUSER", @"isPro", @"isTeamPro", @"isActiveTeamUser"];
}

static NSArray<NSString *> *patchzero_pro_date_columns(void) {
    return @[@"ZPROENDDATE", @"ZVIPENDDATE", @"proEndDate", @"vipEndDate"];
}

// Core Data's Cocoa-reference-date epoch (2001-01-01), matching how
// TTUser.proEndDate is stored as a REAL column in the sqlite store.
static const double kPatchZeroForcedProEndDateReferenceSeconds = 3092601600.0; // ~2098-12-13

// Calling the real symbol by name here is intentional and safe: dyld's
// __interpose mechanism only rewrites bindings in OTHER images that import
// these symbols, not references from within this same dylib. Routing through
// a dlsym-resolved pointer instead (an earlier version of this patch did)
// resolved back to our own replacement on this dyld and crashed with
// infinite recursion / stack overflow.
int patchzero_sqlite3_column_int(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_bool_columns())) {
        return 1;
    }
    return sqlite3_column_int(stmt, col);
}

sqlite3_int64 patchzero_sqlite3_column_int64(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_bool_columns())) {
        return 1;
    }
    return sqlite3_column_int64(stmt, col);
}

double patchzero_sqlite3_column_double(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_date_columns())) {
        return kPatchZeroForcedProEndDateReferenceSeconds;
    }
    return sqlite3_column_double(stmt, col);
}

// Core Data checks the column type before trusting a REAL value; a row with
// no proEndDate is otherwise reported as SQLITE_NULL and the forced double
// above never gets read.
int patchzero_sqlite3_column_type(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_date_columns())) {
        return SQLITE_FLOAT;
    }
    return sqlite3_column_type(stmt, col);
}

typedef struct patchzero_interpose_s {
    const void *replacement;
    const void *original;
} patchzero_interpose_t;

__attribute__((used)) static const patchzero_interpose_t patchzero_interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)patchzero_sqlite3_column_int, (const void *)sqlite3_column_int },
    { (const void *)patchzero_sqlite3_column_int64, (const void *)sqlite3_column_int64 },
    { (const void *)patchzero_sqlite3_column_double, (const void *)sqlite3_column_double },
    { (const void *)patchzero_sqlite3_column_type, (const void *)sqlite3_column_type },
};

// Redirect the App Group container to a writable location.
//
// macOS denies an ad-hoc-signed app filesystem access to its team-prefixed
// Group Container (~/Library/Group Containers/<team>.<id>) even when the
// application-groups entitlement is present, because access is gated on the
// real team-signed identity. The app then fails its SQLite WAL checkpoint
// during the "Upgrading..." migration and shows "Abnormal data detected".
//
// We point the app at a normal, writable directory in the user's home that a
// non-sandboxed process can freely access. TickTick is cloud-synced, so the
// app starts from a clean local store and re-downloads everything from the
// server after login.
static NSString *patchzero_redirected_group_path(NSString *groupIdentifier) {
    NSString *base = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/TickTickPatched/GroupContainers"];
    return [base stringByAppendingPathComponent:groupIdentifier];
}

@implementation NSFileManager (PatchZeroContainerRedirect)

- (NSURL *)patched_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSString *path = patchzero_redirected_group_path(groupIdentifier);
    [self createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

@end

static void patchzero_install_container_redirect(void) {
    Class fm = [NSFileManager class];
    Method orig = class_getInstanceMethod(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method repl = class_getInstanceMethod(fm, @selector(patched_containerURLForSecurityApplicationGroupIdentifier:));
    if (orig && repl) {
        method_exchangeImplementations(orig, repl);
        NSLog(@"[PatchZero] Redirected App Group container to a writable path.");
    } else {
        NSLog(@"[PatchZero] WARNING: could not install container redirect.");
    }
}

// As of TickTick 8.0.80, the pro-status entity was renamed from
// TTUserModel to TTUser (verified against the compiled Core Data model,
// TickTick.momd, which still carries isPro/proEndDate/isTeamPro properties
// on the TTUser entity). Keep both names so this keeps working if the app
// reverts or renames again.
static NSString *const kPatchZeroCandidateClassNames[] = {
    @"TTUser",
    @"TTUserModel",
};

static BOOL patchzero_try_hook_user_class(void) {
    Class class = nil;
    NSString *foundName = nil;
    for (size_t i = 0; i < sizeof(kPatchZeroCandidateClassNames) / sizeof(kPatchZeroCandidateClassNames[0]); i++) {
        Class candidate = NSClassFromString(kPatchZeroCandidateClassNames[i]);
        if (candidate) {
            class = candidate;
            foundName = kPatchZeroCandidateClassNames[i];
            break;
        }
    }
    if (!class) {
        return NO;
    }

    SEL originalSelectors[] = {
        @selector(setIsPro:),
        @selector(isPro),
        @selector(setProEndDate:),
        @selector(proEndDate)
    };

    SEL patchedSelectors[] = {
        @selector(patched_setIsPro:),
        @selector(patched_isPro),
        @selector(patched_setProEndDate:),
        @selector(patched_proEndDate)
    };

    BOOL hookedAny = NO;
    for (int i = 0; i < 4; i++) {
        Method originalMethod = class_getInstanceMethod(class, originalSelectors[i]);
        Method patchedMethod = class_getInstanceMethod([NSObject class], patchedSelectors[i]);

        if (originalMethod && patchedMethod) {
            method_exchangeImplementations(originalMethod, patchedMethod);
            NSLog(@"[PatchZero] Hooked %@ %@", foundName, NSStringFromSelector(originalSelectors[i]));
            hookedAny = YES;
        } else {
            NSLog(@"[PatchZero] WARNING: %@ has no method %@", foundName, NSStringFromSelector(originalSelectors[i]));
        }
    }

    return hookedAny;
}

// Core Data can register the managed-object class for an entity lazily,
// the first time its model is loaded, which can happen after this dylib's
// constructor already ran. Poll briefly instead of giving up on the first miss.
static void patchzero_hook_user_class_with_retry(void) {
    if (patchzero_try_hook_user_class()) {
        NSLog(@"[PatchZero] Hooking complete.");
        return;
    }

    NSLog(@"[PatchZero] User model class not found yet, will retry...");

    __block int attemptsRemaining = 50; // ~10s at 200ms
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                     repeats:YES
                                       block:^(NSTimer *timer) {
        attemptsRemaining--;
        if (patchzero_try_hook_user_class()) {
            NSLog(@"[PatchZero] Hooking complete (after retry).");
            [timer invalidate];
        } else if (attemptsRemaining <= 0) {
            NSLog(@"[PatchZero] WARNING: gave up looking for the user model class.");
            [timer invalidate];
        }
    }];
}

__attribute__((constructor))
static void patch_init() {
    NSLog(@"[PatchZero] Hooking user model...");
    patchzero_install_container_redirect();
    patchzero_install_json_patch();
    patchzero_install_menu_protection();
    // Confirmed by hand: clicking "Cancel" quits the app. Answering with the
    // other button ("Download TickTick") instead - see
    // PatchZeroSuppressPiracyWarning above for the reasoning.
    patchzero_install_piracy_warning_suppression();
    NSLog(@"[PatchZero] Hooked libsqlite3 column readers for ZISPRO/ZPROENDDATE.");
    patchzero_hook_user_class_with_retry();
    // NSEvent local monitors need a running NSApplication; this constructor
    // runs before NSApplicationMain, so defer briefly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_install_quit_safety_valve();
        // Minimize guard for first launch: armed for 8s (the user cannot
        // physically minimize anything meaningful in that window; the first
        // tamper ticks land here).
        patchzero_install_minimize_blocker();
        patchzero_install_minimize_guard();
        patchzero_arm_minimize_guard(8.0);
        // Seed window snapshot, then keep it fresh every 0.5s so the reopen
        // pass can tell "tamper-check-hid" windows from "user closed them".
        patchzero_snapshot_visible_windows();
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         repeats:YES
                                           block:^(NSTimer *timer) {
            patchzero_snapshot_visible_windows();
        }];
        NSLog(@"[PatchZero] Installed Cmd+Q safety valve + window snapshot timer.");
    });
}
