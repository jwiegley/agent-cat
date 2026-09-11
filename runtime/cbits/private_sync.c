#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include <fcntl.h>
#include <unistd.h>

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
