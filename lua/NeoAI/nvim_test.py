#!/usr/bin/env python3
"""
nvim_render_test.py
====================
启动一个真实的 nvim 进程，按脚本描述依次发送按键 / 命令，
等待指定时间后把当前屏幕内容（含真彩色高亮）抓取出来，
保存为可直接 `cat` 查看的 ANSI 彩色文本文件。

用法示例
--------
    # 1) 生成示例配置文件
    python3 nvim_render_test.py --create-example

    # 2) 运行测试
    python3 nvim_render_test.py --config basic_test.yaml

    # 3) 输出纯文本（不带颜色）
    python3 nvim_render_test.py --config basic_test.yaml --no-color
"""

import os
import sys
import time
import json
import subprocess
import argparse
import shlex
from pathlib import Path
from typing import List, Tuple, Optional

# ---------- 颜色工具 ----------

def rgb_to_ansi_fg(r, g, b):
    return f"\x1b[38;2;{r};{g};{b}m"

def rgb_to_ansi_bg(r, g, b):
    return f"\x1b[48;2;{r};{g};{b}m"

ANSI_RESET = "\x1b[0m"
ANSI_BOLD = "\x1b[1m"
ANSI_ITALIC = "\x1b[3m"
ANSI_UNDERLINE = "\x1b[4m"
ANSI_REVERSE = "\x1b[7m"

# ---------- 核心类 ----------

class NvimTester:
    """封装 nvim 进程的启动、按键发送与屏幕抓取。"""

    def __init__(self, nvim_cmd: str = "nvim", timeout: float = 10.0):
        self.nvim_cmd = nvim_cmd
        self.timeout = timeout
        self.proc = None
        self._next_msgid = 1
        self._unpacker = None

    # ---- 进程管理 ----

    def start(self, extra_args: List[str] = None):
        """以 --embed 模式启动 nvim。"""
        cmd = [self.nvim_cmd, "--embed", "--headless", "-n"]
        if extra_args:
            cmd.extend(extra_args)
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # 握手：发送 nvim_get_api_info
        self._send_msg("nvim_get_api_info", [])
        resp = self._recv_msg()
        if resp["error"] is not None:
            raise RuntimeError(f"nvim 握手失败: {resp['error']}")
        self._channel_id = resp["result"][0]
        print(f"[*] nvim 已启动, channel_id={self._channel_id}")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self._send_msg("nvim_command", ["qa!"])
                time.sleep(0.3)
            except Exception:
                pass
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        print("[*] nvim 已退出")

    # ---- 消息协议 (简化版 msgpack-rpc over stdio) ----

    def _send_msg(self, method: str, args: list):
        """发送一个 msgpack-rpc 请求。"""
        import msgpack
        msgid = self._next_msgid
        self._next_msgid += 1
        # [type=0(request), msgid, method, args]
        payload = msgpack.packb([0, msgid, method, args])
        self.proc.stdin.write(payload)
        self.proc.stdin.flush()
        return msgid

    def _recv_msg(self, expected_id: Optional[int] = None):
        import msgpack
        import fcntl
        # 将 stdout 设为非阻塞：nvim 的消息是小的 msgpack 流，
        # 阻塞式 read(65536) 会一直等待 EOF，导致握手永久挂起。
        fd = self.proc.stdout.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        # 使用持久化 unpacker，跨调用保留未消费的缓冲字节
        if self._unpacker is None:
            self._unpacker = msgpack.Unpacker(raw=False)
        while True:
            try:
                msg = self._unpacker.unpack()
                if msg[0] == 1:  # response: [type, msgid, error, result]
                    if expected_id is None or msg[1] == expected_id:
                        return {"result": msg[3], "error": msg[2]}
                elif msg[0] == 2:  # notification
                    # 忽略通知（如红raw）
                    continue
            except msgpack.OutOfData:
                # 非阻塞读取当前可用的字节并喂给 unpacker
                try:
                    data = os.read(fd, 65536)
                except BlockingIOError:
                    data = b""
                if data:
                    self._unpacker.feed(data)
                    continue
                if self.proc.poll() is not None:
                    raise RuntimeError("nvim 进程意外退出")
                # 等待更多数据
                time.sleep(0.05)

    def _call(self, method: str, args: list):
        mid = self._send_msg(method, args)
        resp = self._recv_msg(mid)
        if resp["error"] is not None:
            raise RuntimeError(f"RPC 错误 {method}: {resp['error']}")
        return resp["result"]

    # ---- 高级操作 ----

    def ui_attach(self, width: int = 120, height: int = 40):
        """附加一个 UI 后端，让 nvim 认为有一个终端在显示。"""
        self._call("nvim_ui_attach", [
            width, height,
            {
                "rgb": True,
                "ext_cmdline": False,
                "ext_popupmenu": False,
                "ext_tabline": False,
                "ext_wildmenu": False,
                "ext_linegrid": True,
                "ext_hlstate": False,
                "ext_termcolors": True,
            }
        ])
        print(f"[*] UI 已附加 ({width}x{height})")

    def set_option(self, name: str, value):
        self._call("nvim_set_option", [name, value])

    def command(self, cmd: str):
        self._call("nvim_command", [cmd])

    def feedkeys(self, keys: str, mode: str = "t", escape: bool = False):
        """模拟真实按键输入（自动展开 <C-s> 等键名）。"""
        decoded = self._call("nvim_exec_lua", [
            "return vim.api.nvim_replace_termcodes((...), true, false, true)",
            [keys],
        ])
        self._call("nvim_feedkeys", [decoded, mode, escape])

    def input(self, keys: str):
        """直接输入文本（不经过映射）。"""
        self._call("nvim_input", [keys])

    def sleep(self, seconds: float):
        time.sleep(seconds)

    def redraw(self):
        """强制 nvim 刷新 UI。"""
        self.command("redraw!")

    def get_screen_dump_lua(self) -> str:
        """
        通过内嵌 Lua 获取屏幕内容。
        返回 nvim 当前屏幕上每个单元格的 (char, hl_group_id) 列表。
        """
        lua_code = r"""
        local lines = {}
        local width = vim.api.nvim_get_option('columns')
        local height = vim.api.nvim_get_option('lines')
        for row = 1, height do
            local line_parts = {}
            for col = 1, width do
                local ch = vim.fn.screenstring(row, col)
                if ch == '' then ch = ' ' end
                table.insert(line_parts, ch)
            end
            table.insert(lines, table.concat(line_parts))
        end
        return lines
        """
        return self._call("nvim_exec_lua", [lua_code, []])

    def get_screen_attrs_lua(self) -> list:
        """
        获取屏幕上每个单元格的属性 ID。
        """
        lua_code = r"""
        local attrs = {}
        local width = vim.api.nvim_get_option('columns')
        local height = vim.api.nvim_get_option('lines')
        for row = 1, height do
            local row_attrs = {}
            for col = 1, width do
                local attr_id = vim.fn.screenattr(row, col)
                table.insert(row_attrs, attr_id)
            end
            table.insert(attrs, row_attrs)
        end
        return attrs
        """
        return self._call("nvim_exec_lua", [lua_code, []])

    def get_hl_info_lua(self) -> dict:
        """
        获取所有高亮组的详细信息（名称 -> 属性）。
        """
        lua_code = r"""
        local hls = {}
        local hl_list = vim.fn.getcompletion('', 'highlight')
        for _, name in ipairs(hl_list) do
            local id = vim.fn.hlID(name)
            if id > 0 then
                local ok, attrs = pcall(vim.api.nvim_get_hl_by_id, id, true)
                if ok then
                    hls[tostring(id)] = {
                        name = name,
                        attrs = attrs
                    }
                end
            end
        end
        return hls
        """
        return self._call("nvim_exec_lua", [lua_code, []])

    def get_cursor_pos(self) -> Tuple[int, int]:
        row = self._call("nvim_get_option", ["row"])
        col = self._call("nvim_get_option", ["col"])
        return row, col

    def get_mode(self) -> str:
        return self._call("nvim_get_mode", [])["mode"]


# ---------- 屏幕渲染 ----------

def render_screen_to_ansi(
    screen_lines: List[str],
    screen_attrs: List[List[int]],
    hl_info: dict,
    use_color: bool = True,
) -> str:
    """
    将 nvim 屏幕数据渲染为带 ANSI 转义序列的文本。
    """
    output = []
    height = len(screen_lines)
    width = max(len(l) for l in screen_lines) if screen_lines else 0

    for row_idx in range(height):
        line = screen_lines[row_idx]
        attrs_row = screen_attrs[row_idx] if row_idx < len(screen_attrs) else []
        # 补齐到统一宽度
        line = line.ljust(width)

        if not use_color:
            output.append(line)
            continue

        # 逐字符输出，属性变化时切换 ANSI
        last_attr_id = None
        for col_idx in range(width):
            ch = line[col_idx] if col_idx < len(line) else ' '
            attr_id = attrs_row[col_idx] if col_idx < len(attrs_row) else 0

            if attr_id != last_attr_id:
                last_attr_id = attr_id
                ansi_parts = [ANSI_RESET]
                if attr_id > 0:
                    hl = hl_info.get(str(attr_id))
                    if hl and hl.get("attrs"):
                        a = hl["attrs"]
                        # 前景色
                        if a.get("foreground") is not None:
                            fg = a["foreground"]
                            ansi_parts.append(rgb_to_ansi_fg(
                                (fg >> 16) & 0xFF,
                                (fg >> 8) & 0xFF,
                                fg & 0xFF
                            ))
                        # 背景色
                        if a.get("background") is not None:
                            bg = a["background"]
                            ansi_parts.append(rgb_to_ansi_bg(
                                (bg >> 16) & 0xFF,
                                (bg >> 8) & 0xFF,
                                bg & 0xFF
                            ))
                        # 文字样式
                        if a.get("bold"):
                            ansi_parts.append(ANSI_BOLD)
                        if a.get("italic"):
                            ansi_parts.append(ANSI_ITALIC)
                        if a.get("underline"):
                            ansi_parts.append(ANSI_UNDERLINE)
                        if a.get("reverse"):
                            ansi_parts.append(ANSI_REVERSE)
                output.append("".join(ansi_parts))

            output.append(ch)

        output.append(ANSI_RESET + "\n")

    return "".join(output)


def render_screen_plain(screen_lines: List[str]) -> str:
    """纯文本渲染（无颜色），去除尾部空白。"""
    return "\n".join(line.rstrip() for line in screen_lines) + "\n"


# ---------- 配置解析 ----------

def load_config(config_path: str) -> dict:
    """加载 YAML 或 JSON 配置文件。"""
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"配置文件不存在: {config_path}")

    text = path.read_text()
    if path.suffix in (".yml", ".yaml"):
        try:
            import yaml
            return yaml.safe_load(text)
        except ImportError:
            # 没有 PyYAML 时尝试用 JSON
            print("[!] 未安装 PyYAML，尝试按 JSON 解析")
            return json.loads(text)
    else:
        return json.loads(text)


def execute_steps(tester: NvimTester, steps: list):
    """按顺序执行测试步骤。"""
    for i, step in enumerate(steps):
        step_type = step.get("type", "keys")
        desc = step.get("description", f"步骤 {i+1}")

        if step_type == "keys":
            keys = step.get("keys", "")
            mode = step.get("mode", "t")
            print(f"  [{i+1}] {desc}: feedkeys({shlex.quote(keys)})")
            tester.feedkeys(keys, mode, False)

        elif step_type == "input":
            text = step.get("text", "")
            print(f"  [{i+1}] {desc}: input({shlex.quote(text)})")
            tester.input(text)

        elif step_type == "command":
            cmd = step.get("cmd", "")
            print(f"  [{i+1}] {desc}: :{cmd}")
            tester.command(cmd)

        elif step_type == "sleep":
            secs = float(step.get("seconds", 0.5))
            print(f"  [{i+1}] {desc}: sleep({secs}s)")
            tester.sleep(secs)

        elif step_type == "redraw":
            print(f"  [{i+1}] {desc}: redraw")
            tester.redraw()

        elif step_type == "wait_for_mode":
            target = step.get("mode", "n")
            timeout = float(step.get("timeout", 5.0))
            print(f"  [{i+1}] {desc}: wait_for_mode({target})")
            start = time.time()
            while time.time() - start < timeout:
                if tester.get_mode() == target:
                    break
                time.sleep(0.05)

        else:
            print(f"  [{i+1}] 未知步骤类型: {step_type}, 跳过")

        # 每个步骤后可选的短暂等待
        post_wait = step.get("post_wait", 0.1)
        if post_wait > 0:
            tester.sleep(post_wait)


# ---------- 主流程 ----------

def create_example_config(path: str):
    """生成示例配置文件。"""
    example = {
        "name": "基础测试",
        "description": "打开文件、输入文本、执行命令、抓取渲染",
        "nvim_args": ["--clean"],
        "width": 80,
        "height": 30,
        "output": "render_basic.txt",
        "steps": [
            {"type": "command", "cmd": "enew", "description": "新建缓冲区"},
            {"type": "sleep", "seconds": 0.3},
            {"type": "input", "text": "# Hello Neovim Render Test\n", "description": "输入标题"},
            {"type": "input", "text": "def fibonacci(n):\n", "description": "输入函数定义"},
            {"type": "input", "text": "    if n <= 1:\n", "description": "输入条件"},
            {"type": "input", "text": "        return n\n", "description": "输入返回值"},
            {"type": "input", "text": "    return fibonacci(n-1) + fibonacci(n-2)\n", "description": "输入递归"},
            {"type": "input", "text": "\n", "description": "空行"},
            {"type": "input", "text": "print(fibonacci(10))\n", "description": "输入调用"},
            {"type": "sleep", "seconds": 0.5, "description": "等待渲染"},
            {"type": "command", "cmd": "syntax on", "description": "开启语法高亮"},
            {"type": "sleep", "seconds": 0.3},
            {"type": "command", "cmd": "colorscheme desert", "description": "切换配色"},
            {"type": "sleep", "seconds": 0.5},
            {"type": "keys", "keys": "gg", "description": "回到文件顶部"},
            {"type": "sleep", "seconds": 0.3},
            {"type": "keys", "keys": "V", "description": "进入行可视模式"},
            {"type": "keys", "keys": "j", "description": "选中下一行"},
            {"type": "sleep", "seconds": 0.5},
        ]
    }
    Path(path).write_text(json.dumps(example, indent=2, ensure_ascii=False))
    print(f"[*] 示例配置已生成: {path}")


def main():
    parser = argparse.ArgumentParser(
        description="Neovim TUI 渲染测试工具 — 发送按键、等待、抓取屏幕"
    )
    parser.add_argument("--config", "-c", help="测试配置文件 (YAML/JSON)")
    parser.add_argument("--create-example", "-e", help="生成示例配置文件并退出")
    parser.add_argument("--output", "-o", help="输出文件路径（覆盖配置中的设置）")
    parser.add_argument("--no-color", action="store_true", help="输出纯文本（不带 ANSI 颜色）")
    parser.add_argument("--nvim", default="nvim", help="nvim 可执行文件路径 (默认: nvim)")
    parser.add_argument("--width", type=int, default=80, help="模拟终端宽度 (默认: 80)")
    parser.add_argument("--height", type=int, default=30, help="模拟终端高度 (默认: 30)")
    args = parser.parse_args()

    if args.create_example:
        create_example_config(args.create_example)
        return

    if not args.config:
        parser.print_help()
        print("\n提示: 使用 --create-example 生成示例配置文件")
        sys.exit(1)

    config = load_config(args.config)

    width = args.width or config.get("width", 80)
    height = args.height or config.get("height", 30)
    output_path = args.output or config.get("output", "nvim_render.txt")
    use_color = not args.no_color
    nvim_args = config.get("nvim_args", [])

    print(f"[*] 测试名称: {config.get('name', '未命名')}")
    print(f"[*] 描述: {config.get('description', '无')}")
    print(f"[*] 输出文件: {output_path}")
    print(f"[*] 颜色模式: {'ANSI真彩色' if use_color else '纯文本'}")
    print()

    tester = NvimTester(nvim_cmd=args.nvim)

    try:
        tester.start(extra_args=nvim_args)
        tester.ui_attach(width, height)

        # 执行步骤
        steps = config.get("steps", [])
        execute_steps(tester, steps)

        # 最终等待，确保渲染完成
        tester.sleep(config.get("final_wait", 0.5))
        tester.redraw()
        tester.sleep(0.3)

        # 抓取屏幕
        print("\n[*] 抓取屏幕内容...")
        screen_lines = tester.get_screen_dump_lua()
        screen_attrs = tester.get_screen_attrs_lua()
        hl_info = tester.get_hl_info_lua() if use_color else {}

        # 渲染
        if use_color:
            rendered = render_screen_to_ansi(
                screen_lines, screen_attrs, hl_info, use_color=True
            )
        else:
            rendered = render_screen_plain(screen_lines)

        # 保存
        Path(output_path).write_text(rendered)
        print(f"[✓] 渲染已保存到: {output_path}")
        print(f"    行数: {len(screen_lines)}, 列数: {max(len(l) for l in screen_lines)}")

        # 打印预览
        print("\n" + "=" * 60)
        print("预览 (前20行):")
        print("=" * 60)
        preview_lines = rendered.split("\n")[:20]
        print("\n".join(preview_lines))
        print("=" * 60)
        print(f"\n查看完整结果: cat {output_path}")

    except Exception as e:
        print(f"\n[✗] 错误: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        tester.stop()


if __name__ == "__main__":
    main()


