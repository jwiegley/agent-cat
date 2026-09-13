#define agentic_sync_private_descriptor draft_real_sync
#include "../../runtime/cbits/private_sync.c"
#undef agentic_sync_private_descriptor
#include <stdatomic.h>
#include <errno.h>
#include <sys/stat.h>

static _Atomic int remaining;
static _Atomic int fired_directory;
void draft_arm_sync_failure(int nth) {
    atomic_store(&fired_directory, 0);
    atomic_store(&remaining, nth);
}
int draft_sync_failure_fired(void) { return atomic_load(&fired_directory); }
int agentic_sync_private_descriptor(int fd) {
    int before = atomic_load(&remaining);
    while (before > 0 && !atomic_compare_exchange_weak(&remaining, &before, before - 1)) {}
    if (before == 1) {
        struct stat status;
        if (fstat(fd, &status) == -1) return -1;
        atomic_store(&fired_directory, S_ISDIR(status.st_mode) ? 1 : -1);
        errno = EIO;
        return -1;
    }
    return draft_real_sync(fd);
}
