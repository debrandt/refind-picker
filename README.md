# refind-picker

A NixOS module for PCs with more than one operating system, such as two NixOS installs and Windows on separate drives.
At power-on it shows a [rEFInd](https://www.rodsbooks.com/refind/) screen with one icon per system:

- **Enter** on a NixOS icon boots that install's current generation.
- **Tab** or **F2** on it lists its newest generations.
- After a timeout, the default system boots.

Each NixOS install keeps [systemd-boot](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html) as
its bootloader, so `nixos-rebuild`, rollbacks and old-generation cleanup work as usual. On every rebuild, the module
reads the generations systemd-boot wrote and turns them into a rEFInd menu entry.

You don't need it if all your systems share one ESP. systemd-boot already lists Windows from the same ESP, and the
nixpkgs `boot.loader.refind` module covers a single NixOS install.

## How it works

One NixOS install is the **host**. rEFInd lives on its ESP, and on every rebuild the host:

- writes `EFI/refind/refind.conf` with its own entry, an `include` line for the guest's entry, and any static entries
  you add (such as Windows);
- makes the firmware boot rEFInd first.

Another NixOS install can be the **guest**. On every rebuild, it mounts the host's ESP, writes its own entry to the
file the host includes, and unmounts the ESP again.

rEFInd boots each NixOS kernel straight from the ESP where that install's systemd-boot copied it. It finds each ESP
by its partition GUID.

```text
firmware ──▶ rEFInd (host ESP)
              ├─ NixOS host   ─▶ kernel + initrd on the host ESP
              │                  (Tab: the 5 newest generations)
              ├─ NixOS guest  ─▶ kernel + initrd on the guest ESP
              │                  (Tab: the 5 newest generations)
              └─ Windows      ─▶ \EFI\Microsoft\Boot\bootmgfw.efi on its ESP
```

## Requirements

- UEFI with Secure Boot off. rEFInd, the kernels and systemd-boot are all unsigned.
- systemd-boot as the bootloader on every NixOS install that takes part.
- Fast Boot off in the firmware if the systems are on more than one drive. See
  [Entries on another drive boot the wrong thing or fail](#entries-on-another-drive-boot-the-wrong-thing-or-fail).
- At most one guest. rEFInd's `include` can't nest, and the host includes one guest file.

Tested with rEFInd 0.14.2 on an American Megatrends UEFI with two NVMe drives.

## Setup

### 1. Find the partition GUIDs

On any of the Linux installs, list the partitions:

```sh
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTUUID
```

You need the `PARTUUID` of:

- the **host's ESP**, the `vfat` partition mounted on `/boot` in the host install;
- the **guest's ESP**, if there is a guest;
- **Windows' ESP**, if you want Windows: the small `vfat` partition with `EFI/Microsoft/Boot/bootmgfw.efi` on it.

If two ESPs are hard to tell apart, mount each one read-only and look at its contents.

### 2. Add the flake input

Add the input to every install that takes part:

```nix
{
  inputs.refind-picker = {
    url = "github:debrandt/refind-picker";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, refind-picker, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      modules = [
        refind-picker.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

### 3. Configure the host

```nix
{ pkgs, ... }:
let
  hostEsp = "631D0A2F-74A7-4D26-9F4B-0638E52D0DF5";
  guestEsp = "0ADB19C8-E41D-4194-A781-A6483635FFF0";
  windowsEsp = "7D1F1188-9334-42D0-AF9E-28AB061DAFA4";
in
{
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;

    refind-picker = {
      enable = true;
      role = "host";
      pickerEspPartuuid = hostEsp;
      espPartuuid = hostEsp;
      title = "NixOS Work";
      icon = ''\EFI\refind\icons\work.png'';

      host = {
        # 128×128 PNGs, put in EFI/refind/icons/ on the host's ESP.
        icons = {
          work = "${pkgs.nixos-icons}/share/icons/hicolor/128x128/apps/nix-snowflake.png";
          private = "${pkgs.refind}/share/refind/icons/os_linux.png";
          windows = "${pkgs.refind}/share/refind/icons/os_win8.png";
        };

        guestConf = "private.conf";

        # Until the guest's first rebuild, its icon starts its own systemd-boot.
        guestFallback = ''
          menuentry "NixOS Private" {
              icon \EFI\refind\icons\private.png
              volume ${guestEsp}
              loader \EFI\systemd\systemd-bootx64.efi
          }
        '';

        extraEntries = ''
          menuentry "Windows" {
              icon \EFI\refind\icons\windows.png
              volume ${windowsEsp}
              loader \EFI\Microsoft\Boot\bootmgfw.efi
          }
        '';
      };
    };
  };
}
```

rEFInd ships OS icons in `${pkgs.refind}/share/refind/icons/` (`os_*.png`). To make a square 128×128 PNG from a
non-square SVG, use `rsvg-convert -h 128` followed by `magick … -background none -gravity center -extent 128x128`.

### 4. Configure the guest

```nix
{
  boot.loader = {
    systemd-boot.enable = true;

    refind-picker = {
      enable = true;
      role = "guest";
      pickerEspPartuuid = "631D0A2F-74A7-4D26-9F4B-0638E52D0DF5"; # the host's ESP
      espPartuuid = "0ADB19C8-E41D-4194-A781-A6483635FFF0"; # this install's ESP
      title = "NixOS Private";
      icon = ''\EFI\refind\icons\private.png''; # one of the host's icons
      guest.confName = "private.conf"; # the host's guestConf
    };
  };
}
```

### 5. Rebuild and try it out

To try rEFInd before trusting it with every boot, set `host.bootFirst = false` and `host.debug = true` on the host
first:

1. Rebuild the host with `sudo nixos-rebuild boot`.
2. Reboot and choose **rEFInd** at the bottom of the systemd-boot menu.
3. Check that every icon boots the right system. If something is off, read `EFI/refind/refind.log` on the host's ESP.

When everything works:

1. Remove both settings and rebuild the host again. rEFInd is now first in the firmware's boot order. Check with
   `efibootmgr`: the `rEFInd` entry's number should come first in `BootOrder`.
2. Rebuild the guest. Its icon now boots it directly, and Tab lists its generations.

## Options

All options are under `boot.loader.refind-picker`.

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Turn the picker on. |
| `role` | | `"host"` (rEFInd lives on this install's ESP) or `"guest"`. |
| `pickerEspPartuuid` | | Partition GUID of the host's ESP. |
| `espPartuuid` | | Partition GUID of this install's own ESP. |
| `title` | | This install's name in the picker. |
| `icon` | | Path of this install's icon on the host's ESP, e.g. `\EFI\refind\icons\nixos.png`. |
| `submenuEntries` | `5` | How many of the newest generations the submenu lists, 1–15. |
| `host.timeout` | `15` | Seconds before the host's entry boots. |
| `host.icons` | `{ }` | PNGs to put in `EFI/refind/icons/`, by file name without `.png`. |
| `host.guestConf` | `"guest.conf"` | File in `EFI/refind/` that the guest writes and the host includes. |
| `host.guestFallback` | `""` | rEFInd entries to put in `guestConf` until the guest writes its own. |
| `host.extraEntries` | `""` | rEFInd entries after the NixOS ones, such as Windows. |
| `host.bootFirst` | `true` | Make the firmware boot rEFInd first on every rebuild. When `false`, the boot order is left alone, and systemd-boot gets an entry that starts rEFInd. |
| `host.tools` | `[ "about" "shutdown" "reboot" "firmware" ]` | rEFInd's tools in the row under the boot icons, in order. `[ ]` hides the row. Their icons are put on the ESP. |
| `host.debug` | `false` | Show rEFInd's banner, hints and badges, and log to `EFI/refind/refind.log`. |
| `guest.confName` | `"guest.conf"` | File in the host's `EFI/refind/` to write this install's entry to. Must match the host's `guestConf`. |

The host's menu entry is the default selection. The firmware boot order is only changed when
`boot.loader.efi.canTouchEfiVariables` is on.

## Troubleshooting

Start with the debug log. Set `host.debug = true`, rebuild the host, boot rEFInd, then read the log from the host:

```sh
sudo cat /boot/EFI/refind/refind.log
```

The log lists every volume rEFInd found, every entry it added, and what it launched.

### A blank grey or white screen, maybe with rEFInd's banner, and nothing happens

rEFInd 0.14.2 hangs while building a submenu with more than 16 items, and it adds one item of its own ("Return to
Main Menu"). That is why `submenuEntries` stops at 15. If you write entries by hand in `host.extraEntries` or
`host.guestFallback`, keep each one to 15 `submenuentry` blocks or fewer.

If you get the blank screen with fewer entries, the log's last lines show where rEFInd stopped.

### Entries on another drive boot the wrong thing or fail

Symptoms:

- the guest's icon opens the host's systemd-boot menu;
- Windows stops with `Error: Not Found while loading bootmgfw.efi`;
- the log lists only the boot drive's volumes.

With Fast Boot on, many firmwares only set up the drive they boot from. rEFInd then can't find the other drive's ESP,
falls back to its own, and looks for the loader there.

Turn **Fast Boot** off in the firmware setup. It's usually on the Boot tab. On the tested firmware, rEFInd's own
rescan (`scan_delay`) didn't bring the second drive up. The UEFI Shell's `connect -r` does, but a firmware setting is
simpler than chaining the shell in front of rEFInd.

Fast Boot comes back if the firmware settings are ever reset, so check this first after a firmware update.

### The PC boots straight into Windows, or into systemd-boot

Windows updates sometimes move Windows Boot Manager to the front of the firmware boot order. The host's next rebuild
puts rEFInd first again. To fix it right away, set the boot order with `efibootmgr -o`, or rebuild the host with
`sudo nixos-rebuild boot`.

If there is no `rEFInd` entry at all, check that `boot.loader.efi.canTouchEfiVariables = true` on the host. Then
look at the output of `nixos-rebuild boot` for errors from the install script.

### The guest's entry doesn't change

The guest writes its entry during its own `nixos-rebuild`. If it can't, it prints one of these warnings and the rebuild
still succeeds:

- `refind-picker: /dev/disk/by-partuuid/… is missing`: `pickerEspPartuuid` is wrong, or that drive isn't connected.
- `refind-picker: … has no EFI/refind`: the host hasn't been rebuilt with the module yet.

Also check that the guest's `guest.confName` matches the host's `host.guestConf`.

### A generation is missing from the submenu

The generator skips entries rEFInd can't express, and prints a `skipping …` warning during the rebuild. That happens
when an entry has more than one `initrd` line, or when its kernel options contain a `"`. Older generations past
`submenuEntries` are still in systemd-boot's own menu (see below).

### Yellow-and-black striped squares instead of icons

That is rEFInd's placeholder for an icon it can't find in `EFI/refind/icons/`. The module installs the icons for your
own entries (`host.icons`) and for the tools in `host.tools`. If you name an icon in `host.extraEntries` or
`host.guestFallback`, add it to `host.icons`. If a tool still shows stripes, rEFInd added a tool that isn't in
`host.tools`. List it there.

### Tools appear twice, or tools you didn't ask for appear

rEFInd 0.14.2, as nixpkgs builds it, keeps its built-in tool list (About, Shut down, Reboot, Firmware setup and
others) in every slot a `showtools` line doesn't fill, so they appear after the tools you chose. A bare `showtools`
line hides nothing. The module fills the remaining slots with `csr_rotate`, a tool that only appears on a Mac with
`csr_values` set, so only `host.tools` shows. If you write your own `showtools` line, fill all 12 slots the same way.

### Getting back to systemd-boot

systemd-boot stays installed and keeps its firmware boot entry, usually called "Linux Boot Manager". To reach it, open
the firmware's one-time boot menu (often F8, F11 or F12 at power-on) and choose it. From there you can boot any
generation, including ones older than the submenu shows.

### Removing the picker

1. Disable the module on both installs and rebuild them.
2. On the host, delete `EFI/refind/` from the ESP.
3. Remove the firmware entry with `sudo efibootmgr -b <number> -B`, using the `rEFInd` entry's number from
   `efibootmgr`.

## Development

```sh
nix flake check   # generator and module checks
nix fmt           # format the Nix files
```

`generate_entry.py` is the generator. It only reads the ESP, so you can run it to see the entry it would write
(as root if the ESP isn't readable):

```sh
nix run .#refind-nixos-entry -- --esp /boot --volume <GUID> --title "NixOS" --icon '\EFI\refind\icons\nixos.png'
```

## Licence

MIT. See [LICENSE](LICENSE).
