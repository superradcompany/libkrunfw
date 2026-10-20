/* Synthetic state and locking only; observers.inc is extracted from patch 0036. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
typedef unsigned int u32;
struct device { int unused; };
struct device_attribute { int unused; };
struct virtio_device { struct device dev; void *priv; u32 possible, requested_online; };
struct mutex { bool locked; };
struct work_struct { unsigned reads, pending_at; };
struct atomic { int value; };
struct virtio_mem {
    bool in_kdump, removing, broken, in_sbm;
    struct mutex readiness_mutex, hotplug_mutex;
    struct atomic config_changed, offline_size;
    struct work_struct wq;
    struct { unsigned long first_mb_id, next_mb_id, sbs_per_mb; } sbm;
    struct { unsigned bb_count[4]; } bbm;
    unsigned long long addr, region_size, requested_size, plugged_size;
    int states[4];
    bool unplugged[4];
};
struct msb_cpu_dev { struct mutex readiness_mutex; struct work_struct converge_work; };
enum { VIRTIO_MEM_SBM_MB_UNUSED, VIRTIO_MEM_SBM_MB_PLUGGED,
       VIRTIO_MEM_SBM_MB_OFFLINE, VIRTIO_MEM_SBM_MB_OFFLINE_PARTIAL,
       VIRTIO_MEM_SBM_MB_KERNEL, VIRTIO_MEM_SBM_MB_KERNEL_PARTIAL,
       VIRTIO_MEM_SBM_MB_MOVABLE, VIRTIO_MEM_SBM_MB_MOVABLE_PARTIAL };
enum { VIRTIO_MEM_BBM_BB_UNUSED, VIRTIO_MEM_BBM_BB_PLUGGED,
       VIRTIO_MEM_BBM_BB_ADDED, VIRTIO_MEM_BBM_BB_FAKE_OFFLINE };
static unsigned online_mask;
static bool cpu_locked;
static bool mutex_trylock(struct mutex *m) { if (m->locked) return false; m->locked = true; return true; }
static void mutex_unlock(struct mutex *m) { assert(m->locked); m->locked = false; }
static int atomic_read(struct atomic *a) { return a->value; }
static int atomic64_read(struct atomic *a) { return a->value; }
static bool work_pending(struct work_struct *w) { return w->pending_at && ++w->reads >= w->pending_at; }
static int virtio_mem_sbm_get_mb_state(struct virtio_mem *v, unsigned long id) { assert(id < 4); return v->states[id]; }
static bool virtio_mem_sbm_test_sb_unplugged(struct virtio_mem *v, unsigned long id, unsigned start, unsigned count)
{ assert(start == 0 && count == v->sbm.sbs_per_mb); return v->unplugged[id]; }
static ssize_t sysfs_emit(char *buf, const char *fmt, ...)
{ va_list ap; va_start(ap, fmt); int n = vsnprintf(buf, 4096, fmt, ap); va_end(ap); return n; }
static bool cpus_read_trylock(void) { if (cpu_locked) return false; cpu_locked = true; return true; }
static void cpus_read_unlock(void) { assert(cpu_locked); cpu_locked = false; }
static unsigned num_online_cpus(void) { return __builtin_popcount(online_mask); }
#define virtio_cread_le(v, type, member, out) (*(out) = (v)->member)
#define for_each_online_cpu(cpu) for ((cpu) = 0; (cpu) < 8; (cpu)++) if (online_mask & (1u << (cpu)))
#include "observers.inc"

static void memory_result(struct virtio_mem *vm, int error, int ready)
{
    char text[4096] = {0};
    struct virtio_device dev = {.priv = vm};
    bool worker = vm->readiness_mutex.locked, hotplug = vm->hotplug_mutex.locked;
    ssize_t n = msb_memory_readiness_show(&dev.dev, NULL, text);
    if (error) { assert(n == -error); assert(!text[0]); }
    else { assert(n > 0); assert(strstr(text, ready ? "all_online=1\n" : "all_online=0\n")); }
    assert(vm->readiness_mutex.locked == worker);
    assert(vm->hotplug_mutex.locked == hotplug);
}

static void cpu_result(struct msb_cpu_dev *cpu, struct virtio_device *dev, int error, int exact)
{
    char text[4096] = {0};
    bool worker = cpu->readiness_mutex.locked, hotplug = cpu_locked;
    ssize_t n = msb_cpu_readiness_show(&dev->dev, NULL, text);
    if (error) { assert(n == -error); assert(!text[0]); }
    else { assert(n > 0); assert(strstr(text, exact ? "exact=1\n" : "exact=0\n")); }
    assert(cpu->readiness_mutex.locked == worker);
    assert(cpu_locked == hotplug);
}

int main(void)
{
    struct virtio_mem vm = {.in_sbm = true, .sbm = {.next_mb_id = 1, .sbs_per_mb = 64}};
    /* Every tracked small-block state, with and without any plugged pages. */
    for (int state = VIRTIO_MEM_SBM_MB_UNUSED; state <= VIRTIO_MEM_SBM_MB_MOVABLE_PARTIAL; state++) {
        vm.states[0] = state;
        vm.unplugged[0] = false;
        memory_result(&vm, 0, state != VIRTIO_MEM_SBM_MB_PLUGGED &&
                      state != VIRTIO_MEM_SBM_MB_OFFLINE && state != VIRTIO_MEM_SBM_MB_OFFLINE_PARTIAL);
        vm.unplugged[0] = true;
        memory_result(&vm, 0, 1);
    }
    vm.sbm.next_mb_id = 2;
    vm.states[0] = VIRTIO_MEM_SBM_MB_KERNEL;
    vm.states[1] = VIRTIO_MEM_SBM_MB_OFFLINE_PARTIAL;
    memory_result(&vm, 0, 0); /* Must inspect beyond the first online block. */
    vm.sbm.next_mb_id = 0;
    memory_result(&vm, 0, 1); /* No hotplugged capacity is not an error. */
    vm.in_sbm = false;
    memory_result(&vm, 0, 1);
    vm.bbm.bb_count[VIRTIO_MEM_BBM_BB_ADDED] = 2;
    memory_result(&vm, 0, 1);
    vm.bbm.bb_count[VIRTIO_MEM_BBM_BB_PLUGGED] = 1;
    memory_result(&vm, 0, 0);
    vm.bbm.bb_count[VIRTIO_MEM_BBM_BB_PLUGGED] = 0;
    vm.bbm.bb_count[VIRTIO_MEM_BBM_BB_FAKE_OFFLINE] = 1;
    memory_result(&vm, 0, 0);
    vm.bbm.bb_count[VIRTIO_MEM_BBM_BB_FAKE_OFFLINE] = 0;
    vm.offline_size.value = 128;
    memory_result(&vm, 0, 0);
    vm.offline_size.value = 0;
    vm.in_kdump = true; memory_result(&vm, EOPNOTSUPP, 0); vm.in_kdump = false;
    vm.readiness_mutex.locked = true; memory_result(&vm, EAGAIN, 0); vm.readiness_mutex.locked = false;
    vm.hotplug_mutex.locked = true; memory_result(&vm, EAGAIN, 0); vm.hotplug_mutex.locked = false;
    vm.removing = true; memory_result(&vm, EIO, 0); vm.removing = false;
    vm.broken = true; memory_result(&vm, EIO, 0); vm.broken = false;
    vm.config_changed.value = 1; memory_result(&vm, EAGAIN, 0); vm.config_changed.value = 0;
    vm.wq.pending_at = 1; memory_result(&vm, EAGAIN, 0);
    vm.wq = (struct work_struct){.pending_at = 2}; memory_result(&vm, EAGAIN, 0);

    struct msb_cpu_dev cpu = {0};
    struct virtio_device dev = {.priv = &cpu, .possible = 4, .requested_online = 2};
    online_mask = 3; cpu_result(&cpu, &dev, 0, 1);
    online_mask = 5; cpu_result(&cpu, &dev, 0, 0); /* Correct count, wrong CPU IDs. */
    online_mask = 1; cpu_result(&cpu, &dev, 0, 0);
    online_mask = 7; cpu_result(&cpu, &dev, 0, 0);
    online_mask = 0; cpu_result(&cpu, &dev, 0, 0);
    online_mask = 3;
    cpu.readiness_mutex.locked = true; cpu_result(&cpu, &dev, EAGAIN, 0); cpu.readiness_mutex.locked = false;
    cpu_locked = true; cpu_result(&cpu, &dev, EAGAIN, 0); cpu_locked = false;
    dev.requested_online = 0; cpu_result(&cpu, &dev, EPROTO, 0);
    dev.requested_online = 5; cpu_result(&cpu, &dev, EPROTO, 0);
    dev.requested_online = 2; dev.possible = 0; cpu_result(&cpu, &dev, EPROTO, 0); dev.possible = 4;
    cpu.converge_work.pending_at = 1; cpu_result(&cpu, &dev, EAGAIN, 0);
    cpu.converge_work = (struct work_struct){.pending_at = 2}; cpu_result(&cpu, &dev, EAGAIN, 0);
    puts("memory/CPU state, pending-work, error and lock-cleanup checks passed");
    return 0;
}
