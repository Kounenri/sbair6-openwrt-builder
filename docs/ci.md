# Building on GitHub Actions

The build needs x86_64 Linux, Docker and about 30 GB of free disk. When the computer that holds the unit cannot
carry that, the kit's manual workflow ([.github/workflows/build.yml](../.github/workflows/build.yml)) runs the same
`build.sh` steps on GitHub's temporary x86_64 runner. `device.sh` still runs on the computer that reaches the unit;
only the build moves ([stage 1](1-try.md)).

## One-time setup

The Wi-Fi firmware and the modem userspace may not be redistributed, so the kit does not carry them, and the
repository does not hold them in the clear either: they are committed as one encrypted file, `local.tar.age`, and
the age identity is a repository secret.

1. On the computer that has `local/firmware/` (after `./build.sh pull-fw`), create a key pair:

       sudo apt install age            # or the distribution's package
       age-keygen -o age-key.txt       # prints "public key: age1..."

2. Encrypt `local/` and commit the result:

       scripts/encrypt-inputs.sh age1...      # writes local.tar.age
       git add local.tar.age
       git commit -m 'ci: encrypted local inputs'
       git push

   `local/` itself stays out of git; `local.tar.age` is the only file of it that is committed.

3. Put the identity into the repository's secret: **Settings → Secrets and variables → Actions → New repository
   secret**, name `AGE_PRIVATE_KEY`, value the whole `age-key.txt` (the `AGE-SECRET-KEY-1...` line). Keep
   `age-key.txt` off the repository, and out of any backup of it that is shared.

Re-run step 2 whenever `local/` changes (another firmware version, `local/files/`, `local/diffconfig`, the modem
userspace): the workflow decrypts what was committed.

## Running it

**Actions → build-air6 → Run workflow.** The inputs are the `start` options:

| Input | Meaning |
| --- | --- |
| `trial` (default on) | `--trial`: the image returns to the other slot about 10 minutes after start-up unless kept |
| `all_kmods` | `--all-kmods`: build every kernel module (`config/all-kmods.exclude` excepted) |
| `modem` | `AIR6_MODEM`: empty for none, `1` for the only version under `local/modem/`, or the version name |

The run makes room on the runner's disk, decrypts `local.tar.age`, builds the Docker image, fetches the OpenWrt
fork at the commit in [fork.lock](../fork.lock), starts the build, waits for `status` to say done or failed,
collects `out/$STAMP/` and checks the boot image policy. It takes about 1–2 hours on the runner's four cores.

## Taking the image

Download the artifact **air6-`$STAMP`** from the run's summary, then on the computer with the unit:

    unzip air6-$STAMP.zip -d out/
    ./device.sh install root@DEVICE $STAMP

Keep the directory name: it is the build ID that `install`, `upgrade` and `CHECK.txt` refer to.

## What stays where

- **The runner** is a fresh machine for each run and is deleted when the run ends. `local.tar.age` is decrypted only
  there; the decrypted files are not cached.
- **GitHub** keeps the run's log and the artifact for three days (`retention-days: 3` in the workflow). Delete the
  artifact after downloading it. No build cache is used, so nothing of one build reaches the next.
- **The repository** keeps `local.tar.age`. Without `age-key.txt` it cannot be read; the age public key alone does
  not decrypt it.
- **The image** is the same file a local build produces and it carries the Wi-Fi firmware, so treat the artifact
  as private, like `local/`.

## Limits and failures

- The runner has 4 vCPU, 16 GB RAM and about 14 GB of free disk; the workflow deletes preinstalled toolchains to
  free about 20 GB more. If a build still runs out of disk, remove packages from the configuration or use a larger
  runner.
- A public repository's Actions minutes are free; a private one uses its monthly allowance. A run that reaches the
  6-hour job timeout is cancelled (`timeout-minutes: 360`).
- `local.tar.age is missing` or `secret AGE_PRIVATE_KEY is not set`: the one-time setup above.
- `local/firmware/mt7996 is empty`: run `./build.sh pull-fw [USER@]DEVICE`, then `scripts/encrypt-inputs.sh` again and
  commit the new `local.tar.age`.
- A failed build uploads **air6-`$STAMP`-logs** (`out/logs-$STAMP/`); the same log files as a local build.
