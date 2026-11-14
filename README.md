# BRR Preview

A small macOS app for auditioning SNES BRR samples, and for converting WAV or other
audio into BRR. Add one or more folders, expand them in the sidebar, and click a
`.brr` file to play it back tuned to its note. The detail pane shows a waveform, the
detected pitch, and a piano keyboard. Click an audio file to open the converter.

Download the [latest universal macOS release](https://github.com/PsychoSync/BRRPreview/releases/latest).
The same app runs on Intel and Apple Silicon Macs with macOS 13 or later.
All audio decoders and the SPC emulator are bundled; no extra dependencies are needed.

- **Add Files…** (⇧⌘O) adds individual BRR, audio, or SPC files to the browser.
  **Add Folders…** (⌘O) adds one or more folders. Each folder appears as a tree, so a
  folder of instrument subfolders can be auditioned directly. Folders expand and
  collapse on click. Hover a top-level folder and click its remove icon to close it
  without deleting files. Right-click a top-level file or folder and choose **Remove File**
  or **Remove Folder** to drop it. The list is remembered between launches.
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
  of the sidebar while an SPC is open. On macOS 26 and later they use the system glass
  effect; on earlier systems they fall back to a translucent material. Space plays or pauses. ↑/↓ move to the previous
  or next file. The piano keys are off in SPC mode.
  Clicking a BRR or audio file leaves the song playing while you audition the sample.
  **Go to spc** in the transport or **← Go back to playback** above the sample returns
  to the same song without restarting it. On the sample page, keyboard shortcuts
  control the sample; the transport continues to control the song.
- **Voices / Tracks**: the picker at the top of the SPC view switches between two modes.
  *Voices* lists the SNES's 8 hardware voices, each with a realtime spectrum, its sample
  number (SRCN), and its note. M and S mute or solo a voice.
  *Tracks* lists one track per sample (SRCN), numbered in the order each sample is first
  heard. A track stays in the list after its sample stops, and it records every voice
  that has played it. Its 60-second timeline shows which voice played it at each moment.
  M and S mute or solo a track. Mute and solo follow the sound, so a muted sample is
  silenced on whichever voice it plays next. The mute can leak for up to about 33 ms
  when a muted sample starts.
- **Instrument name**: enter a custom name above a track's Extract and Replace buttons.
  Both extraction actions use it as the sample filename. Names stay with their SRCN
  while this song is open, including after Stop/restart; they are not embedded in SPC files.
- **Extract…** writes a voice's or track's sample as a `.brr` file with its loop point.
  A `.txt` file with the same name holds the metadata: the SRCN, loop, detected pitch,
  directory address, and the voice or track number. Voice numbers are 1-based.
- **Extract All…** scans from the start in a separate emulator without interrupting playback.
  The editable scan length defaults to 12 minutes (maximum 60). Only BRR samples that
  produce audible voice output in that interval are exported, including instruments
  introduced later; unused directory entries, silent voices and noise-only voices are excluded.
  Samples are captured when heard, preserving their BRR data and loop even if RAM changes later.
  Identical sounds with identical loops are exported once. Custom names are preferred;
  otherwise files are named `SRCN_XX_XXXX.brr`, with a matching `.txt` for each.
  Unsafe filename characters are replaced, and numeric suffixes prevent overwriting
  existing files or collisions between names. Increase the scan length for longer songs.
- **Replace…** shows selectable Original and New sample sections, with one shared piano
  between them. The selected section receives the piano and keyboard notes (Q–P,
  number keys, and left/right octave arrows). Each has its own Loop checkbox, Hold note
  checkbox, and preview volume knob. Loop starts enabled when the sample has a loop.
  Hold note latches a note so you can adjust it hands-free; held notes can continue while
  you select the other section. Monitor volumes do not change the exported sample.
  Click a browser sample to preview once without choosing it, or press and hold to
  sustain it with its loop until release. Drop it onto the new-sample area, or choose
  one with the button, to select it. Audio and BRR files are accepted.
  Editing tools are arranged horizontally. Pitch mode, coarse pitch (-24 to +24 semitones),
  and fine tune (-100 to +100 cents) affect the new preview immediately and are included
  when applied. Choose what to do if the new sample is longer than the original (refuse, truncate,
  or relocate). Apply rewrites the sample in the song's RAM. The change is heard the
  next time that track plays a note, because the emulator keeps the old sample until
  then. Relocate moves the sample to a free area of RAM. That path is heuristic and
  hasn't been tested in real songs.
- **Save SPC As…** opens a sheet with the song's extended (xid6) tags: song, game,
  artist, dumper, comments, soundtrack title, publisher, and date dumped (yyyymmdd).
  Changed fields are written; untouched tags keep their original bytes. Clearing a
  field removes it. After you confirm, a save panel writes the emulator's current state,
  including any replaced samples, with the tags. Files without tags can gain them.

The emulator is GME (game-music-emu) by Shay Green, licensed under LGPL-2.1. See
`Sources/CSpcEmu/LICENSE-GME.txt`.

## Build and run

Requires macOS 13 or later and the Swift command-line tools.

```sh
make app
open build/BRRPreview.app
```

The build targets both `x86_64` (Intel) and `arm64` (Apple Silicon). To
build and launch in one step, run `make run`. Create the universal release ZIP with
`make release`. Run the tests with
`make test`. The app icon is `Resources/AppIcon.icns`, which `make app` copies into the bundle. The faint
background behind the file browser is `Resources/Background.png`, also copied by `make app`. It
only appears in the built `.app`, not under `swift run`.
