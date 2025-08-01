#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

### Attention: we can't use any interactive programs, read from stdin, nor use non-coreutils utilities here.

function do_main_configuration() {
	display_alert "Starting main configuration" "${MOUNT_UUID}" "info"

	# Obsolete stuff, make sure not defined, then make readonly
	declare -g -r DEBOOTSTRAP_LIST
	declare -g -r PACKAGE_LIST
	declare -g -r PACKAGE_LIST_BOARD
	declare -g -r PACKAGE_LIST_ADDITIONAL
	declare -g -r PACKAGE_LIST_EXTERNAL
	declare -g -r PACKAGE_LIST_DESKTOP

	# common options
	declare revision_from="set in env or command-line parameter"
	if [[ "${REVISION}" == "" ]]; then
		if [ -f "${USERPATCHES_PATH}"/VERSION ]; then
			REVISION=$(cat "${USERPATCHES_PATH}"/VERSION)
			revision_from="userpatches VERSION file"
		else
			REVISION=$(cat "${SRC}"/VERSION)
			revision_from="main VERSION file"
		fi
	fi

	declare -g -r REVISION="${REVISION}"
	display_alert "Using REVISION from" "${revision_from}: '${REVISION}'" "info"
	if [[ ! "${REVISION}" =~ ^[0-9] ]]; then
		exit_with_error "REVISION must begin with a digit, got '${REVISION}'"
	fi

	# Armbian image is set as unofficial if build manually or without declaring from outside
	[[ -z $VENDOR ]] && VENDOR="Armbian-unofficial"

	# Use framework defaults for community Armbian images and unsupported distribution when building Armbian distribution
	if [[ ${VENDOR} == "Armbian" ]] && [[ ${BOARD_TYPE} != "conf" || $(cat $SRC/config/distributions/$RELEASE/support) != "supported" ]]; then
		VENDORURL="https://www.armbian.com/"
		unset VENDORSUPPORT,VENDORPRIVACY,VENDORBUGS,VENDORLOGO,ROOTPWD,MAINTAINER,MAINTAINERMAIL
	fi

	[[ -z $VENDORCOLOR ]] && VENDORCOLOR="247;16;0"                           # RGB values for MOTD logo
	[[ -z $VENDORURL ]] && VENDORURL="https://duckduckgo.com/"
	[[ -z $VENDORSUPPORT ]] && VENDORSUPPORT="https://community.armbian.com/"
	[[ -z $VENDORPRIVACY ]] && VENDORPRIVACY="https://duckduckgo.com/"
	[[ -z $VENDORBUGS ]] && VENDORBUGS="https://armbian.atlassian.net/"
	[[ -z $VENDORDOCS ]] && VENDORDOCS="https://docs.armbian.com/"
	[[ -z $VENDORLOGO ]] && VENDORLOGO="armbian-logo"
	[[ -z $ROOTPWD ]] && ROOTPWD="1234"                                       # Must be changed @first login
	[[ -z $MAINTAINER ]] && MAINTAINER="John Doe"                             # deb signature
	[[ -z $MAINTAINERMAIL ]] && MAINTAINERMAIL="john.doe@somewhere.on.planet" # deb signature
	DEST_LANG="${DEST_LANG:-"en_US.UTF-8"}"                                   # en_US.UTF-8 is default locale for target
	display_alert "DEST_LANG..." "DEST_LANG: ${DEST_LANG}" "debug"

	declare -g SKIP_EXTERNAL_TOOLCHAINS="${SKIP_EXTERNAL_TOOLCHAINS:-yes}" # don't use any external toolchains, by default.
	declare -g USE_CCACHE="${USE_CCACHE:-no}"                              # stop using ccache as our worktree is more effective

	# Armbian config is central tool used in all builds. As its build externally, we have moved it to extension. Enable it here.
	enable_extension "armbian-config"

	# Network stack to use, default to network-manager; configuration can override this.
	# Will be made read-only further down.
	declare -g NETWORKING_STACK="${NETWORKING_STACK}"

	# If empty, default depending on BUILD_MINIMAL; if yes, use systemd-networkd; if no, use network-manager.
	if [[ -z "${NETWORKING_STACK}" ]]; then
		display_alert "NETWORKING_STACK not set" "Calculating defaults" "debug"
		# Network-manager and Chrony for standard CLI and desktop, systemd-networkd and systemd-timesyncd for minimal
		# systemd-timesyncd is slimmer and less resource intensive than Chrony, see https://unix.stackexchange.com/questions/504381/chrony-vs-systemd-timesyncd-what-are-the-differences-and-use-cases-as-ntp-cli
		if [[ "${BUILD_MINIMAL}" == "yes" ]]; then
			display_alert "BUILD_MINIMAL is set to yes" "Using systemd-networkd" "debug"
			NETWORKING_STACK="systemd-networkd"
		else
			display_alert "BUILD_MINIMAL not set to yes" "Using network-manager" "debug"
			NETWORKING_STACK="network-manager"
		fi
	else
		display_alert "NETWORKING_STACK is preset during configuration" "NETWORKING_STACK: ${NETWORKING_STACK}" "debug"
	fi

	# Timezone
	if [[ -f /etc/timezone ]]; then # Timezone for target is taken from host, if it exists.
		TZDATA=$(cat /etc/timezone)
		display_alert "Using host's /etc/timezone for" "TZDATA: ${TZDATA}" "debug"
	else
		display_alert "Host has no /etc/timezone" "Using Etc/UTC by default" "debug"
		TZDATA="Etc/UTC" # If not /etc/timezone at host, default to UTC.
	fi

	USEALLCORES=yes # Use all CPU cores for compiling

	[[ -z $EXIT_PATCHING_ERROR ]] && EXIT_PATCHING_ERROR="" # exit patching if failed
	[[ -z $HOST ]] && HOST="$BOARD"
	cd "${SRC}" || exit

	[[ -z "${CHROOT_CACHE_VERSION}" ]] && CHROOT_CACHE_VERSION=7

	if [[ -d "${SRC}/.git" && "${CONFIG_DEFS_ONLY}" != "yes" ]]; then # don't waste time if only gathering config defs
		# The docker launcher will have passed these as environment variables. If not, try again here.
		if [[ -z "${BUILD_REPOSITORY_URL}" || -z "${BUILD_REPOSITORY_COMMIT}" ]]; then
			set_git_build_repo_url_and_commit_vars "main configuration"
		fi
	fi

	ROOTFS_CACHE_MAX=200 # max number of rootfs cache, older ones will be cleaned up

	# .deb compression. xz is standard, but is slow, so if avoided by default if not running in CI. one day, zstd.
	if [[ -z ${DEB_COMPRESS} ]]; then
		DEB_COMPRESS="none"                          # none is very fast bug produces big artifacts.
		[[ "${CI}" == "true" ]] && DEB_COMPRESS="xz" # xz is small and slow
	fi
	display_alert ".deb compression" "DEB_COMPRESS=${DEB_COMPRESS}" "debug"

	declare -g -r PACKAGES_HASHED_STORAGE="${DEST}/packages-hashed"
	if [[ $BETA == yes ]]; then
		DEB_STORAGE=$DEST/debs-beta
	else
		DEB_STORAGE=$DEST/debs
	fi

	# image artefact destination with or without subfolder
	FINALDEST="${DEST}/images"
	if [[ -n "${MAKE_FOLDERS}" ]]; then
		FINALDEST="${DEST}"/images/"${BOARD}"/"${MAKE_FOLDERS}"
		install -d "${FINALDEST}"
	fi

	# Prepare rootfs filesystem support
	[[ -z $ROOTFS_TYPE ]] && ROOTFS_TYPE=ext4 # default rootfs type is ext4
	case "$ROOTFS_TYPE" in
		ext4) # nothing extra here
			;;
		nfs)
			FIXED_IMAGE_SIZE=256 # small SD card with kernel, boot script and .dtb/.bin files
			;;
		f2fs)
			enable_extension "fs-f2fs-support"
			# Fixed image size is in 1M dd blocks (MiB)
			# to get size of block device /dev/sdX execute as root: echo $(( $(blockdev --getsize64 /dev/sdX) / 1024 / 1024 ))
			[[ -z $FIXED_IMAGE_SIZE ]] && exit_with_error "Please define FIXED_IMAGE_SIZE for use with f2fs"
			;;
		xfs)
			enable_extension "fs-xfs-support"
			;;
		btrfs)
			enable_extension "fs-btrfs-support"
			[[ -z $BTRFS_COMPRESSION ]] && BTRFS_COMPRESSION=zlib # default btrfs filesystem compression method is zlib
			[[ ! $BTRFS_COMPRESSION =~ zlib|lzo|zstd|none ]] && exit_with_error "Unknown btrfs compression method" "$BTRFS_COMPRESSION"
			;;
		nilfs2)
			enable_extension "fs-nilfs2-support"
			;;
		*)
			exit_with_error "Unknown rootfs type: ROOTFS_TYPE='${ROOTFS_TYPE}'"
			;;
	esac

	# Check if the filesystem type is supported by the build host
	if [[ $CONFIG_DEFS_ONLY != yes ]]; then # don't waste time if only gathering config defs
		check_filesystem_compatibility_on_host
	fi

	# Support for LUKS / cryptroot
	if [[ $CRYPTROOT_ENABLE == yes ]]; then
		enable_extension "fs-cryptroot-support" # add the tooling needed, cryptsetup
		if [[ -z $CRYPTROOT_PASSPHRASE ]]; then # a passphrase is mandatory if rootfs encryption is enabled
			exit_with_error "Root encryption is enabled but CRYPTROOT_PASSPHRASE is not set"
		fi
		[[ -z $CRYPTROOT_MAPPER ]] && CRYPTROOT_MAPPER="armbian-root" # TODO: fixed name can't be used for parallel image building (rpardini: ?)
		[[ -z $CRYPTROOT_SSH_UNLOCK ]] && CRYPTROOT_SSH_UNLOCK=yes
		[[ -z $CRYPTROOT_SSH_UNLOCK_PORT ]] && CRYPTROOT_SSH_UNLOCK_PORT=2022
		# Default to pdkdf2, this used to be the default with cryptroot <= 2.0, however
		# cryptroot 2.1 changed that to Argon2i. Argon2i is a memory intensive
		# algorithm which doesn't play well with SBCs (need 1GiB RAM by default !)
		# https://gitlab.com/cryptsetup/cryptsetup/-/issues/372
		[[ -z $CRYPTROOT_PARAMETERS ]] && CRYPTROOT_PARAMETERS="--pbkdf pbkdf2"
	fi

	# Since we are having too many options for mirror management,
	# then here is yet another mirror related option.
	# Respecting user's override in case a mirror is unreachable.
	case $REGIONAL_MIRROR in
		china)
			[[ -z $USE_MAINLINE_GOOGLE_MIRROR ]] && [[ -z $MAINLINE_MIRROR ]] && MAINLINE_MIRROR=tuna
			[[ -z $USE_GITHUB_UBOOT_MIRROR ]] && [[ -z $UBOOT_MIRROR ]] && UBOOT_MIRROR=gitee
			[[ -z $GITHUB_MIRROR ]] && GITHUB_MIRROR=ghproxy
			[[ -z $DOWNLOAD_MIRROR ]] && DOWNLOAD_MIRROR=china
			[[ -z $GHCR_MIRROR ]] && GHCR_MIRROR=nju
			;;
		*) ;;

	esac

	# Defaults... # @TODO: why?
	declare -g -r MAINLINE_UBOOT_DIR='u-boot'

	# pre-calculate mirrors. important: this sets _SOURCE variants that might be used in common.conf to default things to mainline, but using mirror.
	# @TODO: setting them here allows family/board code (and hooks) to read them and embed them into configuration, which is bad: it might end up without the mirror.
	[[ $USE_MAINLINE_GOOGLE_MIRROR == yes ]] && MAINLINE_MIRROR=google

	case $MAINLINE_MIRROR in
		google)
			declare -g -r MAINLINE_KERNEL_SOURCE='https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux-stable'
			declare -g -r MAINLINE_FIRMWARE_SOURCE='https://kernel.googlesource.com/pub/scm/linux/kernel/git/firmware/linux-firmware.git'
			;;
		tuna)
			declare -g -r MAINLINE_KERNEL_SOURCE='https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git'
			declare -g -r MAINLINE_FIRMWARE_SOURCE='https://mirrors.tuna.tsinghua.edu.cn/git/linux-firmware.git'
			;;
		bfsu)
			declare -g -r MAINLINE_KERNEL_SOURCE='https://mirrors.bfsu.edu.cn/git/linux-stable.git'
			declare -g -r MAINLINE_FIRMWARE_SOURCE='https://mirrors.bfsu.edu.cn/git/linux-firmware.git'
			;;
		*)
			declare -g -r MAINLINE_KERNEL_SOURCE='https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git' # "linux-stable" was renamed to "linux"
			declare -g -r MAINLINE_FIRMWARE_SOURCE='https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git'
			;;
	esac

	[[ $USE_GITHUB_UBOOT_MIRROR == yes ]] && UBOOT_MIRROR=github # legacy compatibility?

	case $UBOOT_MIRROR in
		gitee)
			declare -g -r MAINLINE_UBOOT_SOURCE='https://gitee.com/mirrors/u-boot.git'
			;;
		denx)
			declare -g -r MAINLINE_UBOOT_SOURCE='https://source.denx.de/u-boot/u-boot.git'
			;;
		*)
			declare -g -r MAINLINE_UBOOT_SOURCE='https://github.com/u-boot/u-boot'
			;;
	esac

	case $GITHUB_MIRROR in
		fastgit)
			declare -g -r GITHUB_SOURCE='https://hub.fastgit.xyz'
			;;
		ghproxy)
			[[ -z $GHPROXY_ADDRESS ]] && GHPROXY_ADDRESS=ghfast.top
			declare -g -r GITHUB_SOURCE="https://${GHPROXY_ADDRESS}/https://github.com"
			;;
		gitclone)
			declare -g -r GITHUB_SOURCE='https://gitclone.com/github.com'
			;;
		*)
			declare -g -r GITHUB_SOURCE='https://github.com'
			;;
	esac

	case $GHCR_MIRROR in
		dockerproxy)
			GHCR_MIRROR_ADDRESS="${GHCR_MIRROR_ADDRESS:-"ghcr.dockerproxy.net"}"
			declare -g -r GHCR_SOURCE=$GHCR_MIRROR_ADDRESS
			;;
		nju)
			declare -g -r GHCR_SOURCE='ghcr.nju.edu.cn'
			;;
		*)
			declare -g -r GHCR_SOURCE='ghcr.io'
			;;
	esac

	# Let's set default data if not defined in board configuration above
	[[ -z $OFFSET ]] && OFFSET=4 # offset to 1st partition (we use 4MiB boundaries by default)
	[[ -z $ARCH ]] && ARCH=arm64 # makes little sense to default to anything... # @TODO: remove, but check_config_userspace_release_and_desktop requires it
	ATF_COMPILE=yes              # @TODO: move to armhf/arm64
	[[ -z $EXTRAWIFI ]] && EXTRAWIFI="yes"
	[[ -z $PLYMOUTH ]] && PLYMOUTH="yes"
	[[ -z $AUFS ]] && AUFS="yes"
	[[ -z $IMAGE_PARTITION_TABLE ]] && IMAGE_PARTITION_TABLE="msdos"
	[[ -z $EXTRA_BSP_NAME ]] && EXTRA_BSP_NAME=""
	[[ -z $EXTRA_ROOTFS_MIB_SIZE ]] && EXTRA_ROOTFS_MIB_SIZE=0
	[[ -z $CONSOLE_AUTOLOGIN ]] && CONSOLE_AUTOLOGIN="yes"

	# single ext4 partition is the default and preferred configuration
	#BOOTFS_TYPE=''

	###
	### ------------------- Sourcing family config -------------------
	###
	source_family_config_and_arch

	if [[ "$HAS_VIDEO_OUTPUT" == "no" ]]; then
		PLYMOUTH="no"
		[[ $BUILD_DESKTOP != "no" ]] && exit_with_error "HAS_VIDEO_OUTPUT is set to no. So we shouldn't build desktop environment"
	fi

	# Make NETWORKING_STACK read-only, as further changes would make the whole thing inconsistent.
	# But only after family config to allow family to change it (post-family hooks CANNOT change NETWORKING_STACK since the hook is running after this).
	# Individual networking extensions should _check_ this to make there's no spurious enablement.
	display_alert "Using NETWORKING_STACK" "NETWORKING_STACK: ${NETWORKING_STACK}" "info"
	declare -g -r NETWORKING_STACK="${NETWORKING_STACK}"

	# Now enable extensions according to the configuration.
	case "${NETWORKING_STACK}" in
		"network-manager")
			display_alert "Adding networking extensions" "net-network-manager, net-chrony" "info"
			enable_extension "net-network-manager"
			enable_extension "net-chrony"
			;;
		"systemd-networkd")
			display_alert "Adding networking extensions" "net-systemd-networkd, net-systemd-timesyncd" "info"
			enable_extension "net-systemd-networkd"
			enable_extension "net-systemd-timesyncd"
			;;
		"none")
			display_alert "NETWORKING_STACK=${NETWORKING_STACK}" "Not adding networking extensions" "info"
			;;
		*)
			display_alert "NETWORKING_STACK=${NETWORKING_STACK}" "Invalid value? Not adding networking extensions" "wrn"
			;;
	esac

        # enable APA extension for Debian Unstable release
        [ "$RELEASE" = "sid" ] && enable_extension "apa"

	## Extensions: at this point we've sourced all the config files that will be used,
	##             and (hopefully) not yet invoked any extension methods. So this is the perfect
	##             place to initialize the extension manager. It will create functions
	##             like the 'post_family_config' that is invoked below.
	initialize_extension_manager

	call_extension_method "post_family_config" "config_tweaks_post_family_config" <<- 'POST_FAMILY_CONFIG'
		*give the config a chance to override the family/arch defaults*
		This hook is called after the family configuration (`sources/families/xxx.conf`) is sourced.
		Since the family can override values from the user configuration and the board configuration,
		it is often used to in turn override those.
	POST_FAMILY_CONFIG
	track_general_config_variables "after post_family_config hooks"

	# A secondary post_family_config hook, this time with the BRANCH in the name, lowercase.
	call_extension_method "post_family_config_branch_${BRANCH,,}" <<- 'POST_FAMILY_CONFIG_PER_BRANCH'
		*give the config a chance to override the family/arch defaults, per branch*
		This hook is called after the family configuration (`sources/families/xxx.conf`) is sourced,
		and after `post_family_config()` hook is already run.
		The sole purpose of this is to avoid "case ... esac for $BRANCH" in the board configuration,
		allowing separate functions for different branches. You're welcome.
	POST_FAMILY_CONFIG_PER_BRANCH
	track_general_config_variables "after post_family_config_branch hooks"

	# Lets make some variables readonly.
	# We don't want anything changing them, it's exclusively for family config.
	declare -g -r PACKAGE_LIST_FAMILY="${PACKAGE_LIST_FAMILY}"
	declare -g -r PACKAGE_LIST_FAMILY_REMOVE="${PACKAGE_LIST_FAMILY_REMOVE}"

	display_alert "Done with do_main_configuration" "do_main_configuration" "debug"
}

function do_extra_configuration() {
	[[ -n $ATFSOURCE && -z $ATF_USE_GCC ]] && exit_with_error "Error in configuration: ATF_USE_GCC is unset"
	[[ -z $UBOOT_USE_GCC ]] && exit_with_error "Error in configuration: UBOOT_USE_GCC is unset"
	[[ -z $KERNEL_USE_GCC ]] && exit_with_error "Error in configuration: KERNEL_USE_GCC is unset"

	declare BOOTCONFIG_VAR_NAME="BOOTCONFIG_${BRANCH^^}" # Branch name, uppercase
	BOOTCONFIG_VAR_NAME=${BOOTCONFIG_VAR_NAME//-/_}      # Replace dashes with underscores
	[[ -n ${!BOOTCONFIG_VAR_NAME} ]] && BOOTCONFIG=${!BOOTCONFIG_VAR_NAME}
	[[ -z $BOOTPATCHDIR ]] && BOOTPATCHDIR="u-boot-$LINUXFAMILY" # @TODO move to hook
	[[ -z $ATFPATCHDIR ]] && ATFPATCHDIR="atf-$LINUXFAMILY"

	if [[ "$RELEASE" =~ ^(focal|jammy|noble|oracular|plucky)$ ]]; then
		DISTRIBUTION="Ubuntu"
	else
		DISTRIBUTION="Debian"
	fi

	DEBIAN_MIRROR='deb.debian.org/debian'
	DEBIAN_SECURTY='security.debian.org/'
	[[ "${ARCH}" == "amd64" ]] &&
		UBUNTU_MIRROR='archive.ubuntu.com/ubuntu/' ||
		UBUNTU_MIRROR='ports.ubuntu.com/'

	if [[ $DOWNLOAD_MIRROR == "china" ]]; then
		DEBIAN_MIRROR='mirrors.tuna.tsinghua.edu.cn/debian'
		DEBIAN_SECURTY='mirrors.tuna.tsinghua.edu.cn/debian-security'
		[[ "${ARCH}" == "amd64" ]] &&
			UBUNTU_MIRROR='mirrors.tuna.tsinghua.edu.cn/ubuntu/' ||
			UBUNTU_MIRROR='mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/'
	fi

	if [[ $DOWNLOAD_MIRROR == "bfsu" ]]; then
		DEBIAN_MIRROR='mirrors.bfsu.edu.cn/debian'
		DEBIAN_SECURTY='mirrors.bfsu.edu.cn/debian-security'
		[[ "${ARCH}" == "amd64" ]] &&
			UBUNTU_MIRROR='mirrors.bfsu.edu.cn/ubuntu/' ||
			UBUNTU_MIRROR='mirrors.bfsu.edu.cn/ubuntu-ports/'
	fi

	if [[ "${ARCH}" == "amd64" ]]; then
		UBUNTU_MIRROR='archive.ubuntu.com/ubuntu' # ports are only for non-amd64, of course.
		if [[ -n ${CUSTOM_UBUNTU_MIRROR} ]]; then # ubuntu redirector doesn't work well on amd64
			UBUNTU_MIRROR="${CUSTOM_UBUNTU_MIRROR}"
		fi
	fi

	if [[ "${ARCH}" != "i386" && "${ARCH}" != "amd64" ]]; then # ports are not present on all mirrors
		if [[ -n ${CUSTOM_UBUNTU_MIRROR_PORTS} ]]; then
			display_alert "Using custom ports/${ARCH} mirror" "${CUSTOM_UBUNTU_MIRROR_PORTS}" "info"
			UBUNTU_MIRROR="${CUSTOM_UBUNTU_MIRROR_PORTS}"
		fi
	fi

	# Control aria2c's usage of ipv6.
	[[ -z $DISABLE_IPV6 ]] && DISABLE_IPV6="true"

	# @TODO this is _very legacy_ and should be removed. Old-time users might have a lib.config lying around and it will mess up things.
	# For (late) user override.
	# Notice: it is too late to define hook functions or add extensions in lib.config, since the extension initialization already ran by now.
	#         in case the user tries to use them in lib.config, hopefully they'll be detected as "wishful hooking" and the user will be wrn'ed.
	if [[ -f $USERPATCHES_PATH/lib.config ]]; then
		display_alert "Using user configuration override" "$USERPATCHES_PATH/lib.config" "info"
		# shellcheck source=/dev/null
		source "$USERPATCHES_PATH"/lib.config
		track_general_config_variables "after sourcing lib.config"
	fi

	# Prepare array for extensions to fill in.
	display_alert "Main config" "initting EXTRA_IMAGE_SUFFIXES" "debug"
	declare -g -a EXTRA_IMAGE_SUFFIXES=()

	call_extension_method "user_config" <<- 'USER_CONFIG'
		*Invoke function with user override*
		Allows for overriding configuration values set anywhere else.
		It is called after sourcing the `lib.config` file if it exists,
		but before assembling any package lists.
	USER_CONFIG
	track_general_config_variables "after user_config hooks"

	display_alert "Extensions: prepare configuration" "extension_prepare_config" "debug"
	call_extension_method "extension_prepare_config" <<- 'EXTENSION_PREPARE_CONFIG'
		*allow extensions to prepare their own config, after user config is done*
		Implementors should preserve variable values pre-set, but can default values an/or validate them.
		This runs *after* user_config. Don't change anything not coming from other variables or meant to be configured by the user.
	EXTENSION_PREPARE_CONFIG
	track_general_config_variables "after extension_prepare_config hooks"

	error_if_lib_tag_set # make sure users are not thrown off by using old parameter which does nothing anymore

	# apt-cacher-ng mirror configurarion
	APT_MIRROR=$DEBIAN_MIRROR
	if [[ $DISTRIBUTION == Ubuntu ]]; then
		APT_MIRROR=$UBUNTU_MIRROR
	fi

	[[ -n "${APT_PROXY_ADDR}" ]] && display_alert "Using custom apt proxy address" "APT_PROXY_ADDR=${APT_PROXY_ADDR}" "info"

	# @TODO: allow to run aggregation, for CONFIG_DEFS_ONLY? rootfs_aggregate_packages

	# Give the option to configure DNS server used in the chroot during the build process
	[[ -z $NAMESERVER ]] && NAMESERVER="1.0.0.1" # default is cloudflare alternate

	# Consolidate the extra image suffix. loop and add.
	declare EXTRA_IMAGE_SUFFIX=""
	for suffix in "${EXTRA_IMAGE_SUFFIXES[@]}"; do
		display_alert "Adding extra image suffix" "'${suffix}'" "debug"
		EXTRA_IMAGE_SUFFIX="${EXTRA_IMAGE_SUFFIX}${suffix}"
	done
	declare -g -r EXTRA_IMAGE_SUFFIX="${EXTRA_IMAGE_SUFFIX}"
	display_alert "Extra image suffix" "'${EXTRA_IMAGE_SUFFIX}'" "debug"
	unset EXTRA_IMAGE_SUFFIXES # get rid of this, no longer used

	# Lets estimate the image name, based on the configuration. The real image name depends on _actual_ kernel version.
	# Here we do a gross estimate with the KERNEL_MAJOR_MINOR + ".y" version, or "generic" if not set (ddks etc).
	declare calculated_image_version="undetermined"
	declare predicted_kernel_version="generic"
	if [[ -n "${KERNEL_MAJOR_MINOR}" ]]; then
		predicted_kernel_version="${KERNEL_MAJOR_MINOR}.y"
	fi
	IMAGE_INSTALLED_KERNEL_VERSION="${predicted_kernel_version}" include_vendor_version="no" calculate_image_version

	declare -r -g IMAGE_FILE_ID="${calculated_image_version}" # Global, readonly.

	display_alert "Done with do_extra_configuration" "do_extra_configuration" "debug"
}

function write_config_summary_output_file() {
	local debug_dpkg_arch debug_uname debug_virt debug_src_mount
	debug_dpkg_arch="$(dpkg --print-architecture)"
	debug_uname="$(uname -a)"
	# We might not have systemd-detect-virt, specially inside docker. Docker images have no systemd...
	debug_virt="unknown-nosystemd"
	if [[ -n "$(command -v systemd-detect-virt)" ]]; then
		debug_virt="$(systemd-detect-virt || true)"
	fi
	debug_src_mount="$(findmnt --output TARGET,SOURCE,FSTYPE,AVAIL --target "${SRC}" --uniq)"

	display_alert "Writing build config summary to" "debug log" "debug"
	LOG_ASSET="build.summary.txt" do_with_log_asset cat <<- EOF
		## BUILD SCRIPT ENVIRONMENT

		Repository: $REPOSITORY_URL
		Version: $REPOSITORY_COMMIT

		Host OS: $HOSTRELEASE
		Host arch: ${debug_dpkg_arch}
		Host system: ${debug_uname}
		Virtualization type: ${debug_virt}

		## Build script directories
		Build directory is located on:
		${debug_src_mount}

		## BUILD CONFIGURATION

		Build target:
		Board: $BOARD
		Branch: $BRANCH
		Minimal: $BUILD_MINIMAL
		Desktop: $BUILD_DESKTOP
		Desktop Environment: $DESKTOP_ENVIRONMENT
		Software groups: $DESKTOP_APPGROUPS_SELECTED

		Kernel configuration:
		Repository: $KERNELSOURCE
		Branch: $KERNELBRANCH
		Config file: $LINUXCONFIG

		U-boot configuration:
		Repository: $BOOTSOURCE
		Branch: $BOOTBRANCH
		Config file: $BOOTCONFIG

		Partitioning configuration: $IMAGE_PARTITION_TABLE offset: $OFFSET
		Boot partition type: ${BOOTFS_TYPE:-(none)} ${BOOTSIZE:+"(${BOOTSIZE} MB)"}
		Root partition type: $ROOTFS_TYPE ${FIXED_IMAGE_SIZE:+"(${FIXED_IMAGE_SIZE} MB)"}

		CPU configuration: $CPUMIN - $CPUMAX with $GOVERNOR
	EOF
}

function source_family_config_and_arch() {
	declare -a family_source_paths=("${SRC}/config/sources/families/${LINUXFAMILY}.conf" "${USERPATCHES_PATH}/config/sources/families/${LINUXFAMILY}.conf")
	declare -i family_sourced_ok=0
	declare family_source_path
	for family_source_path in "${family_source_paths[@]}"; do
		[[ ! -f "${family_source_path}" ]] && continue

		display_alert "Sourcing family configuration" "${family_source_path}" "info"
		# shellcheck source=/dev/null
		source "${family_source_path}"

		# @TODO: reset error handling, go figure what they do in there.

		family_sourced_ok=$((family_sourced_ok + 1))
	done

	# If no families sourced (and not allowed by ext var), bail out
	if [[ ${family_sourced_ok} -lt 1 ]]; then
		if [[ "${allow_no_family:-"no"}" != "yes" ]]; then
			exit_with_error "Sources configuration not found" "tried ${family_source_paths[*]}"
		fi
	fi

	track_general_config_variables "after sourcing family config"

	# load "all-around common arch defaults" common.conf
	display_alert "Sourcing common arch configuration" "common.conf" "debug"
	# shellcheck source=config/sources/common.conf
	source "${SRC}/config/sources/common.conf"
	track_general_config_variables "after sourcing common arch"

	# load architecture defaults
	display_alert "Sourcing arch configuration" "${ARCH}.conf" "info"
	# shellcheck source=/dev/null
	source "${SRC}/config/sources/${ARCH}.conf"
	track_general_config_variables "after sourcing ${ARCH} arch"

	return 0
}

function set_git_build_repo_url_and_commit_vars() {
	display_alert "Getting git info for repo, during ${1}..." "${SRC}" "debug"
	declare -g BUILD_REPOSITORY_URL BUILD_REPOSITORY_COMMIT
	BUILD_REPOSITORY_URL="$(git -C "${SRC}" remote get-url "$(git -C "${SRC}" remote | grep origin || true)" || true)" # ignore all errors
	BUILD_REPOSITORY_COMMIT="$(git -C "${SRC}" describe --match=d_e_a_d_b_e_e_f --always --dirty || true)"             # ignore error
	display_alert "BUILD_REPOSITORY_URL set during ${1}" "${BUILD_REPOSITORY_URL}" "debug"
	display_alert "BUILD_REPOSITORY_COMMIT set during ${1}" "${BUILD_REPOSITORY_COMMIT}" "debug"
	return 0
}

function check_filesystem_compatibility_on_host() {
	if [[ -f "/proc/filesystems" ]]; then
		# Check if the filesystem is listed in /proc/filesystems
		if ! grep -q "\<$ROOTFS_TYPE\>" /proc/filesystems; then # ensure exact match with \<...\>
			# Try modprobing the fs module since it doesn't show up in /proc/filesystems if it's an unloaded module versus built-in
			if ! modprobe "$ROOTFS_TYPE"; then
				exit_with_error "Filesystem type unsupported by build host:" "$ROOTFS_TYPE"
			else
				display_alert "Sucessfully loaded kernel module for filesystem" "$ROOTFS_TYPE" ""
			fi
		fi

		# For f2fs, check if support for extended attributes is enabled in kernel config (otherwise will fail later when using rsync)
		if [ "$ROOTFS_TYPE" = "f2fs" ]; then
			local build_host_kernel_config=""

			# Try to find kernel config in different places
			if [ -f "/boot/config-$(uname -r)" ]; then
				build_host_kernel_config="/boot/config-$(uname -r)"
			elif [ -f "/proc/config.gz" ]; then
				# Try to extract kernel config from /proc/config.gz
				if command -v gzip &> /dev/null; then
					gzip -dc /proc/config.gz > /tmp/build_host_kernel_config
					build_host_kernel_config="/tmp/build_host_kernel_config"
				else
					display_alert "Could extract kernel config from build host, please install 'gzip'." "Build might fail in case of missing kernel configs for '${ROOTFS_TYPE}'" "wrn"
				fi
			else
				display_alert "Could not find kernel config of build host." "Build might fail in case of missing kernel configs for '${ROOTFS_TYPE}'." "wrn"
			fi

			# Check if required configurations are set
			if [ -n "$build_host_kernel_config" ]; then
				if ! grep -q '^CONFIG_F2FS_FS_XATTR=y$' "$build_host_kernel_config" ||
					! grep -q '^CONFIG_F2FS_FS_SECURITY=y$' "$build_host_kernel_config"; then
					exit_with_error "Required kernel configurations for f2fs filesystem not enabled." "Please enable CONFIG_F2FS_FS_XATTR and CONFIG_F2FS_FS_SECURITY in your kernel configuration." "err"
				fi
			fi
		fi
	else
		display_alert "Could not check filesystem support via /proc/filesystems on build host." "Build might fail in case of unsupported rootfs type." "wrn"
	fi
	return 0
}

function pre_install_distribution_specific__disable_cnf_apt_hook() {
	if [[ $(dpkg --print-architecture) != "${ARCH}" && -f "${SDCARD}"/etc/apt/apt.conf.d/50command-not-found ]]; then #disable command-not-found (60% build-time saved under qemu)
		display_alert "Disabling command-not-found during build-time to speed up image creation" "${BOARD}:${RELEASE}-${BRANCH}" "info"
		run_host_command_logged mv "${SDCARD}"/etc/apt/apt.conf.d/50command-not-found "${SDCARD}"/etc/apt/apt.conf.d/50command-not-found.disabled
	fi
}

function post_post_debootstrap_tweaks__restore_cnf_apt_hook() {
	if [ -f "${SDCARD}"/etc/apt/apt.conf.d/50command-not-found.disabled ]; then # (re-enable command-not-found after building rootfs if it's been disabled)
		display_alert "Enabling command-not-found after build-time " "${BOARD}:${RELEASE}-${BRANCH}" "info"
		run_host_command_logged mv "${SDCARD}"/etc/apt/apt.conf.d/50command-not-found.disabled "${SDCARD}"/etc/apt/apt.conf.d/50command-not-found
	fi

}
