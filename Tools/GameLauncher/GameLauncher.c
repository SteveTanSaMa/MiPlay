//
//  GameLauncher.c
//  MiPlay
//
//  游戏 bundle 的入口程序：由 LaunchServices 启动（使游戏进程链归属到具名 .app），
//  fork 后 exec 托管 runtime 的 wine，并把输出与退出状态写入文件供 MiPlay 读取。
//
//  用法：GameLauncher <wine 可执行文件> <程序> [参数...]
//  环境：MIPLAY_LAUNCH_LOG=输出日志路径  MIPLAY_LAUNCH_STATUS=退出状态路径  MIPLAY_LAUNCH_CWD=工作目录
//       MIPLAY_LAUNCH_PID_FILE / MIPLAY_LAUNCH_TOKEN=LaunchServices 会话握手（两者必须同时设置）
//       MIPLAY_ALLOWED_RUNTIME_VARIABLES=显式运行环境键，逗号分隔；空值清除所有受控继承键
//
//  构建（放入 MiPlay/Resources/GameLauncher）：
//    cc -O2 -arch arm64 -arch x86_64 -o MiPlay/Resources/GameLauncher Tools/GameLauncher/GameLauncher.c
//

#include <errno.h>
#include <ctype.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/loader.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int controlled_runtime_key(const char *key) {
    return strncmp(key, "MTL_", 4) == 0 || strncmp(key, "METAL_", 6) == 0 ||
           strncmp(key, "DYLD_", 5) == 0 || strncmp(key, "LSFGM_", 6) == 0 ||
           strncmp(key, "MIPLAY_LSFG_", 12) == 0 || strcmp(key, "DISABLE_LSFGM") == 0;
}

static int valid_runtime_key(const char *key) {
    size_t length = strlen(key);
    if (length == 0 || length > 255 || !controlled_runtime_key(key)) return 0;
    for (size_t index = 0; index < length; ++index) {
        unsigned char byte = (unsigned char)key[index];
        if (!((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
              (byte >= '0' && byte <= '9') || byte == '_')) return 0;
    }
    return 1;
}

static int allowed_runtime_key(const char *key, const char *allowed, const char *end) {
    for (const char *entry = allowed; entry < end; entry += strlen(entry) + 1) {
        if (strcmp(key, entry) == 0) return 1;
    }
    return 0;
}

/* LaunchServices adds inherited values even when OpenConfiguration omits
 * them. The caller lists only explicitly prepared diagnostic/injection keys.
 * Duplicate the marker before unsetenv, and fetch every other getenv pointer
 * only after this pass: mutations may invalidate prior environment pointers. */
static int sanitize_launch_services_environment(void) {
    const char *marker = getenv("MIPLAY_ALLOWED_RUNTIME_VARIABLES");
    if (!marker) return 0; /* Direct launches already use a complete environment. */
    size_t length = strlen(marker);
    if (length > 16384) return -1;
    char *allowed = strdup(marker);
    if (!allowed) return -1;
    const char *end = allowed + length;
    if (length) {
        char *entry = allowed;
        for (;;) {
            char *separator = strchr(entry, ',');
            if (separator) *separator = '\0';
            if (!valid_runtime_key(entry)) { free(allowed); return -1; }
            if (!separator) break;
            entry = separator + 1;
        }
    }
    for (size_t index = 0; environ[index];) {
        const char *entry = environ[index];
        const char *equal = strchr(entry, '=');
        if (!equal) { ++index; continue; }
        char *key = strndup(entry, (size_t)(equal - entry));
        if (!key) { free(allowed); return -1; }
        int remove = controlled_runtime_key(key) && !allowed_runtime_key(key, allowed, end);
        int result = remove ? unsetenv(key) : 0;
        free(key);
        if (result != 0) { free(allowed); return -1; }
        if (remove) index = 0; else ++index;
    }
    free(allowed);
    return unsetenv("MIPLAY_ALLOWED_RUNTIME_VARIABLES");
}

static int write_all(int fd, const char *buffer, size_t length) {
    while (length) {
        ssize_t count = write(fd, buffer, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        buffer += count;
        length -= (size_t)count;
    }
    return 0;
}

static void publish_status(const char *path, int status) {
    if (!path || !*path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, 0644);
    if (fd < 0) return;
    struct stat file;
    if (fstat(fd, &file) == 0 && S_ISREG(file.st_mode)) {
        char buffer[64];
        int length = WIFSIGNALED(status)
            ? snprintf(buffer, sizeof(buffer), "signal:%d\n", WTERMSIG(status))
            : snprintf(buffer, sizeof(buffer), "exit:%d\n", WEXITSTATUS(status));
        if (length > 0) (void)write_all(fd, buffer, (size_t)length);
    }
    close(fd);
}

static int valid_token(const char *token) {
    if (!token || strlen(token) != 36) return 0;
    for (size_t index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (token[index] != '-') return 0;
        } else if (!isxdigit((unsigned char)token[index])) return 0;
    }
    return 1;
}

/* Publish our identity before starting any Wine process, then wait for MiPlay
 * to accept supervision. NSWorkspace may otherwise return Wine's registered
 * child PID instead of this helper. Without an acknowledgement no child runs,
 * so launch cancellation and fallback cannot leave an unowned Wine session. */
static int accept_supervision(void) {
    const char *path = getenv("MIPLAY_LAUNCH_PID_FILE");
    const char *token = getenv("MIPLAY_LAUNCH_TOKEN");
    if (!path && !token) return 0; /* Direct ProcessManager launch owns us already. */
    if (!path || path[0] != '/' || !valid_token(token)) return -1;

    char *temporary = NULL;
    char *acceptance = NULL;
    if (asprintf(&temporary, "%s.%ld.tmp", path, (long)getpid()) < 0) return -1;
    if (asprintf(&acceptance, "%s.accepted", path) < 0) { free(temporary); return -1; }
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int result = -1;
    if (fd >= 0) {
        char receipt[128];
        int length = snprintf(receipt, sizeof(receipt), "v1:%s:%ld:%ld\n", token, (long)getpid(), (long)getpgrp());
        int written = length > 0 && (size_t)length < sizeof(receipt)
            ? write_all(fd, receipt, (size_t)length) : -1;
        int closed = close(fd);
        if (written == 0 && closed == 0 && rename(temporary, path) == 0) {
            struct timespec start, now;
            if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) goto finished;
            for (;;) {
                int accepted = open(acceptance, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
                if (accepted >= 0) {
                    struct stat file;
                    char contents[64];
                    ssize_t count = -1;
                    if (fstat(accepted, &file) == 0 && S_ISREG(file.st_mode) && file.st_uid == getuid() && file.st_size == 37) {
                        do { count = read(accepted, contents, sizeof(contents)); } while (count < 0 && errno == EINTR);
                    }
                    close(accepted);
                    if (count == 37 && memcmp(contents, token, 36) == 0 && contents[36] == '\n') result = 0;
                    break; /* A malformed acceptance is a refusal, never a retry. */
                }
                if (errno != ENOENT) break;
                if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec - start.tv_sec > 10 ||
                    (now.tv_sec - start.tv_sec == 10 && now.tv_nsec >= start.tv_nsec)) break;
                struct timespec delay = { .tv_sec = 0, .tv_nsec = 20000000 };
                while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
            }
        }
    }
finished:
    unlink(temporary);
    unlink(acceptance);
    unlink(path);
    free(temporary);
    free(acceptance);
    return result;
}

/* Relay is inert in the universal launcher: DYLD is materialized only in the
 * fork child immediately before exec of a verified thin x86_64 executable.
 * Resource hashes and GPU preflight are the application caller's responsibility. */
static int x86_macho(const char *path, uint32_t filetype) {
    struct mach_header_64 header;
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    int ok = fread(&header, sizeof(header), 1, file) == 1 &&
             header.magic == MH_MAGIC_64 && header.cputype == CPU_TYPE_X86_64 &&
             header.filetype == filetype;
    fclose(file);
    return ok;
}

static void clear_lsfg_for_waiter(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    for (size_t index = 0; environ[index];) {
        const char *entry = environ[index];
        if (strncmp(entry, "LSFGM_", 6) == 0 || strncmp(entry, "MIPLAY_LSFG_", 12) == 0) {
            const char *equal = strchr(entry, '=');
            if (!equal) { ++index; continue; }
            char *key = strndup(entry, (size_t)(equal - entry));
            if (!key) _exit(70);
            int result = unsetenv(key);
            free(key);
            if (result != 0) _exit(70);
            index = 0;
        } else { ++index; }
    }
}

int main(int argc, char *argv[]) {
    if (sanitize_launch_services_environment() != 0) {
        fprintf(stderr, "GameLauncher: invalid explicit runtime environment allowlist\n");
        return 78;
    }
    if (argc < 3) {
        fprintf(stderr, "GameLauncher: 参数不足（需要 wine 路径与程序参数）\n");
        return 64;
    }

    const char *relay = getenv("MIPLAY_LSFG_LIBRARY");
    if (relay && (!*relay || relay[0] != '/' || strchr(relay, ':') ||
                  !x86_macho(relay, MH_DYLIB) || !x86_macho(argv[1], MH_EXECUTE))) {
        fprintf(stderr, "GameLauncher: invalid LSFG relay or non-x86_64 target\n");
        return 78;
    }

    const char *logPath = getenv("MIPLAY_LAUNCH_LOG");
    const char *statusPath = getenv("MIPLAY_LAUNCH_STATUS");
    const char *cwd = getenv("MIPLAY_LAUNCH_CWD");

    /* 自成进程组：MiPlay 按组终止时不会遗留孤儿进程。 */
    if (setpgid(0, 0) != 0 && getpgrp() != getpid()) {
        perror("GameLauncher: process group");
        return 70;
    }
    if (accept_supervision() != 0) {
        fprintf(stderr, "GameLauncher: launch supervision was not accepted; Wine was not started\n");
        return 78;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("GameLauncher: fork");
        publish_status(statusPath, 70 << 8);
        return 70;
    }

    if (child == 0) {
        if (cwd && *cwd) {
            if (chdir(cwd) != 0) {
                perror("GameLauncher: chdir");
                _exit(72);
            }
        }
        if (logPath && *logPath) {
            /* 输出日志封顶：超过 64MB 时丢弃旧内容，避免调试通道洪泛写满磁盘。 */
            struct stat existing;
            if (stat(logPath, &existing) == 0 && existing.st_size > (64 * 1024 * 1024)) {
                unlink(logPath);
            }
            int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0644);
            struct stat opened;
            if (fd < 0 || fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode) ||
                dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) {
                perror("GameLauncher: log");
                _exit(73);
            }
            close(fd);
        }
        unsetenv("DYLD_INSERT_LIBRARIES");
        if (relay && setenv("DYLD_INSERT_LIBRARIES", relay, 1) != 0) {
            perror("GameLauncher: LSFG relay");
            _exit(78);
        }
        unsetenv("MIPLAY_LSFG_LIBRARY");
        unsetenv("MIPLAY_LAUNCH_PID_FILE");
        unsetenv("MIPLAY_LAUNCH_TOKEN");
        execv(argv[1], &argv[1]);
        perror("GameLauncher: execv");
        _exit(127);
    }

    int status = 0;
    int waitError = 0;
    for (;;) {
        if (waitpid(child, &status, 0) >= 0) {
            break;
        }
        if (errno != EINTR) {
            waitError = errno;
            break;
        }
    }

    if (waitError) {
        errno = waitError;
        perror("GameLauncher: waitpid");
        publish_status(statusPath, 70 << 8);
        return 70;
    }

    /* Steam/Jadeite may finish before the game child. Match YAAGL's
       wineserver -w boundary before publishing an exit and releasing prefix. */
    const char *server = getenv("MIPLAY_WAIT_WINESERVER");
    if (server && *server && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        pid_t waiter = fork();
        if (waiter == 0) {
            clear_lsfg_for_waiter();
            unsetenv("MIPLAY_LAUNCH_PID_FILE");
            unsetenv("MIPLAY_LAUNCH_TOKEN");
            execl(server, server, "-w", (char *)NULL);
            perror("GameLauncher: wineserver -w");
            _exit(127);
        }
        if (waiter < 0) {
            status = 70 << 8;
        } else {
            while (waitpid(waiter, &status, 0) < 0) {
                if (errno != EINTR) { status = 70 << 8; break; }
            }
        }
    }

    publish_status(statusPath, status);

    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}
