#ifndef CSTBVORBIS_H
#define CSTBVORBIS_H

#include <stdlib.h>

/// Decodes an Ogg Vorbis file to interleaved 16-bit PCM from `stb_vorbis.c`.
/// Returns the number of samples per channel, or -1 on failure. The caller frees `*output`.
int stb_vorbis_decode_filename(const char *filename, int *channels, int *sample_rate, short **output);

#endif
