# BRR Preview

A small macOS app for auditioning SNES BRR samples, and for converting WAV or other
audio into BRR. Add one or more folders, expand them in the sidebar, and click a
`.brr` file to play it back tuned to its note. The detail pane shows a waveform, the
detected pitch, and a piano keyboard. Click an audio file to open the converter.

- **Add Folders…** (⌘O) adds one or more folders to the browser. Each folder appears
  as a tree, so a folder of instrument subfolders can be auditioned directly. Folders
  expand and collapse on click. Right-click a top-level folder and choose
  **Remove Folder** to drop it. The folder list is remembered between launches.
- **Pitch**: BRR files don't store a pitch, so the app estimates the sample's
  fundamental with autocorrelation and transposes it so the sample's note sounds.
  The note comes from the filename's trailing note name (e.g. `Eighty Pad C5` → C5),
  or C4 if the name has none. Samples with no clear pitch (drums, noise) play at the
  native rate with that note as the reference.
- **Piano keys**: while the app is focused, the keyboard plays notes. Q through P
  play the white keys, and 2 3 5 6 7 0 9 play the black keys. The octave starts at
  the octave of the current note. Mouse clicks on the on-screen keys work too.
- **Keyboard shortcuts**
  - ←/→ move the octave down or up.
  - ↑/↓ select the previous or next sample, wrapping around the list. Selecting a
    sample plays it.
  - Space plays or stops the selected sample.
  - Tab toggles Loop.
- **Keyboard on-screen**: the − and + buttons move the octave the same way as ←/→.
  The range is limited to two octaves from the detected pitch, which is the
  playback speed range of the audio engine.
- **Loop** is off by default. When it's on, a note loops for as long as its key is
  held, and releasing the key stops it. Holding a key on the on-screen keyboard
  works the same way. The loop repeats from the file's loop point, or the whole
  sample if the file has none. Some pad packs store a 2-byte little-endian loop
  offset (in bytes, relative to the start of the BRR data) at the front of the file.
  When the file size is 2 mod 9, the app reads that offset, skips it, and loops from it.
  Space and clicking a sample play it once.
- Closing the window quits the app.

Decoding stops after the first block with the END bit set, matching hardware.
Trailing bytes that don't form a full 9-byte block are ignored.

## Converting audio to BRR

Audio files (`.wav`, `.aif`, `.aiff`, `.caf`, `.m4a`, `.mp3`, `.ogg`) appear in the browser
with a note icon. Selecting one opens the waveform editor in the detail pane. Stereo
input is averaged to mono. Ogg Vorbis is decoded with the bundled
[stb_vorbis](https://github.com/nothings/stb) library (public domain, in
`Sources/CStbVorbis/`), so no extra tools are needed.

- **Selection**: drag on the waveform in *Select* mode. Crop keeps the selection,
  Cut removes it, and Reverse flips it; these need a selection. Fade In and Fade Out
  apply to the selection, or to the whole sample when nothing is selected.
- **Loop**: switch to *Set loop* and drag to place the loop start. The loop is a
  start point only and plays to the end of the sample. Clear Loop removes it.
- **Other tools**: Trim Silence, Normalize, and Undo (⌘Z). Each loop drag is one undo step.
- **Preview**: Space plays or stops the converted result. Tab toggles looping.
  Piano keys are not active in the editor. Arrow keys still move between samples.
- **Output rate**: the default is 32 kHz, the SPC700 native rate. Pick 22.05, 16,
  11.025, or 8 kHz for smaller files. The sample is resampled with an anti-alias filter.
- **Export BRR…** writes a `.brr` file. The file starts with a 2-byte little-endian
  loop offset, in bytes from the start of the BRR data. The value is `0xFFFF` when
  there is no loop. The stats line shows the pitch register to use for that rate.
  Loops that start beyond about 116k samples can't be stored and show a warning.

Limitation: the browser assumes 32 kHz for every `.brr` file, and the rate isn't stored
in the file. A file exported at a lower rate plays an octave or more low when it's
previewed in this app. The pitch register in the stats line is correct for the
hardware either way.

Limitation: the browser assumes 32 kHz for every `.brr` file, and the rate isn't stored
in the file. A file exported at a lower rate plays an octave or more low when it's
previewed in this app. The pitch register in the stats line is correct for the
hardware either way.

## SPC songs

Selecting a `.spc` file starts it playing. Playback uses the GME emulator's SPC700
core, bundled in `Sources/CSpcEmu/`.

- **Transport**: play/pause and stop buttons, with a volume slider, sit at the bottom
  of the sidebar while an SPC is open. Space plays or pauses. ↑/↓ move to the previous
  or next file. The piano keys are off in SPC mode.
- **Tracks**: each of the 8 voices shows a realtime spectrum, its sample number (SRCN),
  and its note. M and S mute or solo a track.
- **Extract…** writes the track's sample as a `.brr` file with its loop point. A `.txt`
  file with the same name holds the metadata: the SRCN, loop, detected pitch, and
  directory address.
- **Replace…** opens the original sample and a new one side by side. Drop an audio file
  onto the new-sample area, or choose one with the button. Pick the pitch mode, fine
  tune, and what to do if the new sample is longer than the original (refuse, truncate,
  or relocate). Apply rewrites the sample in the song's RAM. The change is heard the
  next time that track plays a note, because the emulator keeps the old sample until
  then. Relocate moves the sample to a free area of RAM. That path is heuristic and
  hasn't been tested in real songs.
- **Save SPC As…** writes the emulator's current state, including any replaced samples.

The emulator is GME (game-music-emu) by Shay Green, licensed under LGPL-2.1. See
`Sources/CSpcEmu/LICENSE-GME.txt`.

## Build and run

Requires macOS 13 or later and the Swift command-line tools.

```sh
make app
open build/BRRPreview.app
```

The build explicitly targets `x86_64` to match the other apps in `macOS/`. To
build and launch in one step, run `make run`. Run the decoder tests with
`make test`. The app icon is `Resources/AppIcon.icns`, which `make app` copies into the bundle.
