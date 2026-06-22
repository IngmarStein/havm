// Thin wrapper around liblzma for XZ decompression.
// macOS ships liblzma.dylib — we link directly via -llzma.
// Since Apple doesn't ship the headers, we declare the minimal API surface here.

#include "xz.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

// ---- Minimal liblzma type declarations ----

typedef enum {
    LZMA_OK                 = 0,
    LZMA_STREAM_END         = 1,
    LZMA_NO_CHECK           = 2,
    LZMA_UNSUPPORTED_CHECK  = 3,
    LZMA_GET_CHECK          = 4,
    LZMA_MEM_ERROR          = 5,
    LZMA_MEMLIMIT_ERROR     = 6,
    LZMA_FORMAT_ERROR       = 7,
    LZMA_OPTIONS_ERROR      = 8,
    LZMA_DATA_ERROR         = 9,
    LZMA_BUF_ERROR          = 10,
    LZMA_PROG_ERROR         = 11,
} lzma_ret;

typedef enum {
    LZMA_RESERVED_ENUM      = 0,
    LZMA_RUN                = 0,
    LZMA_SYNC_FLUSH         = 1,
    LZMA_FULL_FLUSH         = 2,
    LZMA_FULL_BARRIER       = 4,
    LZMA_FINISH             = 3
} lzma_action;

typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;
    void *allocator;
    void *internal;
    void *reserved_ptr1;
    void *reserved_ptr2;
    void *reserved_ptr3;
    void *reserved_ptr4;
    uint64_t reserved_int1;
    uint64_t reserved_int2;
    size_t reserved_int3;
    size_t reserved_int4;
    int reserved_enum1;
    int reserved_enum2;
} lzma_stream;

#define LZMA_STREAM_INIT { NULL, 0, 0, NULL, 0, 0, NULL, NULL, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0, 0 }
#define LZMA_TELL_NO_CHECK          0x01U
#define LZMA_TELL_UNSUPPORTED_CHECK 0x02U
#define LZMA_TELL_ANY_CHECK         0x04U
#define LZMA_CONCATENATED           0x08U
#define LZMA_IGNORE_CHECK           0x10U

// Direct calls into liblzma — resolved at link time.
extern lzma_ret lzma_stream_decoder(lzma_stream *strm, uint64_t memlimit, uint32_t flags);
extern lzma_ret lzma_code(lzma_stream *strm, lzma_action action);
extern void     lzma_end(lzma_stream *strm);

// ---- Implementation ----

#define INPUT_BUF_SIZE  (256 * 1024)
#define OUTPUT_BUF_SIZE (256 * 1024)

int xz_decompress_file(const char *input_path, const char *output_path) {
    // Open input file
    FILE *in = fopen(input_path, "rb");
    if (!in) {
        perror("fopen input");
        return 1;
    }

    // Open output file
    FILE *out = fopen(output_path, "wb");
    if (!out) {
        perror("fopen output");
        fclose(in);
        return 1;
    }

    // Allocate buffers
    uint8_t *in_buf = malloc(INPUT_BUF_SIZE);
    uint8_t *out_buf = malloc(OUTPUT_BUF_SIZE);
    if (!in_buf || !out_buf) {
        fprintf(stderr, "malloc failed\n");
        free(in_buf);
        free(out_buf);
        fclose(out);
        fclose(in);
        return 1;
    }

    // Initialize decoder
    lzma_stream strm = LZMA_STREAM_INIT;
    lzma_ret ret = lzma_stream_decoder(&strm, UINT64_MAX, 0);
    if (ret != LZMA_OK) {
        fprintf(stderr, "lzma_stream_decoder failed: %d\n", ret);
        goto cleanup;
    }

    // Decompress loop
    strm.next_in = NULL;
    strm.avail_in = 0;
    strm.next_out = out_buf;
    strm.avail_out = OUTPUT_BUF_SIZE;

    lzma_action action = LZMA_RUN;
    int done = 0;

    while (!done) {
        // Refill input buffer
        if (strm.avail_in == 0 && !feof(in)) {
            strm.next_in = in_buf;
            strm.avail_in = fread(in_buf, 1, INPUT_BUF_SIZE, in);
            if (ferror(in)) {
                perror("fread");
                ret = LZMA_PROG_ERROR;
                goto cleanup;
            }
            if (feof(in)) {
                action = LZMA_FINISH;
            }
        }

        ret = lzma_code(&strm, action);

        // Write output when buffer is full or we're finishing
        if (strm.avail_out == 0 || ret == LZMA_STREAM_END) {
            size_t write_size = OUTPUT_BUF_SIZE - strm.avail_out;
            if (fwrite(out_buf, 1, write_size, out) != write_size) {
                perror("fwrite");
                ret = LZMA_PROG_ERROR;
                goto cleanup;
            }
            strm.next_out = out_buf;
            strm.avail_out = OUTPUT_BUF_SIZE;
        }

        if (ret == LZMA_STREAM_END) {
            done = 1;
        } else if (ret != LZMA_OK) {
            fprintf(stderr, "lzma_code error: %d\n", ret);
            goto cleanup;
        }
    }

cleanup:
    lzma_end(&strm);
    free(in_buf);
    free(out_buf);
    fclose(out);
    fclose(in);

    if (ret != LZMA_STREAM_END) {
        // Remove partial output on error
        remove(output_path);
        return 1;
    }

    return 0;
}
