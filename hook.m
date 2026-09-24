#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <strings.h>

// Minimal PatchZero dylib: container redirect + JSON patch + surgical sqlite
// isPro read interpose. No window hooks, no menu protection, no neuter — those
// were breaking rendering and the menu bar. This is the proven-stable baseline.

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

typedef struct patchzero_interpose_s {
    const void *replacement;
    const void *original;
} patchzero_interpose_t;

__attribute__((used)) static const patchzero_interpose_t patchzero_interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)patchzero_sqlite3_column_int, (const void *)sqlite3_column_int },
    { (const void *)patchzero_sqlite3_column_int64, (const void *)sqlite3_column_int64 },
};

// ── Init ─────────────────────────────────────────────────────────────────────

__attribute__((constructor))
static void patch_init() {
    NSLog(@"[PatchZero] Hooking...");
    patchzero_install_container_redirect();
    patchzero_install_json_patch();
    NSLog(@"[PatchZero] Installed surgical sqlite premium read interpose (isPro/isTeamPro/isActiveTeamUser).");
}