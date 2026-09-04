// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (c) 2020 FUJITSU LIMITED. All rights reserved.
 * Author: Yang Xu <xuyang2018.jy@cn.jujitsu.com>
 */

/*\
 * Basic test for :manpage:`ioctl(2)` with BLKRRPART, it is the same as blockdev
 * --rereadpt command.
 */

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <errno.h>
#include <sys/mount.h>
#include <stdbool.h>
#include "lapi/loop.h"
#include "tst_test.h"

#define RETVAL_CHECK(x) \
       ({ value ? TST_RETVAL_EQ0(x) : TST_RETVAL_NOTNULL(x); })

static char dev_path[1024];
static int dev_num, attach_flag, dev_fd;
static char loop_partpath[1026], sys_loop_partpath[1026];

static void cleanup_container_partition_nodes(void)
{
	const char *monitor_pid_text;
	char *end;
	long monitor_pid;
	int partition;
	char partition_path[1026];

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

	for (partition = 1; partition <= 15; partition++) {
		snprintf(partition_path, sizeof(partition_path), "%sp%d",
			 dev_path, partition);
		unlink(partition_path);
	}

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

static void check_partition(int part_num, bool value)
{
	int ret;

	sprintf(sys_loop_partpath, "/sys/block/loop%d/loop%dp%d",
		dev_num, dev_num, part_num);
	sprintf(loop_partpath, "%sp%d", dev_path, part_num);

	ret = TST_RETRY_FN_EXP_BACKOFF(access(sys_loop_partpath, F_OK), RETVAL_CHECK, 30);
	if (ret == 0)
		tst_res(value ? TPASS : TFAIL, "access %s succeeds",
			sys_loop_partpath);
	else
		tst_res(value ? TFAIL : TPASS, "access %s fails",
			sys_loop_partpath);

	ret = TST_RETRY_FN_EXP_BACKOFF(access(loop_partpath, F_OK), RETVAL_CHECK, 30);
	if (ret == 0)
		tst_res(value ? TPASS : TFAIL, "access %s succeeds",
			loop_partpath);
	else
		tst_res(value ? TFAIL : TPASS, "access %s fails",
			loop_partpath);
}

static void verify_ioctl(void)
{
	const char *const cmd_parted_old[] = {"parted", "-s", "test.img",
					      "mklabel", "msdos", "mkpart",
					      "primary", "ext4", "1M", "10M",
					      NULL};
	const char *const cmd_parted_new[] = {"parted", "-s", dev_path,
					      "mklabel", "msdos", "mkpart",
					      "primary", "ext4", "1M", "10M",
					      "mkpart", "primary", "ext4",
					      "10M", "20M", NULL};
	struct loop_info loopinfo = {0};

	SAFE_CMD(cmd_parted_old, NULL, NULL);
	tst_attach_device(dev_path, "test.img");
	attach_flag = 1;

	loopinfo.lo_flags =  LO_FLAGS_PARTSCAN;
	SAFE_IOCTL(dev_fd, LOOP_SET_STATUS, &loopinfo);
	check_partition(1, true);
	check_partition(2, false);

	SAFE_CMD(cmd_parted_new, NULL, NULL);
	TST_RETRY_FUNC(ioctl(dev_fd, BLKRRPART, 0), TST_RETVAL_EQ0);
	check_partition(1, true);
	check_partition(2, true);

	cleanup_container_partition_nodes();
	tst_detach_device_by_fd(dev_path, &dev_fd);
	dev_fd = SAFE_OPEN(dev_path, O_RDWR);
	attach_flag = 0;
}

static void setup(void)
{
	dev_num = tst_find_free_loopdev(dev_path, sizeof(dev_path));
	if (dev_num < 0)
		tst_brk(TBROK, "Failed to find free loop device");
	tst_prealloc_file("test.img", 1024 * 1024, 20);
	dev_fd = SAFE_OPEN(dev_path, O_RDWR);
}

static void cleanup(void)
{
	if (dev_fd > 0)
		SAFE_CLOSE(dev_fd);
	cleanup_container_partition_nodes();
	if (attach_flag)
		tst_detach_device(dev_path);
}

static struct tst_test test = {
	.timeout = 1,
	.setup = setup,
	.cleanup = cleanup,
	.test_all = verify_ioctl,
	.needs_root = 1,
	.needs_kconfigs = (const char *const []) {
		"CONFIG_BLK_DEV_LOOP",
		NULL
	},
	.needs_cmds = (struct tst_cmd[]) {
		{.cmd = "parted"},
		{}
	},
	.needs_tmpdir = 1,
};
