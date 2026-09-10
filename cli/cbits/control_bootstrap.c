#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <crt_externs.h>
#endif

static int frontend_parent;

/* Reserve fd 3 before the threaded RTS can allocate an event-manager descriptor. */
void agentic_bootstrap_control_fd(void)
{
    const char *requested = getenv("AGENT_CAT_TUI_BOOTSTRAP_FD3");
    if (frontend_parent || requested == NULL || strcmp(requested, "1") != 0)
        return;

    if (dup2(STDIN_FILENO, 3) < 0)
        goto failed;
    int input = open("/dev/null", O_RDONLY);
    if (input < 0 || dup2(input, STDIN_FILENO) < 0)
        goto failed;
    if (input != STDIN_FILENO && input != 3)
        close(input);
    if (unsetenv("AGENT_CAT_TUI_BOOTSTRAP_FD3") < 0)
        goto failed;
    return;

failed:
    {
        static const char message[] = "agent-cat: private control descriptor bootstrap failed\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(3);
    }
}

#ifdef __APPLE__
__attribute__((constructor)) static void initialize_control_descriptor(void)
{
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
#else
__attribute__((constructor)) static void initialize_control_descriptor(int argc, char **argv, char **environment)
{
    (void)environment;
#endif
    const char *worker = getenv("AGENT_CAT_FRONTEND_WORKER");
    frontend_parent = argc > 1 && strcmp(argv[1], "frontend") == 0 &&
        (worker == NULL || strcmp(worker, "1") != 0);
    agentic_bootstrap_control_fd();
}
