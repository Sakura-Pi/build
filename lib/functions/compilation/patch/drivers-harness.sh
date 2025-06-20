#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function kernel_drivers_create_patches_hash_only() {
	hash_only="yes" kernel_drivers_create_patches "${@}"
}

function kernel_drivers_create_patches() {
	if [[ "${EXTRAWIFI}" == "no" ]]; then
		display_alert "Skipping driver harness as requested" "EXTRAWIFI = ${EXTRAWIFI} - returning" "debug"
		return 0
	fi

	kernel_drivers_patch_hash="undetermined" # outer scope
	kernel_drivers_patch_file="undetermined" # outer scope

	### @TODO: this whole hashing of drivers is a mess. Any changes to any bash files involved of any changes to patches
	### @TODO:  will trigger a cache miss across _all_ kernels, even if the changes are not relevant to that kernel.
	### @TODO: is is also extremely important not to use mutable branch references (eg: "branch:master") in the
	### @TODO: fetch_from_repo()'s calls that are done in the driver bash implemenation, otherwise changes in the
	### @TODO: upstream will not be detected. Please use a fixed sha1. Error will be thrown if this is not the case.

	declare hash_files
	# hash the bash involved in the drivers. any changes in these files will trigger a cache miss
	calculate_hash_for_files "${SRC}/lib/functions/compilation/patch/drivers_network.sh" "${SRC}/lib/functions/compilation/patch/drivers-harness.sh"
	declare driver_bash_hash="${hash_files}"

	# hash the whole contents of the patch/misc dir, including subdirectories. any changes in these files will trigger a cache miss
	calculate_hash_for_all_files_in_dirs "${SRC}"/patch/misc
	declare driver_patches_hash_all="${hash_files}"

	# combine both hashes into a single one; use the first 8 chars of each
	declare hash_files="${driver_bash_hash:0:8}_${driver_patches_hash_all:0:8}"

	declare hash_variables="undetermined"
	do_normalize_src_path="no" calculate_hash_for_variables "${KERNEL_DRIVERS_SKIP[*]}"
	declare hash_variables_short="${hash_variables:0:8}"

	# Sanity check, the KERNEL_GIT_SHA1 gotta be sane.
	[[ "${KERNEL_GIT_SHA1}" =~ ^[0-9a-f]{40}$ ]] || exit_with_error "KERNEL_GIT_SHA1 is not sane: '${KERNEL_GIT_SHA1}'"

	declare cache_key_base="sha1_${KERNEL_GIT_SHA1}_${LINUXFAMILY}_${BRANCH}"
	declare cache_key="${cache_key_base}_${hash_files}-${hash_variables_short}"
	display_alert "Cache key base:" "$cache_key_base" "debug"
	display_alert "Cache key:" "$cache_key" "debug"

	declare cache_dir_base="${SRC}/cache/patch/kernel-drivers"
	mkdir -p "${cache_dir_base}"

	declare cache_target_file="${cache_dir_base}/${cache_key}.patch"

	# outer scope variables:
	kernel_drivers_patch_file="${cache_target_file}" # outer scope
	kernel_drivers_patch_hash="${hash_files}"        # outer scope

	if [[ "${hash_only:-"no"}" == "yes" ]]; then
		display_alert "Hash-only kernel driver requested" "$kernel_drivers_patch_hash - returning" "debug"
		return 0
	fi

	declare kernel_work_dir="${1}"
	declare kernel_git_revision="${2}"

	# If the target file exists, we can skip the patch creation.
	if [[ -f "${cache_target_file}" ]]; then
		# Make sure the file is larger than 512 bytes. Old versions of this code left small/empty files on failure.
		if [[ $(stat -c%s "${cache_target_file}") -gt 512 ]]; then
			display_alert "Using cached drivers patch file for ${LINUXFAMILY}-${BRANCH}" "${cache_key}" "cachehit"
			return
		else
			display_alert "Removing invalid/small cached drivers patch file for ${LINUXFAMILY}-${BRANCH}" "${cache_key}" "warn"
			run_host_command_logged rm -fv "${cache_target_file}"
		fi
	fi

	display_alert "Creating patches for kernel drivers" "version: 'sha1_${KERNEL_GIT_SHA1}' family: '${LINUXFAMILY}-${BRANCH}'" "info"

	# if it does _not_ exist, fist clear the base, so no old patches are left over
	run_host_command_logged rm -fv "${cache_dir_base}/*_${LINUXFAMILY}_${BRANCH}*"
	# also clean up old-style cache base, used before we introduced KERNEL_GIT_SHA1
	run_host_command_logged rm -fv "${cache_dir_base}/${KERNEL_MAJOR_MINOR}_${LINUXFAMILY}*"

	# since it does not exist, go create it. this requires working tree.
	declare target_patch_file="${cache_target_file}"

	display_alert "Preparing patch for drivers" "version: sha1_${KERNEL_GIT_SHA1} kernel_work_dir: ${kernel_work_dir}" "debug"

	kernel_drivers_prepare_harness "${kernel_work_dir}" "${kernel_git_revision}"
}

function kernel_drivers_prepare_harness() {
	declare kernel_work_dir="${1}"
	declare kernel_git_revision="${2}"
	# outer scope variable: target_patch_file

	declare -a all_drivers=(
		driver_generic_bring_back_ipx
		driver_mt7921u_add_pids
		driver_rtl8152_rtl8153
		driver_rtl8189ES
		driver_rtl8189FS
		driver_rtl8192EU
		driver_rtl8811_rtl8812_rtl8814_rtl8821
		driver_xradio_xr819
		driver_rtl8811CU_rtl8821C
		driver_rtl8188EU_rtl8188ETV
		driver_rtl88x2bu
		driver_rtw88
		driver_rtl8852bs
		driver_rtl88x2cs
		driver_rtl8822cs_bt
		driver_rtl8723DS
		driver_rtl8723DU
		driver_uwe5622
		driver_rtl8723cs
	)

	# Extension method for building board level drivers
	custom_drivers=$(call_extension_method "build_board_drivers" <<- 'BUILD_BOARD_DRIVERS'
		*allow extensions to build custom driver for their boards*
	BUILD_BOARD_DRIVERS
	)

	if [[ -n "$custom_drivers" ]]; then
		declare -a drvlist=()
		readarray -t drvlist <<< "${custom_drivers}"
		display_alert "Use custom board drivers: " "${drvlist[*]}"
		all_drivers+=("${drvlist[@]}")
	fi

	declare -a skip_drivers=("${KERNEL_DRIVERS_SKIP[@]}")
	declare -a drivers=()

	# Produce 'drivers' array by removing any drivers in 'skip_drivers' from 'all_drivers'
	for driver in "${all_drivers[@]}"; do
		for skip in "${skip_drivers[@]}"; do
			if [[ "${driver}" == "${skip}" ]]; then
				display_alert "Skipping kernel driver as instructed by KERNEL_DRIVERS_SKIP" "${driver}" "info"
				continue 2 # 2: continue the _outer_ loop
			fi
		done
		drivers+=("${driver}")
	done

	# change cwd to the kernel working dir
	cd "${kernel_work_dir}" || exit_with_error "Failed to change directory to ${kernel_work_dir}"

	#run_host_command_logged git status
	run_host_command_logged git reset --hard "${kernel_git_revision}"
	# git: remove tracked files, but not those in .gitignore
	run_host_command_logged git clean -fd # no -x here

	for driver in "${drivers[@]}"; do
		display_alert "Preparing driver" "${driver}" "info"

		# reset variables used by each driver
		declare version="${KERNEL_MAJOR_MINOR}"
		declare kernel_work_dir="${1}"
		declare kernel_git_revision="${2}"
		# for compatibility with `master`-based code
		declare kerneldir="${kernel_work_dir}"

		# change cwd to the kernel working dir
		cd "${kernel_work_dir}" || exit_with_error "Failed to change directory to ${kernel_work_dir}"

		# invoke the driver; non-armbian-next code.
		FETCH_FROM_REPO_CALLBACK_IF_REF_MUTABLE="kernel_drivers_handle_mutable_ref" DRIVER_HARNESS_DRIVER="${driver}" "${driver}"

		# recover from possible cwd changes in the driver code
		cd "${kernel_work_dir}" || exit_with_error "Failed to change directory to ${kernel_work_dir}"
	done

	# git: check if there are modifications
	if [[ -n "$(git status --porcelain)" ]]; then
		display_alert "Drivers have modifications" "exporting patch into ${target_patch_file}" "info"
		export_changes_as_patch_via_git_format_patch
	else
		exit_with_error "Applying drivers didn't produce changes."
	fi
}

function export_changes_as_patch_via_git_format_patch() {
	# git: add all modifications
	run_host_command_logged git add .

	declare -a common_envs=(
		"HOME=${HOME}"
		"PATH=${PATH}"
	)

	# git: commit the changes
	declare -a git_params=(
		"-c" "commit.gpgsign=false" # force gpgsign off; the user might have it enabled and it will fail.
	)
	declare -a commit_params=(
		"--quiet" # otherwise too much output
		-m "drivers for ${LINUXFAMILY}-${BRANCH} version ${KERNEL_MAJOR_MINOR} git sha1 ${KERNEL_GIT_SHA1}"
		--author="${MAINTAINER} <${MAINTAINERMAIL}>"
	)
	declare -a commit_envs=(
		"GIT_COMMITTER_NAME=${MAINTAINER}"
		"GIT_COMMITTER_EMAIL=${MAINTAINERMAIL}"
	)
	run_host_command_logged env -i "${common_envs[@]@Q}" "${commit_envs[@]@Q}" git "${git_params[@]@Q}" commit "${commit_params[@]@Q}"

	# export the commit as a patch
	declare formatpatch_params=(
		"-1" "--stdout"
		"--unified=3"    # force 3 lines of diff context
		"--keep-subject" # do not add a prefix to the subject "[PATCH] "
		# "--no-encode-email-headers" # do not encode email headers - @TODO does not exist under focal, disable
		'--signature' "Armbian generated patch from drivers for kernel ${version} and family ${LINUXFAMILY}"
		'--stat=120'            # 'wider' stat output; default is 80
		'--stat-graph-width=10' # shorten the diffgraph graph part, it's too long
		"--zero-commit"         # Output an all-zero hash in each patch’s From header instead of the hash of the commit.
	)

	declare target_patch_file_tmp="${target_patch_file}.tmp"
	# The redirect ">" is escaped here, so it's run inside the subshell, not in the current shell.
	run_host_command_logged env -i "${common_envs[@]@Q}" git format-patch "${formatpatch_params[@]@Q}" ">" "${target_patch_file_tmp}"

	# move the tmp to final, if it worked.
	run_host_command_logged mv -v "${target_patch_file_tmp}" "${target_patch_file}"
}

function kernel_drivers_handle_mutable_ref() {
	declare url="${1}" ref_type="${2}" ref="${3}" fetched_revision="${4}"

	# get the third-to-last element of the array, which is the caller of this (hopefully)
	declare stacktrace_element="unknown"
	get_stacktrace_element_by_index "-3" # fills in stracktrace_element; -1 is get_stacktrace_element_by_index, -2 is this function, and -3 is the caller of this function

	display_alert "Kernel driver ${DRIVER_HARNESS_DRIVER} fetching from mutable ref" "${DRIVER_HARNESS_DRIVER}: ${url} ${ref_type} ${ref} - should be 'commit:${fetched_revision}'" "warn"
	display_alert "Kernel driver ${DRIVER_HARNESS_DRIVER} fetching from mutable ref" "${DRIVER_HARNESS_DRIVER}: at ${stacktrace_element}" "warn"

	# warning is not enough. lets bomb out with an error, so people are _forced_ to fix it.
	exit_with_error "Kernel driver '${DRIVER_HARNESS_DRIVER}' fetching from mutable ref: ${url} ${ref_type} ${ref} - should be 'commit:${fetched_revision}' at '${stacktrace_element}' - please fix it"
}
