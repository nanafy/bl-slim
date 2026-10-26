# bl4-slim

Shrinks a Borderlands 4 install on Windows. Mine went from 189 GB to 57 GB, and the game still runs.

## What it removes

1. **Voice languages you don't use.** Steam installs the voices for all 8 languages, about 8 to 9.5 GB each, and has no option to skip them. The script keeps the one you pick and deletes the rest.
2. **Old patch data.** Every update adds new pak files and leaves the older ones in place, so the install keeps old copies of data that a newer patch replaced. The game only reads the newest copy. The old copies share files with data the game still needs, so you can't just delete files. The script blanks only the dead byte ranges (NTFS sparse files). File sizes stay the same and the space comes back.

It works out what's old by reading the game's own file indexes, so it doesn't depend on file numbers and keeps working after updates. If an update changes the file format, it stops with an error instead of guessing. Before and after blanking each file, it hashes every byte the game still reads, and it stops if a single one changed.

## How to use

1. Close the game and let Steam finish any update.
2. Download the zip, unzip it anywhere, and double-click `bl4-slim.cmd`.
3. Pick the voice language to keep. Use the one your game's voice setting is on. Enter keeps English.
4. It shows what it will remove. Type `y` to go ahead.

Run it again after every game update, because updates bring the old copies back.

It finds the game through Steam on its own. If it can't (Epic, or an unusual setup), it asks you to paste the game folder.

### Options

From a command prompt in the unzipped folder:

| Command | What it does |
|---|---|
| `bl4-slim.cmd -Scan` | shows what it would remove and doesn't touch the game files |
| `bl4-slim.cmd -Keep German` | keeps German without asking |
| `bl4-slim.cmd -GameDir "D:\Games\Borderlands 4"` | uses that game folder |
| `bl4-slim.cmd -Yes` | skips the "Go ahead?" question |

## Undo

In Steam, open the game's Properties and run "Verify integrity of game files". Steam downloads everything back.

## Good to know

- After the old-patch step, File Explorer's "Size" stays the same. Check "Size on disk" in Properties, that's the real number.
- The old-patch step needs an NTFS drive, the normal Windows format. On an exFAT or FAT32 drive it only does the language step.
- If it says Windows blocked access, right-click `bl4-slim.cmd` and pick "Run as administrator".
- The first run reads every file it changes twice to check it, so it takes longer on a hard drive.
- Nothing gets installed. `bl4-slim.cmd` starts `bl4-slim.ps1` in the PowerShell that comes with Windows. Both are plain text, so you can read them first.

## Tested

- Windows 10, Steam version, NTFS drives with 4 KB clusters, Windows PowerShell 5.1.
- My install went from 189 GB to 57 GB, and the game started to the main menu afterwards.
- On a test copy of real game files, every file the script changed still matched the original byte for byte, and a second run found nothing left to do.

Not tested yet: the Epic version, Steam achievements, how big the next update download is, drives with other cluster sizes, PowerShell 7.

Use at your own risk. If you're worried, back up `OakGame\Content\Paks` first.

## License

MIT
