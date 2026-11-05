/* HDIFF13 streaming adapter. HDiffPatch 5.1.3, commit
 * 06961361340085ddb2a551775dc402172b8ca67c; see LICENSE.txt. */
#define _IS_USED_MULTITHREAD 0
#include "patch_implementation.h"
#include <errno.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*MPCancelled)(void *context);
typedef struct { int fd; uint64_t base; MPCancelled cancelled; void *context; int *io_error; } MPInput;
typedef struct { int fd; uint64_t next; MPCancelled cancelled; void *context; int *io_error; } MPOutput;

/* Preserve the first operating-system failure independently of the decoder's
 * generic false result. A short read/write inside an advertised stream means
 * the file changed or could not be accessed, not that the patch is invalid. */
static void mp_record_io_error(int *result, int code) {
    if (*result == 0) *result = code > 0 ? code : EIO;
}

static hpatch_BOOL mp_read(const hpatch_TStreamInput *stream, hpatch_StreamPos_t pos,
                          unsigned char *begin, unsigned char *end) {
    MPInput *input = (MPInput *)stream->streamImport;
    if (input->cancelled && input->cancelled(input->context)) return hpatch_FALSE;
    size_t size = (size_t)(end - begin);
    if (pos > stream->streamSize || size > stream->streamSize - pos ||
        input->base > INT64_MAX - pos || size > INT64_MAX - input->base - pos) return hpatch_FALSE;
    uint64_t offset = input->base + pos;
    while (begin < end) {
        if (input->cancelled && input->cancelled(input->context)) return hpatch_FALSE;
        ssize_t n = pread(input->fd, begin, (size_t)(end - begin), (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            mp_record_io_error(input->io_error, n < 0 ? errno : EIO);
            return hpatch_FALSE;
        }
        begin += n; offset += (uint64_t)n;
    }
    return hpatch_TRUE;
}

static hpatch_BOOL mp_write(const hpatch_TStreamOutput *stream, hpatch_StreamPos_t pos,
                           const unsigned char *begin, const unsigned char *end) {
    MPOutput *output = (MPOutput *)stream->streamImport;
    if (output->cancelled && output->cancelled(output->context)) return hpatch_FALSE;
    size_t size = (size_t)(end - begin);
    if (pos != output->next || pos > stream->streamSize || size > stream->streamSize - pos ||
        pos > INT64_MAX || size > INT64_MAX - pos) return hpatch_FALSE;
    while (begin < end) {
        if (output->cancelled && output->cancelled(output->context)) return hpatch_FALSE;
        ssize_t n = pwrite(output->fd, begin, (size_t)(end - begin), (off_t)pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            mp_record_io_error(output->io_error, n < 0 ? errno : EIO);
            return hpatch_FALSE;
        }
        begin += n; pos += (uint64_t)n;
    }
    output->next = pos;
    return hpatch_TRUE;
}

/* The caller owns all three descriptors and must verify input/output hashes.
 * The output must be a new, empty, regular file distinct from both inputs.
 * A failure can leave a partial output; the caller must discard it.
 * Returns 1 on success, 0 for invalid/unsupported input or cancellation,
 * and a negative POSIX error number for an operating-system I/O failure. */
int miplay_hdiff_apply(int old_fd, int diff_fd, int out_fd, uint64_t diff_offset,
                       uint64_t diff_length, uint64_t old_size, uint64_t new_size,
                       MPCancelled cancelled, void *context) {
    struct stat old_stat, diff_stat, out_stat;
    if (old_size > INT64_MAX || new_size > INT64_MAX || diff_offset > INT64_MAX ||
        diff_length > INT64_MAX - diff_offset) return 0;
    if (fstat(old_fd, &old_stat) || fstat(diff_fd, &diff_stat) || fstat(out_fd, &out_stat)) {
        return -(errno > 0 ? errno : EIO);
    }
    if (
        !S_ISREG(old_stat.st_mode) || !S_ISREG(diff_stat.st_mode) || !S_ISREG(out_stat.st_mode) ||
        old_stat.st_size < 0 || diff_stat.st_size < 0 || out_stat.st_size != 0 ||
        (uint64_t)old_stat.st_size != old_size || diff_offset + diff_length > (uint64_t)diff_stat.st_size ||
        (out_stat.st_dev == old_stat.st_dev && out_stat.st_ino == old_stat.st_ino) ||
        (out_stat.st_dev == diff_stat.st_dev && out_stat.st_ino == diff_stat.st_ino)) return 0;

    int io_error = 0;
    MPInput old_input = {old_fd, 0, cancelled, context, &io_error}, diff_input = {diff_fd, diff_offset, cancelled, context, &io_error};
    MPOutput new_output = {out_fd, 0, cancelled, context, &io_error};
    hpatch_TStreamInput old_stream = {&old_input, old_size, mp_read, 0};
    hpatch_TStreamInput diff_stream = {&diff_input, diff_length, mp_read, 0};
    hpatch_TStreamOutput new_stream = {&new_output, new_size, 0, mp_write};
    hpatch_compressedDiffInfo info;
    if (!getCompressedDiffInfo(&info, &diff_stream) || info.oldDataSize != old_size ||
        info.newDataSize != new_size || info.compressedCount != 0 || info.compressType[0] != '\0')
        return io_error ? -io_error : 0;
    hpatch_BOOL applied = patch_decompress(&new_stream, &old_stream, &diff_stream, 0);
    return io_error ? -io_error : (applied && new_output.next == new_size);
}
