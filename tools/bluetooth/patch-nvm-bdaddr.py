#!/usr/bin/env python3
"""Patch the generated BDADDR into the QCA WCN6855 NVM firmware."""

import hashlib
import os
import shutil
import struct
import sys
from pathlib import Path

FIRMWARE_DIR = Path("/lib/firmware/qca")
NVM_PATTERNS = (
    "wcnhpnv21g.bin",
    "hpnv21g.*",
)
SERIAL_PATH = Path("/sys/class/dmi/id/product_serial")
BD_ADDR_TAG_ID = 2
TLV_HEADER_SIZE = 4
ENTRY_HEADER_SIZE = 12
BD_ADDR_LEN = 6


def parse_nvm_find_bdaddr(data):
    """Return the offset of the BDADDR TLV payload."""
    if len(data) < TLV_HEADER_SIZE + ENTRY_HEADER_SIZE:
        return None

    type_len = struct.unpack_from("<I", data, 0)[0]
    tlv_type = type_len & 0xFF
    tlv_length = type_len >> 8
    offset = TLV_HEADER_SIZE

    if tlv_type == 4:
        if len(data) < offset + TLV_HEADER_SIZE:
            return None
        type_len = struct.unpack_from("<I", data, offset)[0]
        tlv_length = type_len >> 8
        offset += TLV_HEADER_SIZE

    idx = 0
    while idx < tlv_length:
        entry_offset = offset + idx
        if entry_offset + ENTRY_HEADER_SIZE > len(data):
            break

        tag_id = struct.unpack_from("<H", data, entry_offset)[0]
        tag_len = struct.unpack_from("<H", data, entry_offset + 2)[0]
        data_offset = entry_offset + ENTRY_HEADER_SIZE

        if data_offset + tag_len > len(data):
            break
        if tag_id == BD_ADDR_TAG_ID and tag_len == BD_ADDR_LEN:
            return data_offset

        idx += ENTRY_HEADER_SIZE + tag_len

    return None


def generate_bdaddr(serial):
    """Generate a locally-administered unicast address from the serial."""
    digest = hashlib.md5(serial.encode("utf-8")).digest()
    first = (digest[0] | 0x02) & 0xFE
    return bytes([first, *digest[1:BD_ADDR_LEN]])


def read_serial():
    try:
        serial = SERIAL_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return "gaokun3"

    return serial or "gaokun3"


def iter_nvm_files():
    """Yield supported NVM files, excluding backup copies."""
    seen = set()

    for pattern in NVM_PATTERNS:
        for path in sorted(FIRMWARE_DIR.glob(pattern)):
            if not path.is_file() or path.name.endswith(".orig"):
                continue
            if path in seen:
                continue
            seen.add(path)
            yield path


def patch_file(path, desired_addr):
    """Patch one firmware file if the stored address differs."""
    data = bytearray(path.read_bytes())
    offset = parse_nvm_find_bdaddr(data)
    if offset is None:
        return False

    desired_fw_addr = desired_addr[::-1]
    if data[offset:offset + BD_ADDR_LEN] == desired_fw_addr:
        return False

    backup = path.with_name(path.name + ".orig")
    if not backup.exists():
        shutil.copy2(path, backup)

    data[offset:offset + BD_ADDR_LEN] = desired_fw_addr
    path.write_bytes(data)
    return True


def main():
    if os.geteuid() != 0:
        print("Error: must run as root", file=sys.stderr)
        sys.exit(1)

    available_files = list(iter_nvm_files())
    if not available_files:
        print("Error: no supported QCA NVM files found", file=sys.stderr)
        sys.exit(1)

    desired_addr = generate_bdaddr(read_serial())
    for path in available_files:
        patch_file(path, desired_addr)


if __name__ == "__main__":
    main()
