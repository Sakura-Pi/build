#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) Martin Schmiedel
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/
#

ARCH="arm64"
KERNEL_IMAGE_TYPE="Image"
OVERLAY_DIR="/boot/dtb/freescale/overlay"
SRC_EXTLINUX="yes" # use extlinux as default
IMX_FIRMWARE="${IMX_FIRMWARE:-"firmware-imx-8.26-d4c33ab"}"
# ATF_PLAT musst set in board
# ATF_UART_BASE musst set in board
# MAP = target_make,target_patchdir,target_files
# use xxx:xxx to rename files after build
ATFPATCHDIR='atf-imx8'
ATF_TARGET_MAP="PLAT=${ATF_PLAT} IMX_BOOT_UART_BASE=${ATF_UART_BASE} bl31;;build/imx8mp/release/bl31.bin"
UBOOT_TARGET_MAP="flash.bin;;flash.bin"

# linux releated
case $BOARD in

	mba8mpxl*)
		LINUXCONFIG='linux-tqma-'$BRANCH # one config for "tq arm modules"
		case $BRANCH in

			current) # mainline stable kernel
				KERNEL_MAJOR_MINOR="6.12"
				;;

			edge | default) # use for tests with recent mainline kernels
				;;

		esac
		;;

esac
