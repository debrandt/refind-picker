"""Print a rEFInd menu entry for one NixOS install's generations.

Reads the boot entries systemd-boot keeps on the install's ESP
(loader/entries/nixos-generation-*.conf) and prints one rEFInd `menuentry`
that boots the default generation, with every generation in its submenu.
rEFInd then boots the kernels systemd-boot copied to that ESP directly.
"""

import argparse
import re
import sys
from pathlib import Path

ENTRY_NAME = re.compile(r"^nixos-generation-(\d+)(?:-specialisation-(.+))?\.conf$")


def warn(message):
    print(f"refind-nixos-entry: {message}", file=sys.stderr)


def read_entry(path):
    """The entry's fields, or None if rEFInd can't express it."""
    fields = {}
    initrds = []
    for line in path.read_text().splitlines():
        key, _, value = line.strip().partition(" ")
        if not key or key.startswith("#"):
            continue
        if key == "initrd":
            initrds.append(value.strip())
        else:
            fields[key] = value.strip()

    if "linux" not in fields:
        warn(f"skipping {path.name}: it has no linux line")
        return None
    # A rEFInd stanza takes one initrd, and its options are one quoted
    # string with no way to escape a quote.
    if len(initrds) > 1:
        warn(f"skipping {path.name}: it has more than one initrd")
        return None
    if '"' in fields.get("options", ""):
        warn(f"skipping {path.name}: its options contain a double quote")
        return None

    fields["initrd"] = initrds[0] if initrds else None
    return fields


def read_entries(esp):
    """(generation, specialisation, filename, fields), newest first, each
    generation's specialisations right after it."""
    entries = []
    for path in (esp / "loader" / "entries").glob("nixos-generation-*.conf"):
        match = ENTRY_NAME.match(path.name)
        if not match:
            continue
        fields = read_entry(path)
        if fields is not None:
            generation, specialisation = match.groups()
            entries.append((int(generation), specialisation, path.name, fields))
    entries.sort(key=lambda entry: (-entry[0], entry[1] or ""))
    return entries


def default_entry_name(esp):
    """The entry systemd-boot boots by default, if loader.conf names one."""
    loader_conf = esp / "loader" / "loader.conf"
    if not loader_conf.exists():
        return None
    for line in loader_conf.read_text().splitlines():
        key, _, value = line.strip().partition(" ")
        if key == "default":
            return value.strip()
    return None


def boot_lines(fields, indent):
    lines = [f"{indent}loader {fields['linux']}"]
    # A bare initrd clears one inherited from the main stanza.
    lines.append(f"{indent}initrd {fields['initrd'] or ''}".rstrip())
    lines.append(f'{indent}options "{fields.get("options", "")}"')
    return lines


def label(specialisation, fields, generation):
    text = fields.get("version") or f"Generation {generation}"
    if specialisation:
        text += f" ({specialisation})"
    return text.replace('"', "'")


# rEFInd 0.14.2 hangs when a submenu grows past 16 items, and it adds a
# "Return to Main Menu" item of its own.
MAX_SUBMENU_ENTRIES = 15


def menu_entry(esp, volume, title, icon, limit):
    entries = read_entries(esp)
    if not entries:
        sys.exit(f"refind-nixos-entry: no usable boot entries in {esp}/loader/entries")

    # Without a usable default, the newest entry, which is a generation
    # itself rather than one of its specialisations whenever it can be.
    by_name = {entry[2]: entry for entry in entries}
    default = by_name.get(default_entry_name(esp), entries[0])

    lines = [
        f'menuentry "{title}" {{',
        f"    icon {icon}",
        f"    volume {volume}",
        "    ostype Linux",
        "    graphics on",
        *boot_lines(default[3], "    "),
    ]
    for generation, specialisation, _, fields in entries[:limit]:
        lines.append(
            f'    submenuentry "{label(specialisation, fields, generation)}" {{'
        )
        lines.extend(boot_lines(fields, "        "))
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--esp", type=Path, required=True, help="where the install's ESP is mounted"
    )
    parser.add_argument(
        "--volume", required=True, help="the ESP's partition GUID, as rEFInd finds it"
    )
    parser.add_argument("--title", required=True, help="the menu entry's name")
    parser.add_argument("--icon", required=True, help="the icon's path on rEFInd's ESP")
    parser.add_argument(
        "--limit",
        type=int,
        default=MAX_SUBMENU_ENTRIES,
        help=f"most entries in the submenu, newest first (at most {MAX_SUBMENU_ENTRIES})",
    )
    args = parser.parse_args()
    if not 1 <= args.limit <= MAX_SUBMENU_ENTRIES:
        parser.error(f"--limit must be between 1 and {MAX_SUBMENU_ENTRIES}")
    sys.stdout.write(
        menu_entry(args.esp, args.volume, args.title, args.icon, args.limit)
    )


if __name__ == "__main__":
    main()
