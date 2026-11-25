# A rEFInd boot picker shared by NixOS installs on one PC: one icon per
# install (plus any static entries, such as Windows), each booting that
# install's default generation, with its newest generations in the icon's
# submenu (Tab or F2).
#
# systemd-boot stays each install's bootloader: it copies kernels to its own
# ESP, removes old ones and writes loader/entries/. After it does, on every
# rebuild, this module turns those entries into a rEFInd menu entry.
#
# One install is the "host": rEFInd lives on its ESP, its menu entry is
# written into refind.conf, and the firmware boots rEFInd first. Every other
# install is a "guest": it mounts the host's ESP and writes its own entry to a
# file refind.conf includes.
#
# rEFInd only sees drives the firmware has set up. With the firmware's fast
# boot on, that may be just the drive it boots from: if entries on another
# drive boot the wrong thing or fail, turn fast boot off in the firmware.
#
# See README.md for setup and troubleshooting.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    getExe
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.boot.loader.refind-picker;
  esp = config.boot.loader.efi.efiSysMountPoint;
  generator = import ./generator.nix { inherit pkgs; };

  # rEFInd finds volumes by GUID in upper case; /dev/disk/by-partuuid uses
  # lower case.
  byPartuuid = partuuid: "/dev/disk/by-partuuid/${lib.toLower partuuid}";

  generateEntry =
    espDir:
    lib.escapeShellArgs [
      (getExe generator)
      "--esp"
      espDir
      "--volume"
      (lib.toUpper cfg.espPartuuid)
      "--title"
      cfg.title
      "--icon"
      cfg.icon
      "--limit"
      (toString cfg.submenuEntries)
    ];

  refindConfHeader = pkgs.writeText "refind.conf-header" ''
    timeout ${toString cfg.host.timeout}
    scanfor manual
    ${
      if cfg.host.debug then
        ''
          # Debugging: rEFInd's own banner, hints and tools stay, and it logs
          # to EFI/refind/refind.log.
          log_level 2
        ''
      else
        ''
          # No tools row, and none of rEFInd's own banner, hints or badges:
          # just the boot icons.
          showtools
          hideui banner,hints,badges,arrows
        ''
    }
    default_selection "${cfg.title}"
  '';

  hostInstall = pkgs.writeShellApplication {
    name = "refind-picker-install";
    runtimeInputs = with pkgs; [
      coreutils
      efibootmgr
      gawk
      gnugrep
      gnused
      util-linux
    ];
    text = ''
      dir=${esp}/EFI/refind
      mkdir -p "$dir"

      {
        cat ${refindConfHeader}
        echo
        ${generateEntry esp}
        echo
        echo ${lib.escapeShellArg "include ${cfg.host.guestConf}"}
        echo
        cat ${pkgs.writeText "refind.conf-extra" cfg.host.extraEntries}
      } > "$dir/refind.conf.tmp"
      mv "$dir/refind.conf.tmp" "$dir/refind.conf"

      # Until the guest's first rebuild writes its own entry.
      if [ ! -e "$dir/${cfg.host.guestConf}" ]; then
        cp ${pkgs.writeText "guest-fallback.conf" cfg.host.guestFallback} "$dir/${cfg.host.guestConf}.tmp"
        mv "$dir/${cfg.host.guestConf}.tmp" "$dir/${cfg.host.guestConf}"
      fi

      ${lib.optionalString (cfg.host.bootFirst && config.boot.loader.efi.canTouchEfiVariables) ''
        # Make the firmware boot rEFInd first. Windows updates sometimes put
        # Windows Boot Manager first again; the next rebuild undoes that.
        rEFInd_entry() {
          efibootmgr | awk '/^Boot[0-9A-Fa-f]{4}\*? rEFInd(\t| |$)/ { print substr($1, 5, 4); exit }'
        }
        entry=$(rEFInd_entry)
        if [ -z "$entry" ]; then
          part=$(readlink -f ${byPartuuid cfg.pickerEspPartuuid})
          disk=/dev/$(lsblk -no PKNAME "$part")
          partnum=$(cat "/sys/class/block/$(basename "$part")/partition")
          efibootmgr -q -c -d "$disk" -p "$partnum" -l '\EFI\refind\refind_x64.efi' -L rEFInd
          entry=$(rEFInd_entry)
        fi
        order=$(efibootmgr | sed -n 's/^BootOrder: //p')
        if [ "''${order%%,*}" != "$entry" ]; then
          rest=$(tr , '\n' <<< "$order" | grep -vix "$entry" | paste -sd, || true)
          efibootmgr -q -o "$entry''${rest:+,$rest}"
        fi
      ''}
    '';
  };

  guestInstall = pkgs.writeShellApplication {
    name = "refind-picker-install";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = ''
      part=${byPartuuid cfg.pickerEspPartuuid}
      if [ ! -e "$part" ]; then
        echo "refind-picker: $part is missing, so the boot picker's ${cfg.title} entry is unchanged" >&2
        exit 0
      fi

      mnt=$(mktemp -d)
      trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt"' EXIT
      mount -t vfat "$part" "$mnt"

      dir=$mnt/EFI/refind
      if [ ! -d "$dir" ]; then
        echo "refind-picker: $part has no EFI/refind, so the boot picker's ${cfg.title} entry is unchanged" >&2
        exit 0
      fi

      ${generateEntry esp} > "$dir/${cfg.guest.confName}.tmp"
      mv "$dir/${cfg.guest.confName}.tmp" "$dir/${cfg.guest.confName}"
    '';
  };
in
{
  options.boot.loader.refind-picker = {
    enable = mkEnableOption "a rEFInd boot picker in front of systemd-boot";

    role = mkOption {
      type = types.enum [
        "host"
        "guest"
      ];
      description = "Whether rEFInd lives on this install's ESP (host) or on another's (guest).";
    };

    pickerEspPartuuid = mkOption {
      type = types.str;
      description = "Partition GUID of the ESP rEFInd lives on (the host's).";
    };

    espPartuuid = mkOption {
      type = types.str;
      description = "Partition GUID of this install's own ESP, where systemd-boot keeps its kernels.";
    };

    title = mkOption {
      type = types.str;
      description = "This install's name in the picker.";
    };

    icon = mkOption {
      type = types.str;
      example = ''\EFI\refind\icons\nixos.png'';
      description = "Path of this install's icon on the host's ESP.";
    };

    host = {
      timeout = mkOption {
        type = types.int;
        default = 15;
        description = "Seconds before the picker boots this install.";
      };

      icons = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = "PNG icons to put in EFI/refind/icons/ on the ESP, by file name without .png.";
      };

      guestConf = mkOption {
        type = types.str;
        default = "guest.conf";
        description = "File in EFI/refind/ the guest writes its entry to.";
      };

      guestFallback = mkOption {
        type = types.lines;
        default = "";
        description = "rEFInd entries to put in guestConf until the guest writes its own.";
      };

      extraEntries = mkOption {
        type = types.lines;
        default = "";
        description = "rEFInd entries after the NixOS ones, such as Windows.";
      };

      bootFirst = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether every rebuild makes the firmware boot rEFInd first. When
          false, the boot order is left alone and systemd-boot gets a menu
          entry that starts rEFInd, for trying it out.
        '';
      };

      debug = mkOption {
        type = types.bool;
        default = false;
        description = "Whether rEFInd shows its own banner, hints and tools, and logs to EFI/refind/refind.log.";
      };
    };

    submenuEntries = mkOption {
      # rEFInd 0.14.2 hangs on a submenu of more than 16 items, one of which
      # is its own "Return to Main Menu".
      type = types.ints.between 1 15;
      default = 5;
      description = "How many of the newest generations this install's submenu lists.";
    };

    guest.confName = mkOption {
      type = types.str;
      default = "guest.conf";
      description = "File in the host's EFI/refind/ to write this install's entry to; the host's guestConf.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.loader.systemd-boot.enable;
        message = "boot.loader.refind-picker builds its entries from systemd-boot's, so it needs systemd-boot.";
      }
    ];

    boot.loader.systemd-boot = {
      extraFiles = mkIf (cfg.role == "host") (
        {
          "efi/refind/refind_x64.efi" = "${pkgs.refind}/share/refind/refind_x64.efi";
        }
        // lib.mapAttrs' (name: icon: lib.nameValuePair "efi/refind/icons/${name}.png" icon) cfg.host.icons
      );

      extraEntries = mkIf (cfg.role == "host" && !cfg.host.bootFirst) {
        "refind-picker.conf" = ''
          title rEFInd
          efi /efi/refind/refind_x64.efi
          sort-key z_refind
        '';
      };

      extraInstallCommands = getExe (if cfg.role == "host" then hostInstall else guestInstall);
    };
  };
}
