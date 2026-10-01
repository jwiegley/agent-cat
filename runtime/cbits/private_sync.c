#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _DEFAULT_SOURCE
#endif
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

/* Take an exclusive flock(2) on the open file description without waiting.
   Every descriptor that shares the description shares the lock. */
int agentic_lock_private_descriptor(int descriptor)
{
    return flock(descriptor, LOCK_EX | LOCK_NB);
}

int agentic_sync_private_descriptor(int descriptor)
{
    if (fsync(descriptor) == -1)
        return -1;
#ifdef __APPLE__
    return fcntl(descriptor, F_FULLFSYNC);
#else
    return 0;
#endif
}
