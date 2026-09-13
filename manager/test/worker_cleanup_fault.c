#define agentic_signal_group worker_real_signal_group
#include "../../runtime/cbits/process_group.c"
#undef agentic_signal_group
#include <stdatomic.h>

static _Atomic int fail_term;
static _Atomic int term_failed;
void worker_arm_term_failure(void) {
    atomic_store(&term_failed, 0);
    atomic_store(&fail_term, 1);
}
int worker_term_failure_fired(void) { return atomic_load(&term_failed); }
int agentic_signal_group(int pid, int signal) {
    if (signal == SIGTERM && atomic_exchange(&fail_term, 0)) {
        atomic_store(&term_failed, 1);
        errno = EIO;
        return -1;
    }
    return worker_real_signal_group(pid, signal);
}
