cmd_kernel/irq/built-in.o :=  ld  -m elf_i386  -r -o kernel/irq/built-in.o kernel/irq/handle.o kernel/irq/manage.o kernel/irq/spurious.o kernel/irq/resend.o kernel/irq/chip.o kernel/irq/proc.o
