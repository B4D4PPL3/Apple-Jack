// Ensure the read-only helper exits even if Jack crashes or is force-quit.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <unistd.h>
static dispatch_source_t parentMonitor;
__attribute__((constructor)) static void watchJack(void) {
    const char *expected = getenv("APPLEJACK_HOST_PID");
    if (!expected) return; // Standalone diagnostics do not need a parent guard.
    pid_t parent = (pid_t)strtol(expected, NULL, 10);
    if (parent <= 1 || getppid() != parent) _exit(0);
    parentMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent,
        DISPATCH_PROC_EXIT, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!parentMonitor) _exit(0);
    dispatch_source_set_event_handler(parentMonitor, ^{ _exit(0); });
    dispatch_resume(parentMonitor);
    if (getppid() != parent) _exit(0);
}
