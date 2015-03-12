# Introduction #
Lab 4 is about memory management. Specifically pages. Part I deals with reporting memory management statistics. Part II deals with replacing the page replacement algorithm.


# Part I #
We decided to call the directory that contains our system call 'rum', since that's the name of our group. We called the function itself mem\_stats, and it returns an int pointer, which in turn has 7 values, each corresponding to those required in the lab.

Also added rum/ to the core-y          += kernel/ mm/ fs/ ipc/ security/ crypto/ block/
line in the Makefile in the top level of the kernel, line 555. Then added a Makefile to the rum/ directory with the following contents:

`obj-y   := mem_stats.o`

Then we added the following lines to include/asm-x86-64/unistd.h:

`#define __NR_mem_stats          280`

`__SYSCALL(__NR_mem_stats, sys_mem_stats)`

In order to get the statistics from memory, we investigated `get_zone_counts` and `__get_zone_counts` in mm/vmstat.c, line 17 and 33, respectively; these functions get the number of active, inactive, and free pages from each zone. This in turn led us to the zone struct, which is locate in include/linux/mmzone.h, line 139. The `get_zone_counts` function uses

```

for_each_online_pgdat(pgdat){
	unsigned long l, m, n;
	__get_zone_counts(&l, &m, &n, pgdat);
	*active += l;
	*inactive += m;
	*free += n;
} 

```

to iterate through the zones of each pgdat, using:

```
void __get_zone_counts(unsigned long *active, unsigned long *inactive,
			unsigned long *free, struct pglist_data *pgdat)
{
	struct zone *zones = pgdat->node_zones;
	int i;

	*active = 0;
	*inactive = 0;
	*free = 0;
	for (i = 0; i < MAX_NR_ZONES; i++) {
		*active += zones[i].nr_active;
		*inactive += zones[i].nr_inactive;
		*free += zones[i].free_pages;
	}
}
```

I adopted the code from that function to:

```
#include <linux/slab.h>
#include <asm/uaccess.h>
#include <linux/config.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/cpu.h>
#include <linux/mmzone.h>

/*This is the file that will
contain the code for the system
call needed for part I, which reports
the following statistics to a user level
application:
1. current number of pages in active list over all memory zones
2. current number of pages in inactive list over all memory zone
3. current number of pages in the active list whose reference bits
	are set over all memory zones
4. current number of pages in inactive list whose ref bits are set
5. cumulative number of pages moved from the active list to the
	inactive list since the last machine boot.
6. cumulative number of pages evicted from the inactive list since last boot
7. a list of the number of pages allocated to all active processes.
*/

void __mem_stats(unsigned long *stats, struct pglist_data *pgdat)
{
	struct zone *zones = pgdat->node_zones;
	int i;

	stats[0] = 0;
	stats[1] = 0;
	stats[5] = 0;
	for (i = 0; i < MAX_NR_ZONES; i++) {
		stats[0] += zones[i].nr_active;
		stats[1] += zones[i].nr_inactive;
		stats[5] += zones[i].free_pages;
	}
}


asmlinkage int sys_mem_stats(void __user *to, void __user *from, int n)
{
	struct pglist_data *pgdat;
	// stats is the data to be returned, tempStats is for 
	unsigned long *stats, *tempStats;
	stats = kmalloc(sizeof(unsigned long)*7,GFP_KERNEL);
	tempStats = kmalloc(sizeof(unsigned long)*7,GFP_KERNEL);
	
	// initialize counts to zero
	// stats[0] is the active pages
	// stats[1] is the inactive pages
	// stats[6] is inactive + active
	stats[0] = 0;
	stats[1] = 0;
	stats[6] = 0;
	
	// iterate through higher level memory zones,
	// (if they exist)
	for_each_online_pgdat(pgdat) {
		// __mem_stats looks at each zone, and
		// counts the number of acive and inactive
		// frames
		__mem_stats(tempStats, pgdat);
		
		stats[0] += tempStats[0];
		stats[1] += tempStats[1];
		stats[6] += tempStats[0] + tempStats[1];
	}

	kfree(tempStats);
	copy_to_user((void *)to, (void *)stats, sizeof(unsigned long)*7);
	//to = stats;
	return 0;
}

}
```

This code should work fine, with the following as test code:

```
#define SYS_MEM_STATS 280
#include <stdio.h>
#include <malloc.h>

int main()
{
	// out will be what's returned
	int n = 0;
	unsigned long *out = malloc(sizeof(unsigned long) * 7);
	unsigned long *in;
	printf("%ld\n", out[0]);
	syscall(SYS_MEM_STATS, out, in, sizeof(unsigned long) * 7);
	printf("%ld\n", out[0]);
	printf("%ld\n", out[1]);
	free(out);
	return 0;
}
```

This doesn't seem to do anything (values are zero after the system call), for perhaps several reasons:
**Swap space isn't created anywhere** The call to `copy_to_user` may not be functioning correctly

# Part II #

Scanning code for reference count:

Within shrink\_active\_list, it isolates all of LRU pages to a holding list. It loops through the list. For each page, there's a reference count. For each page that's referenced, our code increments ref\_count, which holds the reference count for the page. The function called page\_referenced will check if the reference bit flag of the page is set, and if it is, it adds it to the reference count. Then, after that, it removes the page from the zone's active list. It'll check if the page is mapped, and if so, it does another check to reclaim.

These changes are implemented with the following patch:

```
diff --git a/include/linux/mm.h b/include/linux/mm.h
index f0b135c..92dd9b8 100644
--- a/include/linux/mm.h
+++ b/include/linux/mm.h
@@ -267,6 +267,7 @@ struct page {
 	void *virtual;			/* Kernel virtual address (NULL if
 					   not kmapped, ie. highmem) */
 #endif /* WANT_PAGE_VIRTUAL */
+	unsigned long ref_count;
 };
 
 #define page_private(page)		((page)->private)
diff --git a/mm/vmscan.c b/mm/vmscan.c
index a04fb41..ff45578 100644
--- a/mm/vmscan.c
+++ b/mm/vmscan.c
@@ -793,11 +793,18 @@ static void shrink_active_list(unsigned long nr_pages, struct zone *zone,
 	while (!list_empty(&l_hold)) {
 		cond_resched();
 		page = lru_to_page(&l_hold);
+		if (page->ref_count >= sizeof(unsigned long)) {
+			page->ref_count += page_referenced(page, 0);
+		}
+		else if (page->ref_count < 0) {
+			page->ref_count = 0;
+		}
 		list_del(&page->lru);
 		if (page_mapped(page)) {
 			if (!reclaim_mapped ||
 			    (total_swap_pages == 0 && PageAnon(page)) ||
-			    page_referenced(page, 0)) {
+			    (page->ref_count > 0)) {
+				page->ref_count--;
 				list_add(&page->lru, &l_active);
 				continue;
 			}
```