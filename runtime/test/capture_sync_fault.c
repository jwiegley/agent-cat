#define agentic_sync_private_descriptor capture_real_sync
#include "../cbits/private_sync.c"
#undef agentic_sync_private_descriptor
#include <errno.h>
#include <sys/stat.h>

static int calls;
static int failure_call;
static int pause_call;
static int ready_fd;
static int release_fd;
static struct stat observed[8];

void capture_configure_sync(int failure, int pause, int ready, int release)
{
    calls = 0;
    failure_call = failure;
    pause_call = pause;
    ready_fd = ready;
    release_fd = release;
}

int agentic_sync_private_descriptor(int descriptor)
{
    if (calls == 8) {
        errno = EOVERFLOW;
        return -1;
    }
    if (fstat(descriptor, &observed[calls]) == -1)
        return -1;
    ++calls;
    if (calls == pause_call) {
        char byte = 'x';
        if (write(ready_fd, &byte, 1) != 1 || read(release_fd, &byte, 1) != 1) {
            errno = EIO;
            return -1;
        }
    }
    if (calls == failure_call) {
        errno = EIO;
        return -1;
    }
    return capture_real_sync(descriptor);
}

int capture_sync_calls(void) { return calls; }
unsigned long long capture_sync_inode(int index)
{
    return index >= 0 && index < calls ? (unsigned long long)observed[index].st_ino : 0;
}
int capture_sync_is_directory(int index)
{
    return index >= 0 && index < calls && S_ISDIR(observed[index].st_mode);
}
