// SPDX-License-Identifier: GPL-2.0-only
#include "Support.h"
#include <zlib.h>
#include <stdlib.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <errno.h>
#include <string.h>

void *gravity_inflate_create(void) {
    z_stream *s = calloc(1, sizeof(z_stream));
    if (!s) return NULL;
    if (inflateInit2(s, -MAX_WBITS) != Z_OK) { free(s); return NULL; }
    return s;
}
int gravity_inflate(void *state, const uint8_t *input, size_t *input_size, uint8_t *output, size_t *output_size) {
    z_stream *s = state;
    s->next_in = (Bytef *)input; s->avail_in = (uInt)*input_size;
    s->next_out = output; s->avail_out = (uInt)*output_size;
    int result = inflate(s, Z_NO_FLUSH);
    *input_size -= s->avail_in; *output_size -= s->avail_out;
    return result;
}
void gravity_inflate_destroy(void *state) { if (state) { inflateEnd(state); free(state); } }
uint32_t gravity_crc32(uint32_t crc, const uint8_t *data, size_t size) { return (uint32_t)crc32(crc, data, (uInt)size); }
int gravity_bootable(const char *path, int value) {
    int cmd = value;
    if (fsctl(path, 0xc0044a57UL, &cmd, 0) == -1) return -errno;
    return cmd;
}
int gravity_set_compressed(const char *path, uint64_t size) {
    // decmpfs type 12: LZFSE in the resource fork, little endian header.
    uint8_t hdr[16] = {0x66, 0x70, 0x6d, 0x63, 12, 0, 0, 0};
    for (int i = 0; i < 8; i++) hdr[8+i] = (uint8_t)(size >> (8*i));
    if (getxattr(path, "com.apple.ResourceFork", NULL, 0, 0, XATTR_SHOWCOMPRESSION) <= 0) return -2000-errno;
    if (setxattr(path, "com.apple.decmpfs", hdr, sizeof(hdr), 0, 0) < 0) return -errno;
    struct stat st;
    if (stat(path, &st) < 0) return -errno;
    if (chflags(path, st.st_flags | UF_COMPRESSED) < 0) return -errno;
    uint8_t check[16];
    if (getxattr(path, "com.apple.decmpfs", check, sizeof(check), 0, XATTR_SHOWCOMPRESSION) != 16) return -3000-errno;
    if (memcmp(hdr, check, sizeof(hdr)) != 0) return -4000;
    if (getxattr(path, "com.apple.ResourceFork", NULL, 0, 0, XATTR_SHOWCOMPRESSION) <= 0) return -5000-errno;
    return 0;
}
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <poll.h>
#include <termios.h>
int gravity_spawn_pty(const char *executable, char *const argv[], int *master) {
    int fd = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (grantpt(fd) || unlockpt(fd)) { close(fd); return -1; }
    const char *name = ptsname(fd);
    int slave = open(name, O_RDWR | O_NOCTTY);
    if (slave < 0) { close(fd); return -1; }
    pid_t pid = fork();
    if (pid == 0) {
        close(fd); setsid(); ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, 0); dup2(slave, 1); dup2(slave, 2);
        if (slave > 2) close(slave);
        execv(executable, argv); _exit(127);
    }
    close(slave);
    if (pid < 0) { close(fd); return -1; }
    *master = fd; return pid;
}
int gravity_wait_pty(int pid) {
    int status;
    while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return -1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}
int gravity_poll_readable(int fd, int milliseconds) {
    struct pollfd p = {fd, POLLIN, 0};
    int result;
    do { result = poll(&p, 1, milliseconds); } while (result < 0 && errno == EINTR);
    return result;
}
int gravity_terminal_echo(int fd) {
    struct termios settings;
    if (tcgetattr(fd, &settings) < 0) return -1;
    return (settings.c_lflag & ECHO) != 0;
}
#include <stdio.h>
int gravity_swap_paths(const char *first, const char *second) {
    return renameatx_np(AT_FDCWD, first, AT_FDCWD, second, RENAME_SWAP);
}
