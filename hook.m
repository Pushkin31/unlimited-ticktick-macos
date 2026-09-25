#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <strings.h>

// ── Minimal PatchZero dylib: container redirect + JSON patch + surgical sqlite
// isPro read interpose + piracy alert suppression + App Store URL swallow +
// activation policy pin + main menu protection + same-turn window restore.
// No window close/miniaturize hooks, no neuter, no diagnostics — those were
// breaking rendering and the menu bar. This is the proven-stable baseline.

// ── Piracy alert suppression ─────────────────────────────────────────────────

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

// Answer NSModalResponseStop (-1000): no button matches, so the handler runs
// none of its branches — no App Store open, no window hide, no terminate.
@implementation NSAlert (PatchZeroSuppressPiracyWarning)

- (NSModalResponse)patched_runModal {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (runModal), answering Stop.");
        return NSModalResponseStop;
    }
    return [self patched_runModal];
}

- (void)patched_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (sheet), answering Stop.");
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

// ── Main menu protection ─────────────────────────────────────────────────────

static NSMenu *gPatchZeroProtectedMenu = nil;

@implementation NSApplication (PatchZeroProtectMainMenu)

- (void)patched_setMainMenu:(NSMenu *)menu {
    if (menu == nil || menu.numberOfItems == 0) {
        if (gPatchZeroProtectedMenu != nil && [self mainMenu] != gPatchZeroProtectedMenu) {
            NSLog(@"[PatchZero] Blocked clearing of main menu, restoring.");
            [self patched_setMainMenu:gPatchZeroProtectedMenu];
        }
        return;
    }
    if (gPatchZeroProtectedMenu == nil) {
        gPatchZeroProtectedMenu = [menu retain];
    }
    [self patched_setMainMenu:menu];
}

@end

static void patchzero_enable_menu_items(NSMenu *menu) {
    if (menu == nil) return;
    for (NSMenuItem *item in [menu itemArray]) {
        if (item.hasSubmenu) {
            patchzero_enable_menu_items(item.submenu);
        }
        if (item.action != NULL) {
            item.enabled = YES;
        }
    }
}

// ── Activation policy pin ───────────────────────────────────────────────────

@implementation NSApplication (PatchZeroProtectActivationPolicy)

- (void)patched_setActivationPolicy:(NSApplicationActivationPolicy)policy {
    if (policy != NSApplicationActivationPolicyRegular) {
        NSLog(@"[PatchZero] Blocked setActivationPolicy:%ld, keeping Regular.", (long)policy);
        policy = NSApplicationActivationPolicyRegular;
    }
    [self patched_setActivationPolicy:policy];
}

@end

// ── Window restore (main window only, same turn) ─────────────────────────────

static volatile BOOL gPatchZeroTamperWindowActive = NO;

static void patchzero_arm_tamper_window(void) {
    gPatchZeroTamperWindowActive = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gPatchZeroTamperWindowActive = NO;
    });
}

@implementation NSWindow (PatchZeroRestoreAfterTamperHide)

- (void)patched_orderOut:(id)sender {
    BOOL isTamperHide = gPatchZeroTamperWindowActive
        && self == [[NSApplication sharedApplication] mainWindow];
    [self patched_orderOut:sender];
    if (isTamperHide) {
        NSLog(@"[PatchZero] Tamper check ordered out main window; restoring same turn.");
        [self orderFront:nil];
        if ([[NSApplication sharedApplication] isActive]) {
            [self makeKeyWindow];
        }
    }
}

@end

// ── Init ─────────────────────────────────────────────────────────────────────

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
    }
    if (origPolicy && replPolicy) {
        method_exchangeImplementations(origPolicy, replPolicy);
        NSLog(@"[PatchZero] Hooked setActivationPolicy: (pinned to Regular).");
    }
}

static void patchzero_install_window_restore(void) {
    Class cls = [NSWindow class];
    Method orig = class_getInstanceMethod(cls, @selector(orderOut:));
    Method repl = class_getInstanceMethod(cls, @selector(patched_orderOut:));
    if (orig && repl) {
        method_exchangeImplementations(orig, repl);
        NSLog(@"[PatchZero] Hooked NSWindow orderOut: (main-window restore).");
    }
}

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

// ── JSON patch ─────────────────────────────────────────────────────────────

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

// ── Init ─────────────────────────────────────────────────────────────────────

__attribute__((constructor))
static void patch_init() {
    NSLog(@"[PatchZero] Hooking...");
    patchzero_install_container_redirect();
    patchzero_install_json_patch();
    patchzero_install_piracy_warning_suppression();
    NSLog(@"[PatchZero] Installed surgical sqlite premium read interpose (isPro/isTeamPro/isActiveTeamUser + proEndDate).");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_install_menu_protection();
        patchzero_install_window_restore();
        NSLog(@"[PatchZero] Installed menu protection and window restore.");
    });
}