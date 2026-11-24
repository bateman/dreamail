#import "SafeTextLayout.h"
#import <os/log.h>

BOOL MMEnsureTextLayout(NSLayoutManager *layoutManager,
                        NSTextContainer *textContainer) {
    @try {
        [layoutManager ensureLayoutForTextContainer:textContainer];
        return YES;
    } @catch (NSException *exception) {
        // The name is a fixed Foundation constant; the reason can quote the
        // laid-out text (a range error names the string), which here is the
        // compose body, so it stays private in the unified log.
        os_log_error(OS_LOG_DEFAULT,
                     "MishMail: text layout raised %{public}@: %{private}@",
                     exception.name, exception.reason);
        return NO;
    }
}
