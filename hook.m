#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <strings.h>

// PatchZero — final configuration (proven combo):
//   1. container redirect (writable Group Container for ad-hoc signing)
//   2. JSON wire patch (isPro/premium fields on the profile response)
//   3. surgical sqlite read interpose (premium from the LOCAL GRDB store)
//   4. piracy alert suppression (41 localized titles, answered with Stop)
//   5. full tamper-check guard layer transplanted from the proven 7371eae
//      build: window snapshot, menu protection + item re-enable, activation
//      policy pin, NSApp unhide, minimize guard, orderOut same-turn restore,
//      termination block, Cmd+Q safety valve.

// ── Piracy alert detection ───────────────────────────────────────────────────

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
    nil,
};

static BOOL patchzero_alert_is_piracy_warning(NSAlert *alert) {
    NSString *title = alert.messageText ?: @"";
    for (NSUInteger i = 0; kPatchZeroPiracyTitles[i] != nil; i++) {
        if ([title isEqualToString:kPatchZeroPiracyTitles[i]]) {
            return YES;
        }
    }
    NSString *info = alert.informativeText ?: @"";
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
    return mentionsTickTickInInfo && piracyKeyword;
}

// ── Termination block (armed briefly after each suppression) ────────────────

static volatile BOOL patchzero_block_termination = NO;

static void patchzero_arm_termination_block(void) {
    patchzero_block_termination = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_block_termination = NO;
    });
}

@implementation NSApplication (PatchZeroBlockForcedQuit)

- (void)patched_terminate:(id)sender {
    if (patchzero_block_termination) {
        NSLog(@"[PatchZero] Blocked an app termination request during the post-alert window.");
        return;
    }
    [self patched_terminate:sender];
}

@end

// ── Main menu protection ─────────────────────────────────────────────────────

static NSMenu *gPatchZeroProtectedMenu = nil;

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

// Re-enable every menu item that has an action (recursively through submenus).
// The tamper check disables items via setEnabled:NO; called on each
// suppression so the menu bar comes back alive.
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

// ── Activation policy pin ────────────────────────────────────────────────────

@implementation NSApplication (PatchZeroProtectActivationPolicy)

- (void)patched_setActivationPolicy:(NSApplicationActivationPolicy)policy {
    if (policy != NSApplicationActivationPolicyRegular) {
        NSLog(@"[PatchZero] Blocked setActivationPolicy:%ld (tamper check), keeping Regular.", (long)policy);
        policy = NSApplicationActivationPolicyRegular;
    }
    [self patched_setActivationPolicy:policy];
}

@end

// ── Window snapshot + reopen pass (transplanted from proven 7371eae) ────────

// Window number of the last suppressed piracy alert, kept so the reopen pass
// does not raise an empty NSAlert window over the app's real UI.
static NSInteger gPatchZeroSuppressedWindowNumber = 0;

// Rolling snapshot of window numbers that are actually visible and not
// miniaturized, refreshed every 0.5s. The reopen pass uses this to
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
            // Skip the suppressed piracy alert's own (empty) window.
            if ([window windowNumber] == gPatchZeroSuppressedWindowNumber) {
                continue;
            }
            if (!snapshotEmpty && !patchzero_is_window_number_tracked(window.windowNumber)) {
                continue;
            }
            if (snapshotEmpty && !window.isVisible && !window.isMiniaturized) {
                continue;
            }
            if (window.isMiniaturized) {
                [window deminiaturize:nil];
            }
            // Show without touching the key window: makeKeyAndOrderFront here
            // stole focus from a window the user just opened.
            [window orderFront:nil];
        }
        // Reactivate only if the app was already active: unconditional
        // activateIgnoringOtherApps:YES stole focus on every tamper tick.
        if ([[NSApplication sharedApplication] isActive]) {
            [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
        }
    });
}

// ── Minimize guard (armed after each suppression + at startup) ──────────────

static volatile BOOL gPatchZeroMinimizeGuardArmed = NO;

static void patchzero_arm_minimize_guard(double seconds) {
    gPatchZeroMinimizeGuardArmed = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gPatchZeroMinimizeGuardArmed = NO;
    });
}

@implementation NSWindow (PatchZeroBlockMinimize)

- (void)patched_miniaturize:(id)sender {
    if (gPatchZeroMinimizeGuardArmed) {
        NSLog(@"[PatchZero] Minimize guard: blocked miniaturize: on window %ld.", (long)[self windowNumber]);
        return;
    }
    [self patched_miniaturize:sender];
}

@end

// ── orderOut same-turn restore (main window only) ───────────────────────────

@implementation NSWindow (PatchZeroRestoreAfterTamperHide)

- (void)patched_orderOut:(id)sender {
    BOOL isTamperHide = gPatchZeroMinimizeGuardArmed
        && [self windowNumber] >= 0
        && [self windowNumber] != gPatchZeroSuppressedWindowNumber
        && (patchzero_is_window_number_tracked([self windowNumber]) || self.isVisible);
    [self patched_orderOut:sender];
    if (isTamperHide) {
        NSLog(@"[PatchZero] Tamper check ordered out window %ld; restoring same turn.", (long)[self windowNumber]);
        [self orderFront:nil];
        if ([[NSApplication sharedApplication] isActive]) {
            [self makeKeyWindow];
        }
    }
}

@end

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
            return;
        }
        NSLog(@"[PatchZero] Minimize guard: restoring window %ld minimized by tamper check.", (long)[window windowNumber]);
        [window deminiaturize:nil];
        [window orderFront:nil];
    }];
    NSLog(@"[PatchZero] Installed window minimize guard.");
}

// ── Alert suppression ───────────────────────────────────────────────────────

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

@implementation NSAlert (PatchZeroSuppressPiracyWarning)

- (NSModalResponse)patched_runModal {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (runModal), answering Stop (no button action).");
        patchzero_hide_suppressed_alert_window(self);
        patchzero_arm_termination_block();
        patchzero_arm_minimize_guard(3.0);
        patchzero_reopen_windows_shortly();
        return NSModalResponseStop;
    }
    return [self patched_runModal];
}

- (void)patched_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (sheet), answering Stop (no button action).");
        patchzero_hide_suppressed_alert_window(self);
        patchzero_arm_termination_block();
        patchzero_arm_minimize_guard(3.0);
        patchzero_reopen_windows_shortly();
        if (handler) {
            handler(NSModalResponseStop);
        }
        return;
    }
    [self patched_beginSheetModalForWindow:sheetWindow completionHandler:handler];
}

@end

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

static void patchzero_install_menu_protection(void) {
    Class cls = [NSApplication class];
    Method origMainMenu = class_getInstanceMethod(cls, @selector(setMainMenu:));
    Method replMainMenu = class_getInstanceMethod(cls, @selector(patched_setMainMenu:));
    Method origPolicy = class_getInstanceMethod(cls, @selector(setActivationPolicy:));
    Method replPolicy = class_getInstanceMethod(cls, @selector(patched_setActivationPolicy:));
    if (origMainMenu && replMainMenu) {
        method_exchangeImplementations(origMainMenu, replMainMenu);
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

static void patchzero_install_window_guards(void) {
    Class cls = [NSWindow class];
    Method origMini = class_getInstanceMethod(cls, @selector(miniaturize:));
    Method replMini = class_getInstanceMethod(cls, @selector(patched_miniaturize:));
    if (origMini && replMini) {
        method_exchangeImplementations(origMini, replMini);
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
    patchzero_install_minimize_guard();
}

// ── Cmd+Q safety valve ───────────────────────────────────────────────────────

// Match by KEYCODE (12 = kVK_ANSI_Q), not by charactersIgnoringModifiers:
// on a Cyrillic layout the Q key yields "й", so a literal @"q" comparison
// misses Cmd+Q every time. keyCode 12 is layout-independent.
static void patchzero_install_quit_safety_valve(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        BOOL isCommandQ = (event.modifierFlags & NSEventModifierFlagCommand)
            && (event.keyCode == 12);
        if (isCommandQ) {
            NSLog(@"[PatchZero] Cmd+Q seen (keyCode 12); will force-quit in 1s if the app hasn't quit by itself.");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSLog(@"[PatchZero] App still alive 1s after Cmd+Q; forcing exit.");
                exit(0);
            });
        }
        return event;
    }];
}

// ── JSON patch ──────────────────────────────────────────────────────────────

static const double kPatchZeroForcedProEndDateSeconds = 4070908800.0; // ~2098

static id patchzero_patch_json_object(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dict.count];
        for (id key in dict) {
            result[key] = patchzero_patch_json_object(dict[key]);
        }

        BOOL looksLikeUser =
               result[@"proEndDate"] != nil
            || result[@"premiumPaymentType"] != nil
            || result[@"premiumSubscriptionDuration"] != nil
            || result[@"needsRenew"] != nil;

        if (looksLikeUser) {
            for (NSString *proKey in @[@"isPro", @"isTeamPro", @"isActiveTeamUser", @"isPremium"]) {
                if (result[proKey] == nil || ![result[proKey] isEqual:@YES]) {
                    NSLog(@"[PatchZero] Patched JSON field %@: %@ -> true", proKey, result[proKey] ?: @"<absent>");
                    result[proKey] = @YES;
                }
            }

            id payType = result[@"premiumPaymentType"];
            if (payType == nil || [payType isEqual:[NSNull null]] || ([payType isKindOfClass:[NSString class]] && [(NSString *)payType length] == 0)) {
                NSLog(@"[PatchZero] Patched JSON field premiumPaymentType: %@ -> Yearly", payType ?: @"<absent>");
                result[@"premiumPaymentType"] = @"Yearly";
            }

            id subDur = result[@"premiumSubscriptionDuration"];
            if (subDur == nil || [subDur isEqual:[NSNull null]] || [subDur integerValue] <= 0) {
                NSLog(@"[PatchZero] Patched JSON field premiumSubscriptionDuration: %@ -> 999999999", subDur ?: @"<absent>");
                result[@"premiumSubscriptionDuration"] = @999999999;
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

// ── Surgical sqlite read interpose ──────────────────────────────────────────

static inline int patchzero_col_is(const sqlite3_stmt *stmt, int col, const char *const *names, int count) {
    const char *name = sqlite3_column_name((sqlite3_stmt *)stmt, col);
    if (!name) return 0;
    for (int i = 0; i < count; i++) {
        if (strcasecmp(name, names[i]) == 0) return 1;
    }
    return 0;
}

static const char *const kPatchZeroProBoolColumns[] = {
    "ZISPRO", "isPro", "ZISTEAMPRO", "isTeamPro", "ZISACTIVETEAMUSER", "isActiveTeamUser",
};
static const char *const kPatchZeroProDateColumns[] = {
    "ZPROENDDATE", "proEndDate", "ZVIPENDDATE", "vipEndDate",
};
static const double kPatchZeroForcedProEndReferenceSeconds = 3092601600.0; // ~2098 (Core Data ref epoch)

int patchzero_sqlite3_column_int(sqlite3_stmt *stmt, int col) {
    if (patchzero_col_is(stmt, col, kPatchZeroProBoolColumns, 6)) {
        return 1;
    }
    return sqlite3_column_int(stmt, col);
}

sqlite3_int64 patchzero_sqlite3_column_int64(sqlite3_stmt *stmt, int col) {
    if (patchzero_col_is(stmt, col, kPatchZeroProBoolColumns, 6)) {
        return 1;
    }
    return sqlite3_column_int64(stmt, col);
}

double patchzero_sqlite3_column_double(sqlite3_stmt *stmt, int col) {
    if (patchzero_col_is(stmt, col, kPatchZeroProDateColumns, 4)) {
        return kPatchZeroForcedProEndReferenceSeconds;
    }
    return sqlite3_column_double(stmt, col);
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
};

// ── Container redirect ──────────────────────────────────────────────────────

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

// ── Init ─────────────────────────────────────────────────────────────────────

__attribute__((constructor))
static void patch_init() {
    NSLog(@"[PatchZero] Hooking...");
    patchzero_install_container_redirect();
    patchzero_install_json_patch();
    patchzero_install_piracy_warning_suppression();
    NSLog(@"[PatchZero] Installed surgical sqlite premium read interpose (isPro/isTeamPro/isActiveTeamUser + proEndDate).");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_install_quit_safety_valve();
        patchzero_install_menu_protection();
        patchzero_install_window_guards();
        // Snapshot timer: keep the tracked-window list fresh so the reopen
        // pass knows which windows were legitimately on screen.
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            patchzero_snapshot_visible_windows();
        }];
        // Arm the minimize guard for the first seconds after launch: the
        // tamper check fires its first tick right around login/sync.
        patchzero_arm_minimize_guard(8.0);
        NSLog(@"[PatchZero] Installed Cmd+Q safety valve, menu protection, window guards.");
    });
}