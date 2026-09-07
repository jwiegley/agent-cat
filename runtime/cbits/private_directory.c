#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <stddef.h>

int agentic_read_directory_name(DIR *stream, const char **name)
{
    errno = 0;
    struct dirent *entry = readdir(stream);
    if (entry == NULL)
        return errno == 0 ? 0 : -1;
    *name = entry->d_name;
    return 1;
}
