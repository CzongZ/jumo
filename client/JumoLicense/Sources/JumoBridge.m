#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dispatch/dispatch.h>
#import "JumoBridge.h"

extern void JumoStartAuthorization(void);
extern void JumoPresentAuthorization(void);
extern bool JumoIsAuthorized(void);
extern void BaimingStyleView(void *view);

static IMP BaimingOriginalLayout;
static IMP BaimingOriginalRefresh;
static void BaimingRestyle(id self) {
    SEL panel = sel_registerName("panel");
    if ([self respondsToSelector:panel]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(self, panel);
        BaimingStyleView((__bridge void *)view);
    }
    SEL title = sel_registerName("titleLabel");
    if ([self respondsToSelector:title]) {
        UILabel *label = ((id (*)(id, SEL))objc_msgSend)(self, title);
        if ([label isKindOfClass:UILabel.class]) label.text = @"百鸣科技";
    }
}

static void BaimingLayout(id self, SEL cmd) {
    ((void (*)(id, SEL))BaimingOriginalLayout)(self, cmd);
    BaimingRestyle(self);
}

static void BaimingRefresh(id self, SEL cmd) {
    ((void (*)(id, SEL))BaimingOriginalRefresh)(self, cmd);
    BaimingRestyle(self);
}

static id BaimingCrest(id self, SEL cmd) {
    // Keep a visible management entry even after authorization opens the gate.
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 32, 32);
    [button setTitle:@"授权" forState:UIControlStateNormal];
    button.accessibilityLabel = @"百鸣科技授权管理";
    button.accessibilityHint = @"查看、复制配对码和 App 实例编号";
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        JumoPresentAuthorization();
    }] forControlEvents:UIControlEventTouchUpInside];
    BaimingStyleView((__bridge void *)button);
    return button;
}

static void BaimingInstallStyle(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class panel = NSClassFromString(@"VCamFloatingPanel");
    Method layout = class_getInstanceMethod(panel, sel_registerName("layoutForState"));
    Method crest = class_getInstanceMethod(panel, sel_registerName("makePorscheCrestView"));
    Method refresh = class_getInstanceMethod(panel, sel_registerName("refreshStatus"));
    if (!layout || !crest || !refresh) return;
    BaimingOriginalLayout = method_setImplementation(layout, (IMP)BaimingLayout);
    BaimingOriginalRefresh = method_setImplementation(refresh, (IMP)BaimingRefresh);
    method_setImplementation(crest, (IMP)BaimingCrest);
    installed = YES;
}

static id JumoCamAuthorization(void) {
    Class cls = NSClassFromString(@"VCamAuthorization");
    SEL sel = sel_registerName("sharedAuthorization");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

bool JumoCamSetAuthorized(bool authorized) {
    NSCAssert([NSThread isMainThread], @"JUMO authorization state requires main thread");
    id auth = JumoCamAuthorization();
    SEL set = sel_registerName("setAuthorized:");
    SEL getCallback = sel_registerName("startupCompletion");
    SEL setCallback = sel_registerName("setStartupCompletion:");
    if (!auth || ![auth respondsToSelector:set] || ![auth respondsToSelector:getCallback]
        || ![auth respondsToSelector:setCallback]) return false;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(auth, set, authorized ? YES : NO);
    if (authorized) {
        void (^callback)(BOOL) = ((id (*)(id, SEL))objc_msgSend)(auth, getCallback);
        ((void (*)(id, SEL, id))objc_msgSend)(auth, setCallback, nil);
        if (callback) callback(YES);
    }
    return true;
}

static void JumoVerify(id self, SEL cmd) { JumoStartAuthorization(); }
static void JumoPrompt(id self, SEL cmd, id ignored) { JumoPresentAuthorization(); }
static BOOL JumoReadAuthorization(id self, SEL cmd) { return JumoIsAuthorized() ? YES : NO; }

static void JumoInstall(void) {
    BaimingInstallStyle();
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"VCamAuthorization");
    if (!cls) return;
    // Version-locked binary preparation also disables these old network paths.
    Method verify = class_getInstanceMethod(cls, sel_registerName("verifyCachedLicenseAtStartup"));
    Method prompt = class_getInstanceMethod(cls, sel_registerName("presentCardPromptWithMessage:"));
    Method activate = class_getInstanceMethod(cls, sel_registerName("activateCard:"));
    Method getter = class_getInstanceMethod(cls, sel_registerName("isAuthorized"));
    if (!verify || !prompt || !activate || !getter) return;
    method_setImplementation(getter, (IMP)JumoReadAuthorization);
    method_setImplementation(verify, (IMP)JumoVerify);
    method_setImplementation(prompt, (IMP)JumoPrompt);
    method_setImplementation(activate, (IMP)JumoPrompt);
    installed = YES;
    JumoCamSetAuthorized(false);
    JumoStartAuthorization();
}

static void JumoImageAdded(const struct mach_header *header, intptr_t slide) {
    // Defer Objective-C / UIKit work until dyld's image notification returns.
    dispatch_async(dispatch_get_main_queue(), ^{ JumoInstall(); });
}

__attribute__((constructor)) static void JumoInitialize(void) {
    _dyld_register_func_for_add_image(JumoImageAdded);
}
