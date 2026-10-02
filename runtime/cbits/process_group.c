#ifndef __APPLE__
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

/* Observe this child without releasing its PID for reuse. Darwin's waitid
   also reports a stopped child for WEXITED alone, with CLD_STOPPED, so only
   the three termination codes count as an exit. */
int agentic_child_exited(int pid)
{
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0)
        return -1;
    return info.si_pid != 0 &&
           (info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED);
}

/* The caller must retain the original, unreaped session leader. */
int agentic_signal_group(int pid, int signal)
{
    if (kill(-pid, signal) == 0 || errno == ESRCH)
        return 0;
#ifdef __APPLE__
    if (errno == EPERM) {
        int exited;
        pid_t members[2];
        do {
            exited = agentic_child_exited(pid);
        } while (exited < 0 && errno == EINTR);
        /* Darwin rejects even a group containing only its zombie leader.
           The atomic two-slot enumeration must prove there is no other member. */
        if (exited > 0 &&
            proc_listpids(PROC_PGRP_ONLY, (uint32_t)pid, members, sizeof members) == sizeof(pid_t) &&
            members[0] == pid)
            return 0;
        errno = EPERM;
    }
#endif
    return -1;
}
