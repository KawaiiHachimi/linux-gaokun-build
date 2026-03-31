// SPDX-License-Identifier: BSD-3-Clause
/*
 * EFI Loader Wrapper for slbounce + GRUB
 *
 * This small EFI application replaces bootaa64.efi. It uses
 * LoadImage+StartImage to load slbounce (which hooks ExitBootServices
 * and returns), then loads and starts GRUB normally.
 *
 * This replicates what the EFI Shell "load" command does, avoiding
 * the broken DriverOrder path on some firmware.
 */

#include <efi.h>
#include <efilib.h>

static EFI_STATUS LoadAndStart(EFI_HANDLE parent, CHAR16 *path, BOOLEAN report_error)
{
	EFI_STATUS status;
	EFI_LOADED_IMAGE *loaded_image;
	EFI_DEVICE_PATH *file_dp;
	EFI_HANDLE image_handle = NULL;

	status = uefi_call_wrapper(BS->HandleProtocol, 3, parent,
				   &LoadedImageProtocol, (void **)&loaded_image);
	if (EFI_ERROR(status)) {
		if (report_error)
			Print(L"HandleProtocol failed: %r\n", status);
		return status;
	}

	file_dp = FileDevicePath(loaded_image->DeviceHandle, path);
	if (!file_dp) {
		if (report_error)
			Print(L"FileDevicePath failed for %s\n", path);
		return EFI_NOT_FOUND;
	}

	status = uefi_call_wrapper(BS->LoadImage, 6, FALSE, parent,
				   file_dp, NULL, 0, &image_handle);
	FreePool(file_dp);
	if (EFI_ERROR(status)) {
		if (report_error)
			Print(L"LoadImage(%s) failed: %r\n", path, status);
		return status;
	}

	status = uefi_call_wrapper(BS->StartImage, 3, image_handle, NULL, NULL);
	return status;
}

EFI_STATUS efi_main(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
	EFI_STATUS status;

	InitializeLib(ImageHandle, SystemTable);

	status = LoadAndStart(ImageHandle, L"\\qebspilaa64.efi", FALSE);
	if (EFI_ERROR(status))
		Print(L"qebspil: %r (remoteprocs may not start)\n", status);

	status = LoadAndStart(ImageHandle, L"\\slbounceaa64.efi", FALSE);
	if (EFI_ERROR(status))
		Print(L"slbounce: %r (continuing without EL2)\n", status);

	/* Load Simple Init directly */
	status = LoadAndStart(ImageHandle, L"\\EFI\\boot\\SimpleInit-AARCH64.efi", TRUE);
	if (EFI_ERROR(status))
		Print(L"Simple Init failed: %r\n", status);

	return status;
}
