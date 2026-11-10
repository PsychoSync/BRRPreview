#ifndef CSPCEMU_H
#define CSPCEMU_H

/* C interface over the SNES SPC700/DSP emulator (Game_Music_Emu, LGPL-2.1). */

#ifdef __cplusplus
extern "C" {
#endif

#define SPC_VOICE_COUNT 8
#define SPC_TAP_SIZE 2048
#define SPC_FILE_SIZE 0x10200

typedef struct SpcEmu SpcEmu;

typedef struct SpcTrackInfo {
    char song[256];
    char game[256];
    char author[256];
    char dumper[256];
    char comment[256];
    long length_ms;
} SpcTrackInfo;

/* Copies `size` bytes of an SPC file. Returns NULL and fills err on failure. */
SpcEmu *spc_open(const unsigned char *data, long size, int sample_rate, char *err, int err_size);
void spc_close(SpcEmu *emu);

/* Starts playback from the file's saved state. Returns 0 on success. */
int spc_start(SpcEmu *emu);

/* Renders `frames` stereo frames as interleaved 16-bit samples. Returns 0 on success. */
int spc_play(SpcEmu *emu, int frames, short *stereo_out);

/* Mutes voices whose bit is set in mask. Muted voices keep producing spectrum taps. */
void spc_set_mute_mask(SpcEmu *emu, int mask);

int spc_track_info(SpcEmu *emu, SpcTrackInfo *info);

/* Copies the most recent `count` pre-volume output values of a voice, oldest first. */
int spc_copy_voice_tap(SpcEmu *emu, int voice, short *out, int count);

int spc_read_dsp(SpcEmu *emu, int reg);

/* Returns 0 on success, -1 when the address range is outside the 64K SPC RAM. */
int spc_read_ram(SpcEmu *emu, int addr, unsigned char *out, int len);
int spc_write_ram(SpcEmu *emu, int addr, const unsigned char *data, int len);

/* Serializes the current CPU, RAM and DSP state as an SPC file. Returns SPC_FILE_SIZE, or -1 if capacity is too small. */
long spc_save(SpcEmu *emu, unsigned char *out, long capacity);

#ifdef __cplusplus
}
#endif

#endif
