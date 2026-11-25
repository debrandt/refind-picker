# What `nix flake check` runs.
{
  pkgs,
  nixpkgs,
  module,
  generator,
}:

let
  # A NixOS system with the module set up as `picker`, evaluated but not
  # built.
  evalWith =
    picker:
    (nixpkgs.lib.nixosSystem {
      modules = [
        module
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          boot.loader = {
            systemd-boot.enable = true;
            efi.canTouchEfiVariables = true;
            refind-picker = {
              enable = true;
              pickerEspPartuuid = "11111111-1111-1111-1111-111111111111";
            }
            // picker;
          };
        }
      ];
    }).config;

  host = evalWith {
    role = "host";
    espPartuuid = "11111111-1111-1111-1111-111111111111";
    title = "NixOS Main";
    icon = ''\EFI\refind\icons\main.png'';
    host = {
      icons.main = "${pkgs.nixos-icons}/share/icons/hicolor/128x128/apps/nix-snowflake.png";
      guestFallback = ''
        menuentry "NixOS Other" {
            volume 22222222-2222-2222-2222-222222222222
            loader \EFI\systemd\systemd-bootx64.efi
        }
      '';
    };
  };

  guest = evalWith {
    role = "guest";
    espPartuuid = "22222222-2222-2222-2222-222222222222";
    title = "NixOS Other";
    icon = ''\EFI\refind\icons\main.png'';
  };

  # Like `host`, but trying rEFInd out from systemd-boot, with rEFInd's own
  # UI and log.
  hostTrying = evalWith {
    role = "host";
    espPartuuid = "11111111-1111-1111-1111-111111111111";
    title = "NixOS Main";
    icon = ''\EFI\refind\icons\main.png'';
    host = {
      bootFirst = false;
      debug = true;
    };
  };

  # The script each role runs after systemd-boot installs, built (so
  # writeShellApplication runs shellcheck on it) and checked for `patterns`.
  scriptHas =
    name: config: patterns:
    pkgs.runCommand name { } ''
      script=${config.boot.loader.systemd-boot.extraInstallCommands}
      ${pkgs.lib.concatMapStrings (pattern: ''
        if ! grep -qF -- ${pkgs.lib.escapeShellArg pattern} "$script" $(grep -o '/nix/store/[^ ]*refind.conf-[a-z]*' "$script"); then
          echo "expected to find: "${pkgs.lib.escapeShellArg pattern}
          failed=1
        fi
      '') patterns}
      [ -z "''${failed:-}" ] && touch $out
    '';
in
{
  # The generator turns systemd-boot's entries into one rEFInd entry: the
  # default generation boots, the newest generations are in the submenu
  # newest first, and entries rEFInd can't express are left out.
  generator = pkgs.runCommand "generator" { nativeBuildInputs = [ generator ]; } ''
    entries=esp/loader/entries
    mkdir -p $entries
    # Rolled back: the default is not the newest generation.
    echo "default nixos-generation-2.conf" > esp/loader/loader.conf
    printf '%s\n' "title NixOS" "version Generation 1, built on 2026-01-01" \
      "linux /EFI/nixos/k1.efi" "options init=/s1/init quiet" > $entries/nixos-generation-1.conf
    printf '%s\n' "title NixOS" "version Generation 2, built on 2026-01-02" \
      "linux /EFI/nixos/k2.efi" "initrd /EFI/nixos/i2.efi" "options init=/s2/init quiet" \
      > $entries/nixos-generation-2.conf
    printf '%s\n' "title NixOS" "version Generation 3, built on 2026-01-03" \
      "linux /EFI/nixos/k3.efi" "initrd /EFI/nixos/i3.efi" "options init=/s3/init quiet" \
      > $entries/nixos-generation-3.conf
    printf '%s\n' "title NixOS" "version Generation 3, built on 2026-01-03" \
      "linux /EFI/nixos/k3.efi" "initrd /EFI/nixos/i3.efi" "options init=/s3/specialisation/gaming/init" \
      > $entries/nixos-generation-3-specialisation-gaming.conf
    printf '%s\n' "title NixOS" "version Generation 4" "linux /EFI/nixos/k4.efi" \
      "initrd /EFI/nixos/a.efi" "initrd /EFI/nixos/b.efi" "options init=/s4/init" \
      > $entries/nixos-generation-4.conf

    refind-nixos-entry --esp esp --volume ABCD --title "NixOS Work" --icon '\EFI\refind\icons\cwc.png' \
      > actual 2> warnings
    cat > expected <<'EOF'
    menuentry "NixOS Work" {
        icon \EFI\refind\icons\cwc.png
        volume ABCD
        ostype Linux
        graphics on
        loader /EFI/nixos/k2.efi
        initrd /EFI/nixos/i2.efi
        options "init=/s2/init quiet"
        submenuentry "Generation 3, built on 2026-01-03" {
            loader /EFI/nixos/k3.efi
            initrd /EFI/nixos/i3.efi
            options "init=/s3/init quiet"
        }
        submenuentry "Generation 3, built on 2026-01-03 (gaming)" {
            loader /EFI/nixos/k3.efi
            initrd /EFI/nixos/i3.efi
            options "init=/s3/specialisation/gaming/init"
        }
        submenuentry "Generation 2, built on 2026-01-02" {
            loader /EFI/nixos/k2.efi
            initrd /EFI/nixos/i2.efi
            options "init=/s2/init quiet"
        }
        submenuentry "Generation 1, built on 2026-01-01" {
            loader /EFI/nixos/k1.efi
            initrd
            options "init=/s1/init quiet"
        }
    }
    EOF
    diff -u expected actual
    grep -q "skipping nixos-generation-4.conf: it has more than one initrd" warnings

    # A limit keeps only the newest entries in the submenu.
    refind-nixos-entry --esp esp --volume ABCD --title "NixOS Work" --icon x --limit 2 2>/dev/null \
      | grep submenuentry > limited
    printf '%s\n' \
      '    submenuentry "Generation 3, built on 2026-01-03" {' \
      '    submenuentry "Generation 3, built on 2026-01-03 (gaming)" {' \
      > expected-limited
    diff -u expected-limited limited

    # rEFInd hangs on longer submenus, so the generator refuses them.
    if refind-nixos-entry --esp esp --volume ABCD --title T --icon x --limit 16 2>/dev/null; then
      echo "expected --limit 16 to be refused"
      exit 1
    fi
    touch $out
  '';

  # The host writes refind.conf with its own entry, the guest's include and
  # the fallback, and puts rEFInd first in the firmware's boot order.
  host-script = scriptHas "host-script" host [
    "include guest.conf"
    "--title 'NixOS Main'"
    "--volume 11111111-1111-1111-1111-111111111111"
    "--limit 5"
    "efibootmgr -q -o"
    "showtools about,shutdown,reboot,firmware,csr_rotate,csr_rotate,csr_rotate,csr_rotate,csr_rotate,csr_rotate,csr_rotate,csr_rotate"
    "hideui banner,hints,badges,arrows"
    "timeout 15"
  ];

  # The guest mounts the host's ESP by its GUID and writes guest.conf there.
  guest-script = scriptHas "guest-script" guest [
    "/dev/disk/by-partuuid/11111111-1111-1111-1111-111111111111"
    ''"$dir/guest.conf.tmp"''
    "--volume 22222222-2222-2222-2222-222222222222"
  ];

  # Trying rEFInd out leaves the boot order alone, shows rEFInd's own UI and
  # logs.
  host-trying-script = scriptHas "host-trying-script" hostTrying [ "log_level 2" ];

  # The host puts rEFInd, its icons and its tools' icons on its ESP, and adds
  # a systemd-boot entry for rEFInd only while trying it out; the guest adds
  # neither.
  host-files =
    assert
      builtins.attrNames host.boot.loader.systemd-boot.extraFiles == [
        "efi/refind/icons/func_about.png"
        "efi/refind/icons/func_firmware.png"
        "efi/refind/icons/func_reset.png"
        "efi/refind/icons/func_shutdown.png"
        "efi/refind/icons/main.png"
        "efi/refind/refind_x64.efi"
      ];
    assert host.boot.loader.systemd-boot.extraEntries == { };
    assert
      builtins.attrNames hostTrying.boot.loader.systemd-boot.extraEntries == [ "refind-picker.conf" ];
    assert guest.boot.loader.systemd-boot.extraFiles == { };
    pkgs.runCommand "host-files" { } "touch $out";
}
