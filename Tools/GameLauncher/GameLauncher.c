//
//  GameLauncher.c
//  MiPlay
//
//  游戏 bundle 的入口程序：由 LaunchServices 启动（使游戏进程链归属到具名 .app），
//  fork 后 exec 托管 runtime 的 wine，并把输出与退出状态写入文件供 MiPlay 读取。
//
//  用法：GameLauncher <wine 可执行文件> <程序> [参数...]
//  环境：MIPLAY_LAUNCH_LOG=输出日志路径  MIPLAY_LAUNCH_STATUS=退出状态路径  MIPLAY_LAUNCH_CWD=工作目录
//
//  构建（放入 MiPlay/Resources/GameLauncher）：
//    cc -O2 -arch arm64 -arch x86_64 -o MiPlay/Resources/GameLauncher Tools/GameLauncher/GameLauncher.c
//

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "GameLauncher: 参数不足（需要 wine 路径与程序参数）\n");
        return 64;
    }

    /* 自成进程组：MiPlay 按组终止时不会遗留孤儿进程。 */
    setpgid(0, 0);

    const char *logPath = getenv("MIPLAY_LAUNCH_LOG");
    const char *statusPath = getenv("MIPLAY_LAUNCH_STATUS");
    const char *cwd = getenv("MIPLAY_LAUNCH_CWD");

    pid_t child = fork();
    if (child < 0) {
        perror("GameLauncher: fork");
        return 70;
    }

    if (child == 0) {
        if (cwd && *cwd) {
            chdir(cwd);
        }
        if (logPath && *logPath) {
            /* 输出日志封顶：超过 64MB 时丢弃旧内容，避免调试通道洪泛写满磁盘。 */
            struct stat existing;
            if (stat(logPath, &existing) == 0 && existing.st_size > (64 * 1024 * 1024)) {
                unlink(logPath);
            }
            int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                close(fd);
            }
        }
        execv(argv[1], &argv[1]);
        perror("GameLauncher: execv");
        _exit(127);
    }

    int status = 0;
    for (;;) {
        if (waitpid(child, &status, 0) >= 0) {
            break;
        }
        if (errno != EINTR) {
            break;
        }
    }

    if (statusPath && *statusPath) {
        int fd = open(statusPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            char buffer[64];
            int length;
            if (WIFSIGNALED(status)) {
                length = snprintf(buffer, sizeof(buffer), "signal:%d\n", WTERMSIG(status));
            } else {
                length = snprintf(buffer, sizeof(buffer), "exit:%d\n", WEXITSTATUS(status));
            }
            if (length > 0) {
                ssize_t written = write(fd, buffer, (size_t)length);
                (void)written;
            }
            close(fd);
        }
    }

    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}
