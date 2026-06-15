#ifndef CXZ_H
#define CXZ_H

#include <stddef.h>
#include <stdint.h>

/// Decompress an XZ-compressed file to an output file.
/// Returns 0 on success, nonzero on failure.
int xz_decompress_file(const char *input_path, const char *output_path);

#endif
