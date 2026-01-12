import asyncio
import json
import threading
import socket
import os
import sys
import time
from io import BytesIO
import base64
import tkinter as tk

import pyautogui
import websockets
from mss import mss
from PIL import Image

try:
    import winreg
except ImportError:
    winreg = None


HOST = "0.0.0.0"
PORT = 8765

CONFIG_DIR_NAME = "VisualEyesPC"
CONFIG_FILE_NAME = "config.json"
RUN_KEY_PATH = r"Software\\Microsoft\\Windows\\CurrentVersion\\Run"
RUN_VALUE_NAME = "VisualEyesPC"

last_activity = time.time()
mode = "temporary"


def _get_config_path():
    base = os.getenv("APPDATA") or os.path.expanduser("~")
    path = os.path.join(base, CONFIG_DIR_NAME)
    os.makedirs(path, exist_ok=True)
    return os.path.join(path, CONFIG_FILE_NAME)


def load_mode():
    path = _get_config_path()
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("mode")
    except Exception:
        return None


def save_mode(value):
    path = _get_config_path()
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"mode": value}, f)
    except Exception:
        return


def set_startup(enabled):
    if winreg is None:
        return
    try:
        key = winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY_PATH)
        if enabled:
            if getattr(sys, "frozen", False):
                exe_path = sys.executable
            else:
                exe_path = os.path.abspath(__file__)
            winreg.SetValueEx(key, RUN_VALUE_NAME, 0, winreg.REG_SZ, f'"{exe_path}"')
        else:
            try:
                winreg.DeleteValue(key, RUN_VALUE_NAME)
            except FileNotFoundError:
                pass
        winreg.CloseKey(key)
    except Exception:
        return


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


async def handle_client(websocket):
    global last_activity
    last_activity = time.time()
    async for message in websocket:
        try:
            data = json.loads(message)
        except json.JSONDecodeError:
            continue

        last_activity = time.time()
        cmd_type = data.get("type")

        if cmd_type == "click":
            x = data.get("x")
            y = data.get("y")
            if x is not None and y is not None:
                pyautogui.click(x, y)

        elif cmd_type == "move":
            x = data.get("x")
            y = data.get("y")
            if x is not None and y is not None:
                pyautogui.moveTo(x, y)

        elif cmd_type == "type_text":
            text = data.get("text", "")
            pyautogui.typewrite(text)

        elif cmd_type == "key":
            key = data.get("key")
            if key:
                pyautogui.press(key)

        elif cmd_type == "screenshot":
            with mss() as sct:
                screenshot = sct.grab(sct.monitors[0])
                img = Image.frombytes("RGB", screenshot.size, screenshot.rgb)
                buf = BytesIO()
                img.save(buf, format="JPEG", quality=60)
                encoded = base64.b64encode(buf.getvalue()).decode("ascii")
                await websocket.send(json.dumps({"type": "screenshot", "data": encoded}))


async def main():
    async with websockets.serve(handle_client, HOST, PORT):
        print(f"Exam companion WebSocket server listening on ws://{HOST}:{PORT}")
        await asyncio.Future()  # run forever


def run_server():
    asyncio.run(main())


def start_inactivity_monitor():
    def monitor():
        while True:
            time.sleep(60)
            if mode == "temporary":
                if time.time() - last_activity > 7200:
                    os._exit(0)

    t = threading.Thread(target=monitor, daemon=True)
    t.start()


def run_gui():
    root = tk.Tk()
    root.title("VisualEyes PC Companion")

    def show_main():
        for child in root.winfo_children():
            child.destroy()
        ip = get_local_ip()
        url = f"ws://{ip}:{PORT}"
        label = tk.Label(root, text=f"Your PC address:\n{url}", font=("Segoe UI", 12))
        label.pack(padx=20, pady=10)
        info = tk.Label(
            root,
            text="Enter this address in VisualEyes PC mode on your phone.",
            wraplength=320,
        )
        info.pack(padx=20, pady=(0, 10))
        btn = tk.Button(root, text="Close", command=root.withdraw)
        btn.pack(pady=(0, 20))
        root.protocol("WM_DELETE_WINDOW", root.withdraw)

    def choose_mode(selected):
        global mode
        mode = selected
        save_mode(mode)
        set_startup(mode == "permanent")
        show_main()

    existing = load_mode()
    if existing:
        global mode
        mode = existing
        set_startup(mode == "permanent")
        show_main()
    else:
        prompt = tk.Label(
            root,
            text="How do you want to run VisualEyes PC companion?",
            wraplength=340,
            font=("Segoe UI", 11),
        )
        prompt.pack(padx=20, pady=10)
        perm_btn = tk.Button(
            root,
            text="Permanent (start with Windows)",
            command=lambda: choose_mode("permanent"),
        )
        perm_btn.pack(padx=20, pady=5)
        temp_btn = tk.Button(
            root,
            text="Temporary (this session only)",
            command=lambda: choose_mode("temporary"),
        )
        temp_btn.pack(padx=20, pady=(0, 15))

    root.mainloop()


if __name__ == "__main__":
    server_thread = threading.Thread(target=run_server, daemon=True)
    server_thread.start()
    start_inactivity_monitor()
    run_gui()
