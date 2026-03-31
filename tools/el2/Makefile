CROSS_COMPILE	:= aarch64-linux-gnu-

CC		:= $(CROSS_COMPILE)gcc
OBJCOPY		:= $(CROSS_COMPILE)objcopy

GNUEFI		:= $(CURDIR)/gnu-efi

CFLAGS := \
	-I$(GNUEFI)/inc/ -I$(GNUEFI)/inc/aarch64 -I$(GNUEFI)/inc/protocol \
	-fpic -fshort-wchar -fno-stack-protector -ffreestanding \
	-DCONFIG_aarch64 -D__MAKEWITH_GNUEFI -DGNU_EFI_USE_MS_ABI \
	-mstrict-align -O2 -Wall

LDFLAGS := \
	-Wl,--no-wchar-size-warning \
	-Wl,--defsym=EFI_SUBSYSTEM=10 \
	-e efi_main \
	-s -Wl,-Bsymbolic -nostdlib -shared \
	-L $(GNUEFI)/lib/

LIBS := -lefi -lgnuefi -T $(GNUEFI)/lib/elf_aarch64_efi.lds
CRT0 := $(GNUEFI)/lib/crt0-efi-aarch64.o

all: bootaa64.efi

loader_main.o: loader_main.c
	$(CC) $(CFLAGS) -c $< -o $@

loader.so: loader_main.o
	$(CC) $(LDFLAGS) $(CRT0) $< -o $@ $(LIBS)

bootaa64.efi: loader.so
	$(OBJCOPY) -j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rel* \
	           -j .rela* -j .reloc -j .eh_frame -O binary $< $@

clean:
	rm -f loader_main.o loader.so bootaa64.efi

.PHONY: all clean
