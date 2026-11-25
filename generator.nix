# `refind-nixos-entry`: prints a rEFInd menu entry for one NixOS install's
# systemd-boot generations. See generate_entry.py.
{ pkgs }:
pkgs.writers.writePython3Bin "refind-nixos-entry" {
  # ruff formats this file at its own 88 columns, wider than flake8 allows.
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./generate_entry.py)
