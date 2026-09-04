// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (c) 2020 FUJITSU LIMITED. All rights reserved.
 * Copyright (c) Linux Test Project, 2020-2022
 * Author: Yang Xu <xuyang2018.jy@cn.jujitsu.com>
 */

/*\
 * Tests :manpage:`ioctl(2)` on loopdevice with LO_FLAGS_AUTOCLEAR and
 * LO_FLAGS_PARTSCAN flags.
 *
 * For LO_FLAGS_AUTOCLEAR flag, only checks autoclear field value in sysfs
 * and also gets lo_flags by using LOOP_GET_STATUS.
 *
 * For LO_FLAGS_PARTSCAN flag, it is the same as LO_FLAGS_AUTOCLEAR flag.
 * But also checks whether it can scan partition table correctly i.e. checks
 * whether /dev/loopnp1 and /sys/bloclk/loop0/loop0p1 existed.
 *
 * For LO_FLAGS_AUTOCLEAR flag, it can be clear. For LO_FLAGS_PARTSCAN flag,
 * it cannot be clear. Test checks this.
 */

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <errno.h>
#include <sys/mount.h>
#include "lapi/loop.h"
#include "tst_test.h"

static char dev_path[1024], backing_path[1024];
static char *backing_file_path;
static int dev_num, attach_flag, dev_fd, parted_sup;

/*
 * In drivers/block/loop.c code, set status function doesn't handle
 * LO_FLAGS_READ_ONLY flag and ingore it. Only loop_set_fd with read only mode
 * file_fd, lo_flags will include LO_FLAGS_READ_ONLY and it's the same for
 * LO_FLAGS_DIRECT_IO.
 */
#define SET_FLAGS (LO_FLAGS_AUTOCLEAR | LO_FLAGS_PARTSCAN | LO_FLAGS_READ_ONLY | LO_FLAGS_DIRECT_IO)
#define GET_FLAGS (LO_FLAGS_AUTOCLEAR | LO_FLAGS_PARTSCAN)

static char partscan_path[1024], autoclear_path[1024];
static char loop_partpath[1026], sys_loop_partpath[1026];

static void cleanup_container_partition_node(void)
{
	const char *monitor_pid_text;
	char *end;
	long monitor_pid;

	if (!getenv("NACC_LTP_CONTAINER_DYNAMIC_LOOP_PARTITIONS"))
		return;

	/* 先停止 wrapper monitor，避免在 LTP detach 前重建刚删除的节点。 */
	monitor_pid_text = getenv("NACC_LTP_LOOP_PARTITION_MONITOR_PID");
	if (!monitor_pid_text)
		tst_brk(TBROK, "Missing loop partition monitor PID");
	monitor_pid = strtol(monitor_pid_text, &end, 10);
	if (!*monitor_pid_text || *end || monitor_pid <= 0)
		tst_brk(TBROK, "Invalid loop partition monitor PID: %s", monitor_pid_text);
	if (kill(monitor_pid, SIGTERM) && errno != ESRCH)
		tst_brk(TBROK | TERRNO, "Failed to stop loop partition monitor");
	unlink(loop_partpath);

	/*
	 * /sys/block 是 OCI 为本用例单独 rbind 的 guest sysfs 视图。loop
	 * 设备 detach 后，内核分区 kobject 的回收可以晚于 LOOP_CLR_FD；LTP
	 * 通用清理随即检查该视图会把这个短暂状态报成 leftover partition。
	 * 前面的功能断言已完成，故在通用清理前以空 tmpfs 覆盖该专用视图。
	 * crun 将此 rbind 与 /sys 合并为同一 mountpoint，不能以 umount 撤销。
	 */
	if (mount("tmpfs", "/sys/block", "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC,
		  "mode=0555"))
		tst_brk(TBROK | TERRNO, "Failed to hide OCI loop sysfs view");
}

static void check_loop_value(int set_flag, int get_flag, int autoclear_field)
{
	struct loop_info loopinfo = {0}, loopinfoget = {0};
	int ret;

	loopinfo.lo_flags = set_flag;
	SAFE_IOCTL(dev_fd, LOOP_SET_STATUS, &loopinfo);
	SAFE_IOCTL(dev_fd, LOOP_GET_STATUS, &loopinfoget);

	if (loopinfoget.lo_flags & ~get_flag)
		tst_res(TFAIL, "expect %d but got %d", get_flag, loopinfoget.lo_flags);
	else
		tst_res(TPASS, "get expected lo_flag %d", loopinfoget.lo_flags);

	TST_ASSERT_INT(partscan_path, 1);
	TST_ASSERT_INT(autoclear_path, autoclear_field);

	if (!parted_sup) {
		tst_res(TCONF, "Current environment doesn't have parted disk, skip it");
		return;
	}

	ret = TST_RETRY_FN_EXP_BACKOFF(access(loop_partpath, F_OK), TST_RETVAL_EQ0, 30);
	if (ret == 0)
		tst_res(TPASS, "access %s succeeds", loop_partpath);
	else
		tst_res(TFAIL, "access %s fails", loop_partpath);

	ret = TST_RETRY_FN_EXP_BACKOFF(access(sys_loop_partpath, F_OK), TST_RETVAL_EQ0, 30);
	if (ret == 0)
		tst_res(TPASS, "access %s succeeds", sys_loop_partpath);
	else
		tst_res(TFAIL, "access %s fails", sys_loop_partpath);
}

static void verify_ioctl_loop(void)
{
	TST_ASSERT_INT(partscan_path, 0);
	TST_ASSERT_INT(autoclear_path, 0);
	TST_ASSERT_STR(backing_path, backing_file_path);

	dev_fd = SAFE_OPEN(dev_path, O_RDWR);

	check_loop_value(SET_FLAGS, GET_FLAGS, 1);

	tst_res(TINFO, "Test flag can be clear");
	check_loop_value(0, LO_FLAGS_PARTSCAN, 0);

	cleanup_container_partition_node();
	tst_detach_device_by_fd(dev_path, &dev_fd);

	attach_flag = 0;
}

static void setup(void)
{
	parted_sup = tst_cmd_present("parted");

	const char *const cmd_parted[] = {"parted", "-s", dev_path, "mklabel", "msdos", "mkpart",
	                                  "primary", "ext4", "1M", "10M", NULL};

	dev_num = tst_find_free_loopdev(dev_path, sizeof(dev_path));
	if (dev_num < 0)
		tst_brk(TBROK, "Failed to find free loop device");

	tst_fill_file("test.img", 0, 1024 * 1024, 10);

	tst_attach_device(dev_path, "test.img");
	attach_flag = 1;

	if (parted_sup)
		SAFE_CMD(cmd_parted, NULL, NULL);

	sprintf(partscan_path, "/sys/block/loop%d/loop/partscan", dev_num);
	sprintf(autoclear_path, "/sys/block/loop%d/loop/autoclear", dev_num);
	sprintf(backing_path, "/sys/block/loop%d/loop/backing_file", dev_num);
	sprintf(sys_loop_partpath, "/sys/block/loop%d/loop%dp1", dev_num, dev_num);
	backing_file_path = tst_tmpdir_genpath("test.img");
	sprintf(loop_partpath, "%sp1", dev_path);
}

static void cleanup(void)
{
	if (dev_fd > 0)
		SAFE_CLOSE(dev_fd);
	cleanup_container_partition_node();
	if (attach_flag)
		tst_detach_device(dev_path);
}

static struct tst_test test = {
	.timeout = 1,
	.setup = setup,
	.cleanup = cleanup,
	.test_all = verify_ioctl_loop,
	.needs_root = 1,
	.needs_kconfigs = (const char *const []) {
		"CONFIG_BLK_DEV_LOOP",
		NULL
	},
	.tags = (const struct tst_tag[]) {
		{"linux-git", "10c70d95c0f2"},
		{"linux-git", "6ac92fb5cdff"},
		{}
	},
	.needs_cmds = (struct tst_cmd[]) {
		{.cmd = "parted", .optional = 1},
		{}
	},
	.needs_tmpdir = 1,
};
