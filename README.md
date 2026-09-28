# Working suspend and hibernation on a MacBook Pro 2017 running Ubuntu 24.04

On a MacBookPro14,1 (13", 2017, no Touch Bar) with Ubuntu 24.04, closing the lid
ended one of two ways: the machine woke up with a dead disk and had to be held
down on the power button, or it never suspended at all and quietly ran on with
the lid shut. Left overnight on battery it lost **78 %**.

There was no single cause. Five independent faults overlapped and masked each
other. With all five fixed, a night off the charger now costs about **10 %**.

| | |
|---|---|
| Measured suspend drain | ~6.3 %/h |
| Measured hibernation drain | ~0.5 %/h |
| Night (8–9 h, lid closed, battery) | ~10 %, was 78 % |
| Resume from suspend | immediate |
| Resume from hibernation | ~30 s, session restored |

## Tested on

- **MacBookPro14,1**, Apple SSD AP0512J, Broadcom BCM4350 Wi-Fi
- **Ubuntu 24.04.5**, kernel **6.8.0-139-generic**, GNOME on Wayland

One machine, one kernel, one release. Other MacBook models have different PCIe
controllers and a different Wi-Fi chip; `install.sh` refuses to run on them
unless you pass `--force`.

## The five faults

| | Symptom | Cause | Fix |
|---|---|---|---|
| **A** | Disk gone after resume; filesystem remounts read-only | PCIe ports enter D3cold and never come back | `pcie_port_pm=off` |
| **B** | Machine does not suspend at all; wakes every ~30 s | BCM4350 firmware stops answering the D3 request after hours of uptime | unload the Wi-Fi driver before every sleep |
| **C** | Suspend costs 6–8 %/h forever | the platform never reaches S0ix, so s2idle saves little | hibernate after an hour of suspend |
| **D** | Machine powers itself on minutes after hibernating | Apple firmware lets the lid sensor and the Wi-Fi card wake it from S4 | revoke both, at boot **and** after every driver reload |
| **E** | Wi-Fi interface missing after a warm reboot | the chip is not power-cycled and reads back `0xffffffff` | re-enumerate the PCI device 25 s after boot |

Only **one** kernel parameter turned out to be necessary. `pcie_aspm=off`,
`nvme_core.default_ps_max_latency_us=0`, `intel_iommu=off` and
`acpi.ec_no_wakeup=Y` were all bisected away — see the Polish write-up for what
each of them did and did not do.

## Install

```sh
git clone https://github.com/<you>/ubuntu-suspend-macbook-pro-2017.git
cd ubuntu-suspend-macbook-pro-2017
sudo ./install.sh --dry-run    # see exactly what would change
sudo ./install.sh
sudo reboot
```

Then verify — and do not skip the second half:

```sh
./verify.sh                                        # files match the repository
sudo rtcwake -m no -s 60; sudo systemctl suspend -i # one real suspend
sudo tail -2 /var/log/macbook-sleep-wifi.log        # two fresh entries = hooks ran
```

The install is idempotent; running it twice changes nothing the second time.
`sudo ./uninstall.sh` removes everything and restores the stock behaviour.

## What you get

| Situation | Behaviour |
|---|---|
| Lid closed, on battery | suspend now, hibernate after 60 min |
| Lid closed, on AC | plain suspend, no hibernation |
| Left alone, lid open | screen blanks and locks; **the machine keeps running** |
| "Suspend" in the GNOME menu | suspend only — that path knows nothing about hibernation |
| Waking from hibernation | power button, not the lid (deliberate: fault D) |

Idling deliberately does not sleep this machine. An idle-triggered suspend hung
it once while four lid-triggered suspends the same day were fine, so sleeping is
left to one explicit gesture. The cost is that a laptop left open on battery
will run itself flat.

## A trap worth knowing

systemd sleep hooks live in **`/usr/lib/systemd/system-sleep/` only**. Unlike
almost everything else in systemd, there is no `/etc` override directory. A hook
placed in `/etc/systemd/system-sleep/` is never executed — no error, no log
entry, no sign at all. Check what your systemd actually looks at:

```sh
strings /usr/lib/systemd/systemd-sleep | grep system-sleep
```

This cost us a failed hibernation: the hook silently stopped running, four
suspends looked fine, and the fifth wrote a hibernation image with a hung
Wi-Fi chip inside it that would not load back.

## Known limitations

- **Suspend occasionally fails to come back.** Measured over a week of ordinary
  use: **one hang in 26 logged sleeps**, on 22 September, with none since. The
  machine enters suspend cleanly and never returns, and since nothing is written
  to disk while it sleeps, there is no trace in any log. Unresolved.
  You can count your own rate: the battery hook writes a `pre` line before every
  sleep and a `post` line after it, so a hang is a `pre` with no matching `post`
  in `/var/log/macbook-sleep-battery.log`.
  If it happens to you, press Caps Lock first: if the LED toggles, the kernel is
  alive and it is a graphics restore problem; if not, the machine is truly gone.
  Then boot without `quiet splash`, with `no_console_suspend=1 initcall_debug`,
  and photograph the screen.
- **Root cause of fault B is unfixed.** The Broadcom calibration files
  (`brcmfmac4350c2-pcie.txt`, `clm_blob`, `txcap_blob`) are missing from the
  system and are the prime suspect for the firmware hangs. We work around it.
- **Kernel updates are held on the reference machine**, for an unrelated reason:
  audio depends on the `snd_hda_macbookpro` DKMS module built for this exact
  kernel. Nothing here requires that, but it does mean this configuration has
  only ever run on 6.8.0-139.

## After system updates

An apt hook writes the result of `sleep-check` to
`/var/log/macbook-sleep-check.log` after every package operation, so a silent
breakage shows up there rather than as a flat battery three weeks later. What it
cannot check is whether the hooks still execute — that needs the one-minute
suspend test above, worth repeating after a systemd upgrade.

## Installed tools

| Command | Purpose |
|---|---|
| `sudo sleep-check` | 18 checks over the whole configuration |
| `sleep-power` | measured battery drain per sleep, from the logs |
| `sudo sleep-probe` | diagnostic 60 s suspend with interrupt and ACPI deltas |

## Files

`lib/files.sh` holds the exact contents of all sixteen installed files and is the
single source of truth: `install.sh` writes them, `verify.sh` compares against
them, `uninstall.sh` removes them. Two further files are generated per machine
because they carry the root filesystem UUID and the swap file's physical offset.

## The long version

[The full write-up (in Polish)](https://misiek-moro.github.io/ubuntu-suspend-macbook-pro-2017/diagnosis-pl.html) is the full write-up **in
Polish**: how each fault was found, the measurements, the dead ends, the
rollback procedure, and what is still unknown. Open it in a browser.

## How this was made

Ten days of paired work between the repository owner and Claude, Anthropic's
assistant: the assistant wrote the commands and the prose, the owner ran
everything on the machine and made the calls about what to keep. Every number
above is a measurement from that one laptop — none of them are estimates.

How it got there matters, because it tells you how far to trust it:

- Most of the assistant's early hypotheses were wrong. Deep sleep (S3), Wi-Fi
  DMA, NVMe power states, EC wakeup storms and a udev rule were all proposed
  confidently and all bisected away against data from the machine.
- The assistant introduced two defects of its own. One put the sleep hooks in
  `/etc/systemd/system-sleep/`, where systemd never looks, which cost a failed
  hibernation days later; the other wrote files without their final newline.
  Both were caught by comparing the documentation against the running system,
  file by file — which is why `verify.sh` exists.
- Everything here is verified on one machine, one kernel, one Ubuntu release.

Someone will likely do this better. Corrections, issues and pull requests are
welcome — particularly from anyone with the same laptop whose machine behaves
differently, and from anyone who knows what actually blocks S0ix here or where
the missing Broadcom calibration files come from.

## Prior art and credits

None of the individual fixes here are new. `pcie_port_pm=off`, unloading a
misbehaving Wi-Fi driver around sleep, hibernating to a swap file with
`resume=` and `resume_offset=`, and revoking wake sources through
`/proc/acpi/wakeup` are all long-standing community knowledge — scattered
across the kernel's own documentation, the Arch Wiki, Ask Ubuntu answers, bug
reports and mailing-list threads written by people who worked this out years
before us. The kernel documentation on
[system sleep states](https://www.kernel.org/doc/html/latest/admin-guide/pm/sleep-states.html)
is where most of it starts.

Thanks are owed to those people, and to the maintainers of the `brcmfmac`
driver and of the Linux power-management subsystem — their work is what makes
any of this possible on a laptop whose manufacturer never intended it to run
Linux at all.

What this repository adds is narrower: the fixes are **measured** rather than
asserted, the kernel command line is **bisected** from seven parameters down to
the single one that actually matters, the **dead ends are written down**, and
the whole configuration can be **verified with one command**. If that saves
someone the two evenings it cost here, it has done its job.

## License and attribution

- **Code** — `install.sh`, `uninstall.sh`, `verify.sh`, `lib/files.sh` and the
  scripts and configuration they install:
  [MIT-0](https://spdx.org/licenses/MIT-0.html) (MIT No Attribution), see
  [LICENSE](LICENSE).
- **Writing** — this README and the write-up in `docs/`:
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), see
  [LICENSE-DOCS](LICENSE-DOCS).

In plain words:

- **Take the code and do whatever you like with it.** Fork it, fix it, improve
  it, ship your own better version, commercially or not. You do not owe anyone
  a credit line. If someone makes this work properly, that is a good outcome.
- **The write-up is the one thing that asks something in return.** If you
  reproduce or describe this work itself — the faults and how they were found,
  the measurements, the method — in an article, a blog post, a video or a wiki
  page, credit **Michał Moroz** and link back here. That is all.
- **Nothing here carries any warranty.** This configuration changes how a
  machine sleeps and writes a hibernation image to disk; read the output of
  `sudo ./install.sh --dry-run` before letting it touch anything.
