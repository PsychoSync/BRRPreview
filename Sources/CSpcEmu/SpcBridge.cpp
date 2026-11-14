#include "CSpcEmu.h"

#include "Data_Reader.h"
#include "Spc_Emu.h"

#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

static_assert(SPC_TAP_SIZE == Spc_Dsp::tap_size, "tap size mismatch");
static_assert(SPC_FILE_SIZE == Snes_Spc::spc_file_size, "SPC file size mismatch");

struct SpcEmu {
    struct Captured {
        SpcCapturedSample info;
        std::vector<unsigned char> data;
    };
    std::vector<unsigned char> bytes;
    Spc_Emu emu;
    std::mutex lock;
    std::vector<Captured> captured;
};

namespace {

void set_error(char *err, int err_size, const char *message) {
    if (err && err_size > 0) {
        std::snprintf(err, static_cast<size_t>(err_size), "%s", message ? message : "Unknown error");
    }
}

void copy_text(char *dst, size_t size, const char *src) {
    std::snprintf(dst, size, "%s", src ? src : "");
}

void capture_sample(void *context, int source, int directory, int start, int loop) {
    SpcEmu *handle = static_cast<SpcEmu *>(context);
    const unsigned char *ram = handle->emu.snes_spc().smp_ram();
    int end = start;
    while (end + 9 <= 0x10000) {
        bool last = (ram[end] & 1) != 0;
        end += 9;
        if (!last) continue;
        std::vector<unsigned char> bytes(ram + start, ram + end);
        for (const auto &sample : handle->captured) {
            if (sample.info.source_index == source &&
                sample.info.loop_address - sample.info.start == loop - start &&
                sample.data == bytes) return;
        }
        handle->captured.push_back({{source, directory, start, loop, (end - start) / 9}, std::move(bytes)});
        return;
    }
}

}  // namespace

extern "C" {

SpcEmu *spc_open(const unsigned char *data, long size, int sample_rate, char *err, int err_size) {
    if (!data || size < Snes_Spc::spc_min_file_size) {
        set_error(err, err_size, "Not a valid SPC file");
        return nullptr;
    }

    SpcEmu *handle = new SpcEmu;
    handle->bytes.assign(data, data + size);

    blargg_err_t status = handle->emu.set_sample_rate(sample_rate);
    if (!status) {
        Mem_File_Reader reader(handle->bytes.data(), size);
        status = handle->emu.load(reader);
    }
    if (status) {
        set_error(err, err_size, status);
        delete handle;
        return nullptr;
    }

    handle->emu.set_autoload_playback_limit(false);
    handle->emu.ignore_silence(true);
    return handle;
}

void spc_close(SpcEmu *emu) {
    delete emu;
}

int spc_start(SpcEmu *emu) {
    std::lock_guard<std::mutex> guard(emu->lock);
    return emu->emu.start_track(0) ? -1 : 0;
}

int spc_play(SpcEmu *emu, int frames, short *stereo_out) {
    std::lock_guard<std::mutex> guard(emu->lock);
    return emu->emu.play(static_cast<long>(frames) * 2, stereo_out) ? -1 : 0;
}

void spc_set_mute_mask(SpcEmu *emu, int mask) {
    std::lock_guard<std::mutex> guard(emu->lock);
    emu->emu.mute_voices(mask);
}

int spc_track_info(SpcEmu *emu, SpcTrackInfo *info) {
    track_info_t track{};
    if (emu->emu.track_info(&track)) {
        return -1;
    }
    copy_text(info->song, sizeof info->song, track.song);
    copy_text(info->game, sizeof info->game, track.game);
    copy_text(info->author, sizeof info->author, track.author);
    copy_text(info->dumper, sizeof info->dumper, track.dumper);
    copy_text(info->comment, sizeof info->comment, track.comment);
    info->length_ms = track.length;
    return 0;
}

int spc_copy_voice_tap(SpcEmu *emu, int voice, short *out, int count) {
    if (voice < 0 || voice >= SPC_VOICE_COUNT || count <= 0 || count > SPC_TAP_SIZE) {
        return -1;
    }
    std::lock_guard<std::mutex> guard(emu->lock);
    emu->emu.snes_spc().spc_dsp().copy_voice_tap(voice, out, count);
    return 0;
}

void spc_begin_sample_capture(SpcEmu *emu) {
    std::lock_guard<std::mutex> guard(emu->lock);
    emu->captured.clear();
    emu->emu.snes_spc().spc_dsp().set_sample_observer(capture_sample, emu);
}

int spc_captured_sample_count(SpcEmu *emu) {
    std::lock_guard<std::mutex> guard(emu->lock);
    return static_cast<int>(emu->captured.size());
}

int spc_copy_captured_sample(SpcEmu *emu, int index, SpcCapturedSample *info,
                              unsigned char *out, int capacity) {
    std::lock_guard<std::mutex> guard(emu->lock);
    if (index < 0 || index >= static_cast<int>(emu->captured.size())) return -1;
    const auto &sample = emu->captured[index];
    if (capacity < static_cast<int>(sample.data.size())) return -1;
    *info = sample.info;
    std::memcpy(out, sample.data.data(), sample.data.size());
    return static_cast<int>(sample.data.size());
}

int spc_read_dsp(SpcEmu *emu, int reg) {
    std::lock_guard<std::mutex> guard(emu->lock);
    return emu->emu.snes_spc().spc_dsp().read(reg & 0x7F);
}

int spc_read_ram(SpcEmu *emu, int addr, unsigned char *out, int len) {
    if (addr < 0 || len < 0 || addr + len > 0x10000) {
        return -1;
    }
    std::lock_guard<std::mutex> guard(emu->lock);
    std::memcpy(out, emu->emu.snes_spc().smp_ram() + addr, static_cast<size_t>(len));
    return 0;
}

int spc_write_ram(SpcEmu *emu, int addr, const unsigned char *data, int len) {
    if (addr < 0 || len < 0 || addr + len > 0x10000) {
        return -1;
    }
    std::lock_guard<std::mutex> guard(emu->lock);
    std::memcpy(emu->emu.snes_spc().smp_ram() + addr, data, static_cast<size_t>(len));
    return 0;
}

long spc_save(SpcEmu *emu, unsigned char *out, long capacity) {
    if (capacity < SPC_FILE_SIZE) {
        return -1;
    }

    std::lock_guard<std::mutex> guard(emu->lock);
    Snes_Spc &apu = emu->emu.snes_spc();

    std::memcpy(out, emu->bytes.data(), Spc_Emu::header_size);

    const Snes_Spc::regs_t &regs = apu.smp_regs();
    out[0x25] = static_cast<unsigned char>(regs.pc & 0xFF);
    out[0x26] = static_cast<unsigned char>(regs.pc >> 8);
    out[0x27] = regs.a;
    out[0x28] = regs.x;
    out[0x29] = regs.y;
    out[0x2A] = regs.psw;
    out[0x2B] = regs.sp;

    const unsigned char *ram = apu.smp_ram();
    std::memcpy(out + 0x100, ram, 0x10000);

    for (int i = 0; i < 128; i++) {
        out[0x10100 + i] = static_cast<unsigned char>(apu.spc_dsp().read(i));
    }

    std::memset(out + 0x10180, 0, 0x40);
    std::memcpy(out + 0x101C0, ram + 0xFFC0, 0x40);
    return SPC_FILE_SIZE;
}

}  // extern "C"
