#define agentic_signal_group admission_real_signal_group
#include "../../runtime/cbits/process_group.c"
#undef agentic_signal_group
#include <stdatomic.h>

static _Atomic int armed;
static _Atomic int fired;
void admission_arm_completion_failure(void) {
    atomic_store(&fired, 0);
    atomic_store(&armed, 1);
}
int admission_completion_failure_fired(void) { return atomic_load(&fired); }

int agentic_signal_group(int pid, int signal) {
    if (signal == SIGKILL && atomic_load(&armed)) {
        int exited;
        do {
            exited = agentic_child_exited(pid);
        } while (exited < 0 && errno == EINTR);
        int result = admission_real_signal_group(pid, signal);
        if (result == 0 && exited > 0 && atomic_exchange(&armed, 0)) {
            /* Real cleanup ran. Only its completion report is simulated as failed. */
            atomic_store(&fired, 1);
            errno = EIO;
            return -1;
        }
        return result;
    }
    return admission_real_signal_group(pid, signal);
}
