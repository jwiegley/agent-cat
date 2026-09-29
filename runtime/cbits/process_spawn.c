/* Session spawn for Agentic.Runtime.ProcessGroup on Apple platforms.

   process-1.6.26.1 cannot use posix_spawn when close_fds is set, so on macOS
   it forks and the child closes every descriptor up to the soft
   RLIMIT_NOFILE.  At a limit of 1048576 that loop costs about 100 ms for each
   spawn.  This helper spawns with POSIX_SPAWN_CLOEXEC_DEFAULT instead, so the
   child receives only the descriptors that its file actions name, and with
   POSIX_SPAWN_SETSID, so the child leads a new session and process group.

   Executable resolution keeps the rules of the process-library fork path.
   With an explicit environment, the executable is found as process-1.6.26.1
   find_executable finds it, and it is executed without a shell fallback, as
   execve executes it.  Without an explicit environment, the candidates of
   execvp are tried in order, relative to the child working directory.  The
   helper never calls posix_spawnp: on macOS, posix_spawnp with a chdir file
   action and a relative PATH entry reports ENOENT and still leaves a child,
   which exits with status 127 and stays a zombie that no caller owns.

   The working directory is set with posix_spawn_file_actions_addchdir_np,
   which the apple-sdk-14.4 headers of the build declare without a
   deprecation.  The macOS 26 SDK deprecates it in favour of
   posix_spawn_file_actions_addchdir.  A build against those headers reports
   a deprecation warning, and the -optc-Werror of runtime/ci/capture.sh makes
   that warning an error. */
#ifdef __APPLE__
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <paths.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

/* Standard stream modes, as the process library encodes them. */
#define AGENTIC_STREAM_PIPE (-1)
#define AGENTIC_STREAM_CLOSED (-2)

struct stream {
    int mode;
    int child_end;
    int parent_end;
    /* An inherited standard descriptor that the parent held closed before
       any pipe was created. */
    bool closed_in_parent;
};

static char *join_path(const char *directory, const char *path)
{
    size_t length = strlen(directory) + 1 + strlen(path) + 1;
    char *joined = malloc(length);
    if (joined != NULL)
        snprintf(joined, length, "%s/%s", directory, path);
    return joined;
}

/* process-1.6.26.1 is_executable: relative to the working directory. */
static bool is_executable(const char *directory, const char *path)
{
    if (directory != NULL && path[0] != '/') {
        char *joined = join_path(directory, path);
        bool result = joined != NULL && access(joined, X_OK) == 0;
        free(joined);
        return result;
    }
    return access(path, X_OK) == 0;
}

/* process-1.6.26.1 find_executable, including its search of the parent PATH
   and its prefix of the working directory for relative PATH entries.  The
   result is always allocated.  NULL means that no candidate was found. */
static char *find_executable(const char *directory, const char *filename)
{
    char *trimmed = NULL;
    if (directory != NULL) {
        size_t length = strlen(directory);
        if (length > 0 && directory[length - 1] == '/') {
            trimmed = strdup(directory);
            if (trimmed == NULL)
                return NULL;
            trimmed[length - 1] = '\0';
            directory = trimmed;
        }
    }
    char *result = NULL;
    if (filename[0] == '/') {
        result = strdup(filename);
        goto done;
    }
    if (strchr(filename, '/') != NULL && is_executable(directory, filename)) {
        result = strdup(filename);
        goto done;
    }
    const char *path = getenv("PATH");
    char *search = strdup(path != NULL ? path : ":");
    if (search == NULL)
        goto done;
    const char *base = directory != NULL ? directory : ".";
    char *state;
    for (char *entry = strtok_r(search, ":", &state); entry != NULL; entry = strtok_r(NULL, ":", &state)) {
        char *candidate;
        if (entry[0] == '/') {
            candidate = join_path(entry, filename);
        } else {
            char *prefix = join_path(base, entry);
            candidate = prefix != NULL ? join_path(prefix, filename) : NULL;
            free(prefix);
        }
        if (candidate != NULL && is_executable(base, candidate)) {
            result = candidate;
            break;
        }
        free(candidate);
    }
    free(search);
done:
    free(trimmed);
    return result;
}

/* stat(2) of a candidate as the child would see it after its chdir. */
static int stat_in_child_directory(const char *directory, const char *path, struct stat *status)
{
    if (directory == NULL || path[0] == '/')
        return stat(path, status);
    char *joined = join_path(directory, path);
    if (joined == NULL)
        return -1;
    int result = stat(joined, status);
    free(joined);
    return result;
}

/* The candidate loop of the macOS execvp (execvP with the parent PATH or
   _PATH_DEFPATH), with each exec attempt made by posix_spawn.  A name that
   contains a slash is the only candidate.  Returns an errno value, or zero
   when a child was started. */
static int spawn_searching(pid_t *pid, const char *directory, char *const argv[],
                           posix_spawn_file_actions_t *actions, posix_spawnattr_t *attributes)
{
    const char *name = argv[0];
    bool direct = strchr(name, '/') != NULL;
    char *search = NULL;
    if (!direct) {
        if (name[0] == '\0')
            return ENOENT;
        const char *path = getenv("PATH");
        search = strdup(path != NULL ? path : _PATH_DEFPATH);
        if (search == NULL)
            return ENOMEM;
    }
    int result = ENOENT;
    bool denied = false;
    bool tried = false;
    char *cursor = search;
    char candidate[PATH_MAX];
    for (;;) {
        const char *attempt;
        if (direct) {
            if (tried)
                break;
            tried = true;
            attempt = name;
        } else {
            char *entry = strsep(&cursor, ":");
            if (entry == NULL)
                break;
            if (entry[0] == '\0')
                entry = ".";
            if (strlen(entry) + strlen(name) + 2 > sizeof candidate)
                continue;
            snprintf(candidate, sizeof candidate, "%s/%s", entry, name);
            attempt = candidate;
        }
        int error = posix_spawn(pid, attempt, actions, attributes, argv, environ);
        if (error == 0) {
            result = 0;
            goto done;
        }
        switch (error) {
        case ELOOP:
        case ENAMETOOLONG:
        case ENOENT:
        case ENOTDIR:
            continue;
        case ENOEXEC: {
            size_t count = 0;
            while (argv[count] != NULL)
                count++;
            char **shell = calloc(count + 2, sizeof *shell);
            if (shell == NULL) {
                result = ENOMEM;
                goto done;
            }
            shell[0] = "sh";
            shell[1] = (char *)attempt;
            for (size_t index = 1; index <= count; index++)
                shell[index + 1] = argv[index];
            result = posix_spawn(pid, _PATH_BSHELL, actions, attributes, shell, environ);
            free(shell);
            goto done;
        }
        case E2BIG:
        case ENOMEM:
        case ETXTBSY:
            result = error;
            goto done;
        default: {
            struct stat status;
            if (stat_in_child_directory(directory, attempt, &status) != 0)
                continue;
            if (error == EACCES) {
                denied = true;
                continue;
            }
            result = error;
            goto done;
        }
        }
    }
    result = denied ? EACCES : ENOENT;
done:
    free(search);
    return result;
}

static int open_stream(struct stream *stream, bool child_reads)
{
    stream->child_end = -1;
    stream->parent_end = -1;
    if (stream->mode != AGENTIC_STREAM_PIPE)
        return 0;
    int ends[2];
    if (pipe(ends) != 0)
        return -1;
    int child_end = child_reads ? ends[0] : ends[1];
    int parent_end = child_reads ? ends[1] : ends[0];
    int flags;
    /* No other spawn in this process may inherit either end.  The parent end
       is nonblocking, as the process library leaves it, so that building its
       Handle makes no system call. */
    if (fcntl(child_end, F_SETFD, FD_CLOEXEC) != 0 || fcntl(parent_end, F_SETFD, FD_CLOEXEC) != 0
        || (flags = fcntl(parent_end, F_GETFL)) == -1 || fcntl(parent_end, F_SETFL, flags | O_NONBLOCK) != 0) {
        int saved = errno;
        close(ends[0]);
        close(ends[1]);
        errno = saved;
        return -1;
    }
    stream->child_end = child_end;
    stream->parent_end = parent_end;
    return 0;
}

static void close_stream(struct stream *stream, bool parent_too)
{
    if (stream->child_end >= 0)
        close(stream->child_end);
    if (parent_too && stream->parent_end >= 0)
        close(stream->parent_end);
}

/* Name one standard descriptor in the file actions.  A closed stream is not
   named, so POSIX_SPAWN_CLOEXEC_DEFAULT leaves it closed in the child.  The
   actions for descriptors 0, 1 and 2 are added in that order, as the fork path
   applies them, so a pipe end that took a lower standard number is copied
   before that number is overwritten.  A pipe end that is only the source of a
   copy is not named, so the child does not hold it. */
static int name_stream(posix_spawn_file_actions_t *actions, int target, const struct stream *stream)
{
    int source;
    if (stream->mode == AGENTIC_STREAM_CLOSED)
        return 0;
    source = stream->mode == AGENTIC_STREAM_PIPE ? stream->child_end : stream->mode;
    if (source != target)
        return posix_spawn_file_actions_adddup2(actions, source, target);
    /* The fork path left a closed inherited descriptor closed, even when a
       pipe end for another stream has since taken its number. */
    if (stream->closed_in_parent)
        return 0;
    return posix_spawn_file_actions_addinherit_np(actions, target);
}

/* Spawn argv in a new session.  modes[i] is AGENTIC_STREAM_PIPE,
   AGENTIC_STREAM_CLOSED, or a descriptor to inherit as standard descriptor i.
   On success the parent pipe ends are stored in parent_ends, each with
   FD_CLOEXEC and O_NONBLOCK set, and the PID is returned.  On failure no child exists, every
   pipe is closed, *failed_doing names the failed step, errno holds the error,
   and -1 is returned. */
int agentic_spawn_session(char *const argv[], const char *directory, char *const environment[],
                          const int modes[3], int parent_ends[3], const char **failed_doing)
{
    struct stream streams[3];
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    char *executable = NULL;
    pid_t pid = -1;
    int error = 0;
    int opened = 0;

    for (int index = 0; index < 3; index++) {
        streams[index].mode = modes[index];
        streams[index].closed_in_parent = modes[index] == index && fcntl(index, F_GETFD) == -1;
    }
    for (; opened < 3; opened++) {
        if (open_stream(&streams[opened], opened == 0) != 0) {
            error = errno;
            *failed_doing = "pipe";
            goto streams;
        }
    }
    if ((error = posix_spawn_file_actions_init(&actions)) != 0) {
        *failed_doing = "posix_spawn_file_actions_init";
        goto streams;
    }
    if ((error = posix_spawnattr_init(&attributes)) != 0) {
        *failed_doing = "posix_spawnattr_init";
        goto actions;
    }
    if ((error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) != 0) {
        *failed_doing = "posix_spawnattr_setflags";
        goto attributes;
    }
    if (directory != NULL && (error = posix_spawn_file_actions_addchdir_np(&actions, directory)) != 0) {
        *failed_doing = "posix_spawn_file_actions_addchdir_np";
        goto attributes;
    }
    for (int target = 0; target < 3; target++) {
        if ((error = name_stream(&actions, target, &streams[target])) != 0) {
            *failed_doing = "posix_spawn_file_actions";
            goto attributes;
        }
    }
    if (environment != NULL) {
        executable = find_executable(directory, argv[0]);
        if (executable == NULL) {
            /* process-1.6.26.1 reports this step with errno set to -ENOENT. */
            error = -ENOENT;
            *failed_doing = "find_executable";
            goto attributes;
        }
        error = posix_spawn(&pid, executable, &actions, &attributes, argv, environment);
    } else {
        error = spawn_searching(&pid, directory, argv, &actions, &attributes);
    }
    if (error != 0)
        *failed_doing = "posix_spawn";

attributes:
    posix_spawnattr_destroy(&attributes);
actions:
    posix_spawn_file_actions_destroy(&actions);
streams:
    free(executable);
    for (int index = 0; index < opened; index++)
        close_stream(&streams[index], error != 0);
    if (error != 0) {
        errno = error;
        return -1;
    }
    for (int index = 0; index < 3; index++)
        parent_ends[index] = streams[index].parent_end;
    return pid;
}
#endif
