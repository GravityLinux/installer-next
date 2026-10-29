// SPDX-License-Identifier: GPL-2.0-only
#include <stddef.h>
#include <stdint.h>
void *gravity_inflate_create(void);
int gravity_inflate(void *state, const uint8_t *input, size_t *input_size, uint8_t *output, size_t *output_size);
void gravity_inflate_destroy(void *state);
uint32_t gravity_crc32(uint32_t crc, const uint8_t *data, size_t size);
int gravity_bootable(const char *path, int value);
int gravity_set_compressed(const char *path, uint64_t size);
int gravity_spawn_pty(const char *executable, char *const argv[], int *master);
int gravity_wait_pty(int pid);
int gravity_poll_readable(int fd, int milliseconds);
int gravity_terminal_echo(int fd);
int gravity_swap_paths(const char *first, const char *second);
