#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <strings.h>

// TickTick 8.0.80 added a runtime tamper/piracy check, independent of the
// isPro state itself, that pops an "Application Not Licensed" NSAlert
// ("We detected that you are using a pirated TickTick application...").
// We couldn't find or reverse the exact check that decides to show it (the
// binary is fully stripped, no local symbols left to search), so instead of
// chasing that we suppress it at its single, guaranteed choke point: every
// alert - regardless of what triggers it - has to go through NSAlert's
// presentation methods to ever become visible.
//
// 8.2.10+ localized the alert through Localizable.strings into 40+ languages,
// so the title is no longer the fixed English "Application Not Licensed".
// Match the full set of localized titles (extracted from the 8.2.10/8.2.20
// bundle) plus a couple of generic fallbacks so a future locale still gets
// caught. The titles are compile-time NSString literals: static constants
// that outlive the process and need no retain under -fno-objc-arc.
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

// Answering either button on the alert (verified by hand for Cancel, and by
// log for "Download TickTick" - no crash report either time, just a clean
// exit) is followed by the app quitting on its own shortly after. That means
// this isn't the alert's response causing it - something unconditionally
// terminates the process once the tamper check has run, regardless of what
// the user chooses. Block termination for a short window after we see the
// alert so that call fails silently instead, then let it work normally again
// so a real user quit (Cmd+Q, Dock menu) still works.
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
// tight ~200-300ms loop instead of its normal ~20s cadence, pegging the main
// thread. So instead: let close/orderOut proceed normally and re-show the
// window a moment afterward.
static void patchzero_reopen_windows_shortly(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSWindow *window in [NSApplication sharedApplication].windows) {
            [window makeKeyAndOrderFront:nil];
        }
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    });
}

@implementation NSAlert (PatchZeroSuppressPiracyWarning)

- (NSModalResponse)patched_runModal {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (runModal), answering Download TickTick.");
        patchzero_start_termination_block_window();
        patchzero_reopen_windows_shortly();
        return NSAlertFirstButtonReturn;
    }
    return [self patched_runModal];
}

- (void)patched_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (sheet), answering Download TickTick.");
        patchzero_start_termination_block_window();
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

// Cmd+Q fallback: if the app's own quit path is broken (menu beeping, etc.),
// force-exit a second after the keypress rather than hang.
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

// "Download TickTick" opens the App Store page as a side effect. Swallow just
// that one URL so launching doesn't also pop open a browser tab every time.
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
    [self patched_setIsPro:YES];
}

- (BOOL)patched_isPro {
    return YES;
}

- (void)patched_setProEndDate:(NSDate *)date {
    NSDate *forcedDate = [NSDate dateWithTimeIntervalSince1970:4070908800]; // 2098
    [self patched_setProEndDate:forcedDate];
}

- (NSDate *)patched_proEndDate {
    return [NSDate dateWithTimeIntervalSince1970:4070908800];
}

@end

static const double kPatchZeroForcedProEndDateSeconds = 4070908800.0; // ~2098

static id patchzero_patch_json_object(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dict.count];
        for (id key in dict) {
            result[key] = patchzero_patch_json_object(dict[key]);
        }

        // 8.2.20 hydrates the user as a Swift struct TTUserEntity whose premium
        // flag is computed from isPro + premiumPaymentType + premiumSubscriptionDuration,
        // NOT from proEndDate alone. A user object is the only payload carrying
        // these "premium*" / "proEndDate" keys, so detecting them is a cheap and
        // unambiguous signature — task lists never contain premiumPaymentType.
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

            // premiumPaymentType: empty/absent means "not subscribed" on 8.2.20.
            id payType = result[@"premiumPaymentType"];
            if (payType == nil || [payType isEqual:[NSNull null]] || ([payType isKindOfClass:[NSString class]] && [(NSString *)payType length] == 0)) {
                NSLog(@"[PatchZero] Patched JSON field premiumPaymentType: %@ -> Yearly", payType ?: @"<absent>");
                result[@"premiumPaymentType"] = @"Yearly";
            }

            // premiumSubscriptionDuration: 0 means "not subscribed" on 8.2.20.
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

// Surgical SQLite read interpose for the user's premium flags.
//
// 8.2.20 hydrates the user as a Swift struct TTUserEntity and persists it to
// the GRDB store table ZTTUSER. The premium gate reads isPro from that LOCAL
// row, not from the profile JSON — the server's 8.2.20 profile response no
// longer carries an isPro key at all (only proEndDate=1970 for free accounts),
// so no amount of wire patching flips it. We force the boolean premium columns
// (and the proEndDate timestamp) on every read of the user row, which keeps
// isPro true regardless of what the server writes.
//
// The earlier, broader interpose broke task rendering for a different reason:
// its matcher allocated an NSString and ran -caseInsensitiveCompare: for every
// column of every query. On a task-list reload (thousands of rows x dozens of
// columns) that is millions of allocations on the main thread, which stalled
// the list from drawing. This matcher is pure C strcasecmp with zero
// allocation, and it scopes itself to the user table only, so task tables are
// never touched even by the cheap name check.

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
// Core Data reference-date epoch (2001-01-01) -> ~2098-12-13.
static const double kPatchZeroForcedProEndReferenceSeconds = 3092601600.0;

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

// Redirect the App Group container to a writable location, since ad-hoc
// signing denies access to the team-prefixed Group Container and the app
// otherwise fails its SQLite WAL checkpoint during migration.
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
    patchzero_install_piracy_warning_suppression();
    NSLog(@"[PatchZero] Installed surgical sqlite premium read interpose (isPro/isTeamPro/isActiveTeamUser + proEndDate).");
    patchzero_hook_user_class_with_retry();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_install_quit_safety_valve();
        NSLog(@"[PatchZero] Installed Cmd+Q safety valve.");
    });
}