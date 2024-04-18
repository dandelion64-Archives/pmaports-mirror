#!/bin/sh
# shellcheck disable=SC1091

IN_CI="false"
LOG_PREFIX="[pmOS-rd]"

[ -e /hooks/10-verbose-initfs.sh ] && set -x

[ -e /hooks/05-ci.sh ] && IN_CI="true"

[ -e /etc/unudhcpd.conf ] && . /etc/unudhcpd.conf
. ./init_functions.sh
. /usr/share/misc/source_deviceinfo
[ -e /etc/os-release ] && . /etc/os-release
# provide a default for os-release's VERSION in case the file doesn't exist
VERSION="${VERSION:-unknown}"

# This is set during packaging and is used when triaging bug reports
INITRAMFS_PKG_VERSION="<<INITRAMFS_PKG_VERSION>>"

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
/bin/busybox --install -s
/bin/busybox-extras --install -s

# Mount everything, set up logging, modules, mdev
mount_proc_sys_dev
setup_log
setup_firmware_path

if [ "$IN_CI" = "false" ]; then
	# shellcheck disable=SC2154
	load_modules /lib/modules/initramfs.load "libcomposite"
	setup_framebuffer
	show_splash "Loading..."
	setup_mdev
	setup_dynamic_partitions "${deviceinfo_super_partitions:=}"
else
	# loads all modules
	setup_udev
fi
run_hooks /hooks

if [ "$IN_CI" = "true" ]; then
	echo "PMOS: CI tests done, disabling console and looping forever"
	dmesg -n 1
	fail_halt_boot
fi

setup_usb_network
start_unudhcpd

check_keys true

mount_subpartitions

wait_boot_partition
mount_boot_partition /boot
extract_initramfs_extra /boot/initramfs-extra
setup_udev
run_hooks /hooks-extra

# For testing the mass storage gadget log export function. We use a flag
# file on /boot so that we can test it on all devices as modifying the
# kernel cmdline is not always possible.
if [ -e /boot/.pmos_export_logs ]; then
	echo "PMOS: Exporting logs via mass storage gadget"
	show_splash "Exporting boot logs..."
	# Delete the flag so we don't soft-brick the device by always booting
	# to the log export mode.
	mount -o remount,rw /boot
	rm -f /boot/.pmos_export_logs
	fail_halt_boot
fi

wait_root_partition
delete_old_install_partition
resize_root_partition
unlock_root_partition
resize_root_filesystem
mount_root_partition

# Mount boot partition into sysroot, so we do not depend on /etc/fstab, as
# not all old installations have a proper /etc/fstab file. See #2800
umount /boot
mount_boot_partition /sysroot/boot "rw"

init="/sbin/init"
setup_bootchart2

# We might be showing "waiting for root partition", which is wrong
show_splash ""

# Restore stdout and stderr to their original values
exec 1>&3 2>&4

# Re-enable kmsg ratelimiting (might have been disabled for logging)
echo ratelimit > /proc/sys/kernel/printk_devkmsg

killall telnetd mdev udevd msm-fb-refresher syslogd 2>/dev/null

# Kill any getty shells that might be running
for pid in $(pidof sh); do
	if ! [ "$pid" = "1" ]; then
		kill -9 "$pid"
	fi
done

# shellcheck disable=SC2093
exec switch_root /sysroot "$init"

echo "$LOG_PREFIX ERROR: switch_root failed!" > /dev/kmsg
echo "$LOG_PREFIX Looping forever. Install and use the debug-shell hook to debug this." > /dev/kmsg
echo "$LOG_PREFIX For more information, see <https://postmarketos.org/debug-shell>" > /dev/kmsg
fail_halt_boot
