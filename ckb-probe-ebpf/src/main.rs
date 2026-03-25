// Placeholder — Week 3 will implement:
//   1. rocksdb_get_pinned_cf uprobe/uretprobe latency measurement
//   2. Multi-function RocksDB uprobe
//   3. tcp_sendmsg kprobe peer IP:Port extraction
//   4. sys_enter raw tracepoint syscall Top-N

fn main() {
    // This crate targets bpfel-unknown-none and uses #![no_std] + #![no_main].
    // The real entry points are BPF program sections (uprobe, kprobe, etc.).
    // This file will be replaced entirely in Week 3.
    panic!("This is a BPF program stub. Build with bpf target.");
}
