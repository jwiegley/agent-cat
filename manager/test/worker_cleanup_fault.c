#define agentic_signal_group worker_real_signal_group
#include "../../runtime/cbits/process_group.c"
#undef agentic_signal_group
#include <stdatomic.h>
#include <time.h>

static _Atomic int fail_kill;
static _Atomic int hold_monitor;
static _Atomic int monitor_held;
static _Atomic int release_monitor;
static struct timespec monitor_started;

void worker_arm_final_refusal(int after_exit) {
    atomic_store(&monitor_held, 0);
    atomic_store(&release_monitor, 0);
    atomic_store(&fail_kill, after_exit ? 1 : 2);
}
int worker_monitor_held(void) { return atomic_load(&monitor_held); }
void worker_release_monitor(void) { atomic_store(&release_monitor, 1); }

static _Atomic int fail_term;
static _Atomic int term_failed;
void worker_arm_term_failure(void) {
    atomic_store(&term_failed, 0);
    atomic_store(&fail_term, 1);
}
int worker_term_failure_fired(void) { return atomic_load(&term_failed); }
int agentic_signal_group(int pid, int signal) {
    if (signal == SIGTERM && (atomic_load(&fail_kill) || atomic_exchange(&fail_term, 0))) {
        atomic_store(&term_failed, 1);
        errno = EIO;
        return -1;
    }
    if (signal == SIGKILL) {
        int mode = atomic_exchange(&fail_kill, 0);
        if (mode) {
            if (mode == 1) {
                if (worker_real_signal_group(pid, SIGKILL) < 0)
                    return -1;
                int exited;
                do {
                    exited = agentic_child_exited(pid);
                    if (exited < 0 && errno != EINTR)
                        return -1;
                    if (exited <= 0) {
                        struct timespec pause = {0, 1000000};
                        nanosleep(&pause, NULL);
                    }
                } while (exited <= 0);
                clock_gettime(CLOCK_MONOTONIC, &monitor_started);
                atomic_store(&hold_monitor, 1);
            }
            errno = EPERM;
            return -1;
        }
        if (atomic_load(&hold_monitor)) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (!atomic_load(&release_monitor) && now.tv_sec - monitor_started.tv_sec < 5) {
                struct timespec pause = {0, 1000000};
                atomic_store(&monitor_held, 1);
                /* Return between interruptions so the unsafe FFI does not pin GC. */
                nanosleep(&pause, NULL);
                errno = EINTR;
                return -1;
            }
            if (!atomic_load(&release_monitor))
                atomic_store(&monitor_held, 2);
            atomic_store(&hold_monitor, 0);
        }
    }
    return worker_real_signal_group(pid, signal);
}
