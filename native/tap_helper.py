#!/usr/bin/env python3

import argparse
import fcntl
import os
import queue
import select
import struct
import sys
import threading


TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000
# 这里和 Erlang port 约定使用 `{packet, 4}`，
# 也就是每个 frame 前面都带一个 4 字节的大端长度前缀。
FRAME_HEADER_SIZE = 4
MAX_FRAME_SIZE = 65535


def discard_stdout():
    # 当 BEAM 侧先关闭 port 后，Python 解释器退出时仍可能尝试 flush stdout，
    # 这时会抛 BrokenPipe。这里把 stdout 重定向到 `/dev/null`，避免退出时刷屏。
    devnull_fd = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull_fd, sys.stdout.fileno())
    os.close(devnull_fd)


def read_exact(stream, size):
    # 从流里精确读取 `size` 字节。
    # 如果中途遇到 EOF，就返回 None。
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(stream):
    # 按 `{packet, 4}` 协议从 stdin/stdout 里解出一帧。
    header = read_exact(stream, FRAME_HEADER_SIZE)
    if header is None:
        return None
    size = struct.unpack(">I", header)[0]
    if size > MAX_FRAME_SIZE:
        raise ValueError(f"frame too large: {size}")
    return read_exact(stream, size)


def write_frame(stream, payload):
    # 按 `{packet, 4}` 协议把一帧写到 Erlang port 对端。
    try:
        stream.write(struct.pack(">I", len(payload)))
        stream.write(payload)
        stream.flush()
        return True
    except BrokenPipeError:
        discard_stdout()
        return False


def open_tap(name):
    # 打开 `/dev/net/tun`，并通过 ioctl 申请一个 TAP 设备。
    # `IFF_NO_PI` 表示读写时不附带额外的 packet information 头，
    # 这样拿到的就是纯以太网帧。
    fd = os.open("/dev/net/tun", os.O_RDWR)
    request = struct.pack("16sH", name.encode(), IFF_TAP | IFF_NO_PI)
    response = fcntl.ioctl(fd, TUNSETIFF, request)
    actual_name = response[:16].split(b"\x00", 1)[0].decode()
    return fd, actual_name


def run_mock():
    # mock 模式不碰内核网络设备，只做一个简单回显：
    # 从 stdin 收一帧，就原样写回 stdout。
    # 这样可以先验证 Gleam/Erlang/Python 三层 framing 是否打通。
    while True:
        frame = read_frame(sys.stdin.buffer)
        if frame is None:
            return
        if not write_frame(sys.stdout.buffer, frame):
            return


def run_tap(name):
    # tap 模式负责在两种数据源之间做桥接：
    # - 一边是 Erlang port 传来的带长度前缀消息（stdin/stdout）
    # - 一边是真实 TAP fd 上的原始以太网帧
    tap_fd, actual_name = open_tap(name)
    outbound = queue.Queue()

    def stdin_to_tap():
        # stdin 的读取是阻塞的，所以放到单独线程里。
        # 主线程就可以持续 select TAP fd，把 TAP 上来的 frame 往外转发。
        while True:
            frame = read_frame(sys.stdin.buffer)
            if frame is None:
                outbound.put(None)
                return
            os.write(tap_fd, frame)

    reader = threading.Thread(target=stdin_to_tap, daemon=True)
    reader.start()

    try:
        while True:
            # 这里定期超时醒来，是为了顺便检查 stdin 线程是否已经结束。
            ready, _, _ = select.select([tap_fd], [], [], 0.2)
            if ready:
                frame = os.read(tap_fd, MAX_FRAME_SIZE)
                if frame:
                    if not write_frame(sys.stdout.buffer, frame):
                        return

            try:
                sentinel = outbound.get_nowait()
            except queue.Empty:
                sentinel = "continue"

            if sentinel is None:
                return
    finally:
        os.close(tap_fd)
        print(f"closed {actual_name}", file=sys.stderr)


def main():
    # `mock` 适合本地无权限 smoke test；
    # `tap` 需要 Linux 上存在 `/dev/net/tun`，通常还需要足够权限。
    parser = argparse.ArgumentParser(description="Minimal TAP helper for Gleam/Erlang ports")
    parser.add_argument("--mode", choices=["mock", "tap"], required=True)
    parser.add_argument("--name", default="tap0")
    args = parser.parse_args()

    if args.mode == "mock":
        run_mock()
    else:
        run_tap(args.name)


if __name__ == "__main__":
    main()
