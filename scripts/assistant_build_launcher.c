/*
 * Launcher for the MeetingScribe assistant build daemon.
 *
 * The repository lives under ~/Documents, which is TCC-protected. A LaunchAgent
 * has its own TCC identity, so a plain `python3 .../daemon.py` agent cannot even
 * open the script. Granting Full Disk Access to /usr/bin/python3 would hand that
 * access to every python process on the machine, so instead this tiny binary is
 * the main executable of a dedicated app bundle that gets the grant.
 *
 * It deliberately does NOT exec python3: the granted bundle identity has to stay
 * alive as the parent, and the python child then inherits the TCC responsibility
 * (the same mechanism that gives everything started from Terminal Terminal's own
 * access). Replacing the process image would hand the identity back to python3
 * and the grant would not apply.
 *
 * Compiled by scripts/install-assistant-build-daemon.sh with the script path
 * baked in, so it parses no arguments and reads no configuration.
 */

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef DAEMON_SCRIPT
#error "DAEMON_SCRIPT must be defined at compile time"
#endif

#ifndef DAEMON_PYTHON
#define DAEMON_PYTHON "/usr/bin/python3"
#endif

static volatile pid_t child_pid = -1;

static void forward_signal(int signal_number) {
    if (child_pid > 0) {
        kill(child_pid, signal_number);
    }
}

int main(void) {
    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);
    signal(SIGHUP, forward_signal);

    child_pid = fork();
    if (child_pid < 0) {
        perror("fork");
        return 70;
    }

    if (child_pid == 0) {
        char *const arguments[] = {
            (char *)DAEMON_PYTHON,
            (char *)DAEMON_SCRIPT,
            NULL,
        };
        execv(DAEMON_PYTHON, arguments);
        perror("execv " DAEMON_PYTHON);
        _exit(70);
    }

    int status = 0;
    while (waitpid(child_pid, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("waitpid");
            return 70;
        }
    }

    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return WEXITSTATUS(status);
}
