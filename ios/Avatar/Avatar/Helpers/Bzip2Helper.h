//
//  Bzip2Helper.h
//  SiriApp
//
//  libbz2 inline wrapper for tar.bz2 model extraction
//  Included via bridging header - no .c file needed
//  Ported from VoiceNote project
//

#ifndef Bzip2Helper_h
#define Bzip2Helper_h

#include <bzlib.h>
#include <stdio.h>
#include <stdlib.h>

#define BZIP2_HELPER_BUF_SIZE (256 * 1024)  // 256KB chunks

/// Decompress a bzip2 file to an output file.
/// Returns 0 on success, or a bzlib error code on failure.
static inline int bzip2_decompress_file(const char *input_path, const char *output_path) {
    FILE *in = fopen(input_path, "rb");
    if (!in) return -1;

    FILE *out = fopen(output_path, "wb");
    if (!out) {
        fclose(in);
        return -2;
    }

    int bzError;
    BZFILE *bz = BZ2_bzReadOpen(&bzError, in, 0, 0, NULL, 0);
    if (bzError != BZ_OK) {
        fclose(in);
        fclose(out);
        return bzError;
    }

    char buf[BZIP2_HELPER_BUF_SIZE];
    while (bzError != BZ_STREAM_END) {
        int n = BZ2_bzRead(&bzError, bz, buf, BZIP2_HELPER_BUF_SIZE);
        if (bzError != BZ_OK && bzError != BZ_STREAM_END) {
            BZ2_bzReadClose(&bzError, bz);
            fclose(in);
            fclose(out);
            return bzError;
        }
        if (n > 0) {
            fwrite(buf, 1, n, out);
        }
    }

    BZ2_bzReadClose(&bzError, bz);
    fclose(in);
    fclose(out);
    return (bzError == BZ_STREAM_END) ? 0 : bzError;
}

#endif /* Bzip2Helper_h */
