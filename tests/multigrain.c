/* SPDX-License-Identifier: GPL-2.0-only */
/* Run on a disposable guest filesystem, using full nanosecond stat values. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void check(bool ok, const char *operation)
{
	if (!ok) {
		fprintf(stderr, "FAIL: %s\n", operation);
		exit(1);
	}
}

static int compare(struct timespec a, struct timespec b)
{
	if (a.tv_sec != b.tv_sec)
		return a.tv_sec < b.tv_sec ? -1 : 1;
	return (a.tv_nsec > b.tv_nsec) - (a.tv_nsec < b.tv_nsec);
}

static struct stat query(int fd)
{
	struct stat st;
	check(fstat(fd, &st) == 0, "fstat");
	return st;
}

static void write_byte(int fd, unsigned int value)
{
	unsigned char byte = value;
	check(pwrite(fd, &byte, 1, 0) == 1, "pwrite");
}

int main(int argc, char **argv)
{
	const unsigned int iterations = 10000;
	unsigned int mtime_collisions = 0, ctime_collisions = 0;
	bool expect_coarse = argc == 3 && !strcmp(argv[2], "--expect-coarse");
	struct timespec started, finished;
	struct stat before, after, other;

	if (argc < 2 || argc > 3 || (argc == 3 && !expect_coarse)) {
		fprintf(stderr, "usage: %s DIRECTORY [--expect-coarse]\n", argv[0]);
		return 2;
	}
	check(chdir(argv[1]) == 0, "chdir");
	/* O_EXCL prevents accidentally overwriting an existing user's file. */
	int fd = open("mgtime-a", O_CREAT | O_EXCL | O_RDWR, 0600);
	int second = open("mgtime-b", O_CREAT | O_EXCL | O_RDWR, 0600);
	check(fd >= 0 && second >= 0, "open");
	write_byte(fd, 0);
	write_byte(second, 0);
	check(clock_gettime(CLOCK_MONOTONIC, &started) == 0, "clock_gettime");

	for (unsigned int i = 0; i < iterations; i++) {
		/* Query before every write: multigrain only promises an observable
		 * update when the previous timestamp has actually been observed. */
		before = query(fd);
		write_byte(fd, i);
		after = query(fd);
		mtime_collisions += compare(before.st_mtim, after.st_mtim) == 0;
		ctime_collisions += compare(before.st_ctim, after.st_ctim) == 0;
		check(compare(after.st_mtim, before.st_mtim) >= 0, "mtime went backward");
		check(compare(after.st_ctim, before.st_ctim) >= 0, "ctime went backward");

		/* The second file must not get a timestamp older than the fine
		 * timestamp just assigned to the first file. */
		write_byte(second, i);
		other = query(second);
		check(compare(other.st_mtim, after.st_mtim) >= 0, "cross-file ordering");
	}
	check(clock_gettime(CLOCK_MONOTONIC, &finished) == 0, "clock_gettime");
	printf("%s: writes=%u mtime_collisions=%u ctime_collisions=%u elapsed_ns=%lld\n",
	       argv[1], iterations, mtime_collisions, ctime_collisions,
	       (long long)(finished.tv_sec - started.tv_sec) * 1000000000LL +
	       finished.tv_nsec - started.tv_nsec);
	check(expect_coarse ? mtime_collisions > 0 : mtime_collisions == 0,
	      "unexpected mtime collision count");
	check(expect_coarse ? ctime_collisions > 0 : ctime_collisions == 0,
	      "unexpected ctime collision count");

	/* Cover setattr_copy: explicit times must survive, UTIME_OMIT must
	 * preserve mtime, and UTIME_NOW must still produce an observable update. */
	struct timespec times[2] = {{1234567890, 123456789}, {1234567891, 987654321}};
	check(futimens(fd, times) == 0, "explicit futimens");
	after = query(fd);
	check(compare(after.st_atim, times[0]) == 0, "explicit atime");
	check(compare(after.st_mtim, times[1]) == 0, "explicit mtime");
	times[0].tv_nsec = UTIME_NOW;
	times[1].tv_nsec = UTIME_OMIT;
	check(futimens(fd, times) == 0, "UTIME_OMIT");
	before = query(fd);
	check(compare(before.st_mtim, after.st_mtim) == 0, "preserved mtime");
	times[1].tv_nsec = UTIME_NOW;
	check(futimens(fd, times) == 0, "UTIME_NOW");
	before = query(fd);
	check(futimens(fd, times) == 0, "repeated UTIME_NOW");
	after = query(fd);
	if (!expect_coarse)
		check(compare(after.st_mtim, before.st_mtim) > 0, "UTIME_NOW mtime");

	before = query(fd);
	check(fchmod(fd, 0640) == 0, "fchmod");
	after = query(fd);
	check(compare(after.st_mtim, before.st_mtim) == 0, "chmod changed mtime");
	if (!expect_coarse)
		check(compare(after.st_ctim, before.st_ctim) > 0, "chmod ctime");
	before = query(fd);
	check(ftruncate(fd, 0) == 0, "ftruncate");
	after = query(fd);
	if (!expect_coarse)
		check(compare(after.st_mtim, before.st_mtim) > 0, "truncate mtime");

	/* Exercise concurrent stat/write access without imposing a total order
	 * on racing syscalls. The queried flag must never leak into tv_nsec. */
	pid_t child = fork();
	check(child >= 0, "fork");
	if (!child) {
		for (unsigned int i = 0; i < iterations; i++)
			write_byte(fd, i);
		_exit(0);
	}
	for (unsigned int i = 0; i < iterations; i++) {
		after = query(fd);
		check(after.st_ctim.tv_nsec >= 0 && after.st_ctim.tv_nsec < 1000000000,
		      "invalid ctime nanoseconds");
		check(after.st_mtim.tv_nsec >= 0 && after.st_mtim.tv_nsec < 1000000000,
		      "invalid mtime nanoseconds");
	}
	int status;
	check(waitpid(child, &status, 0) == child, "waitpid");
	check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "writer failed");
	check(close(fd) == 0 && close(second) == 0, "close");
	check(unlink("mgtime-a") == 0 && unlink("mgtime-b") == 0, "unlink");
	puts("PASS: timestamps, ordering, setattr and concurrent access");
	return 0;
}
