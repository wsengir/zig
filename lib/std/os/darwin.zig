const std = @import("std");
const log = std.log;
const mem = std.mem;
const os = @This();

pub usingnamespace @import("../c.zig");

pub fn vmWrite(
    task: os.mach_port_name_t,
    address: u64,
    buf: []const u8,
    arch: std.Target.Cpu.Arch,
) !usize {
    const count = buf.len;
    var total_written: usize = 0;
    var curr_addr = address;
    const page_size = try pageSize(task);
    var out_buf = buf[0..];

    while (total_written < count) {
        const curr_size = maxBytesLeftInPage(page_size, curr_addr, count - total_written);
        var kern_res = os.mach_vm_write(
            task,
            curr_addr,
            @ptrToInt(out_buf.ptr),
            @intCast(os.mach_msg_type_number_t, curr_size),
        );
        if (kern_res != 0) {
            log.err("mach_vm_write failed with error: {d}", .{kern_res});
            return error.MachVmWriteFailed;
        }

        switch (arch) {
            .aarch64 => {
                var mattr_value: os.vm_machine_attribute_val_t = os.MATTR_VAL_CACHE_FLUSH;
                kern_res = os.vm_machine_attribute(task, curr_addr, curr_size, os.MATTR_CACHE, &mattr_value);
                if (kern_res != 0) {
                    log.err("vm_machine_attribute failed with error: {d}", .{kern_res});
                    return error.VmMachineAttributeFailed;
                }
            },
            .x86_64 => {},
            else => unreachable,
        }

        out_buf = out_buf[curr_size..];
        total_written += curr_size;
        curr_addr += curr_size;
    }

    return total_written;
}

pub fn vmRead(task: os.mach_port_name_t, address: u64, buf: []u8) ![]u8 {
    const count = buf.len;
    var total_read: usize = 0;
    var curr_addr = address;
    const page_size = try pageSize(task);
    var out_buf = buf[0..];

    while (total_read < count) {
        const curr_size = maxBytesLeftInPage(page_size, curr_addr, count - total_read);
        var curr_bytes_read: os.mach_msg_type_number_t = 0;
        var vm_memory: os.vm_offset_t = undefined;
        var kern_res = os.mach_vm_read(task, curr_addr, curr_size, &vm_memory, &curr_bytes_read);
        if (kern_res != 0) {
            log.err("mach_vm_read failed with error: {d}", .{kern_res});
            return error.MachVmReadFailed;
        }

        @memcpy(out_buf[0..].ptr, @intToPtr([*]const u8, vm_memory), curr_bytes_read);
        kern_res = os.vm_deallocate(os.mach_task_self(), vm_memory, curr_bytes_read);
        if (kern_res != 0) {
            log.err("vm_deallocate failed with error: {d}", .{kern_res});
        }

        out_buf = out_buf[curr_bytes_read..];
        curr_addr += curr_bytes_read;
        total_read += curr_bytes_read;
    }

    return buf[0..total_read];
}

pub fn maxBytesLeftInPage(page_size: usize, address: u64, count: usize) usize {
    var left = count;
    if (page_size > 0) {
        const page_offset = address % page_size;
        const bytes_left_in_page = page_size - page_offset;
        if (count > bytes_left_in_page) {
            left = bytes_left_in_page;
        }
    }
    return left;
}

pub fn pageSize(task: os.mach_port_name_t) !usize {
    if (task != 0) {
        var info_count = os.TASK_VM_INFO_COUNT;
        var vm_info: os.task_vm_info_data_t = undefined;
        const kern_res = os.task_info(task, os.TASK_VM_INFO, @ptrCast(os.task_info_t, &vm_info), &info_count);
        if (kern_res != 0) {
            log.err("task_info failed with error: {d}", .{kern_res});
        } else {
            log.info("page_size = {x}", .{vm_info.page_size});
            return @intCast(usize, vm_info.page_size);
        }
    }
    var page_size: os.vm_size_t = undefined;
    const kern_res = os._host_page_size(os.mach_host_self(), &page_size);
    if (kern_res != 0) {
        log.err("_host_page_size failed with error: {d}", .{kern_res});
    }
    return page_size;
}
