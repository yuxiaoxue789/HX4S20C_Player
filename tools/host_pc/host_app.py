import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import serial
from serial.tools import list_ports
from PIL import Image, ImageOps


WIDTH = 640
HEIGHT = 480
IMAGE_BYTES = WIDTH * HEIGHT * 3
PACKET_PREFIX = b"\xA5"


class PlayerHostApp:
    def __init__(self, root):
        self.root = root
        self.root.title("HX4S20C Player 上位机")
        self.root.geometry("560x440")
        self.serial_port = None
        self.serial_lock = threading.Lock()
        self.events = queue.Queue()
        self.uploading = False

        self.port_name = tk.StringVar()
        self.status = tk.StringVar(value="未连接")
        self.brightness = tk.IntVar(value=128)
        self.contrast = tk.IntVar(value=128)
        self.saturation = tk.IntVar(value=255)
        self.subtitle = tk.StringVar()

        self._build_ui()
        self.refresh_ports()
        self.root.after(100, self._drain_events)
        self.root.protocol("WM_DELETE_WINDOW", self.close)

    def _build_ui(self):
        connection = ttk.LabelFrame(self.root, text="串口连接")
        connection.pack(fill="x", padx=12, pady=10)
        self.port_box = ttk.Combobox(connection, textvariable=self.port_name, width=16)
        self.port_box.pack(side="left", padx=8, pady=8)
        ttk.Button(connection, text="刷新", command=self.refresh_ports).pack(side="left", padx=4)
        self.connect_button = ttk.Button(connection, text="连接", command=self.toggle_connection)
        self.connect_button.pack(side="left", padx=4)
        ttk.Label(connection, textvariable=self.status).pack(side="left", padx=12)

        controls = ttk.LabelFrame(self.root, text="播放器控制")
        controls.pack(fill="x", padx=12, pady=6)
        ttk.Button(controls, text="下一张", command=lambda: self.send_command(0x01)).pack(
            side="left", padx=8, pady=8
        )
        ttk.Button(controls, text="自动轮播 开/关", command=lambda: self.send_command(0x02)).pack(
            side="left", padx=8, pady=8
        )
        ttk.Button(controls, text="参数面板", command=lambda: self.send_command(0x03)).pack(
            side="left", padx=8, pady=8
        )

        parameters = ttk.LabelFrame(self.root, text="图像参数")
        parameters.pack(fill="x", padx=12, pady=6)
        self._add_slider(parameters, "亮度", self.brightness, 0x10)
        self._add_slider(parameters, "对比度", self.contrast, 0x11)
        self._add_slider(parameters, "饱和度", self.saturation, 0x12)

        image_frame = ttk.LabelFrame(self.root, text="图像上传")
        image_frame.pack(fill="x", padx=12, pady=6)
        ttk.Button(image_frame, text="选择图片并上传", command=self.choose_image).pack(
            side="left", padx=8, pady=8
        )
        ttk.Label(
            image_frame,
            text="自动适配 640×480；上传后显示在屏幕，不写入 TF 卡",
        ).pack(side="left", padx=6)

        subtitle_frame = ttk.LabelFrame(self.root, text="字幕")
        subtitle_frame.pack(fill="x", padx=12, pady=6)
        ttk.Entry(subtitle_frame, textvariable=self.subtitle).pack(
            side="left", fill="x", expand=True, padx=8, pady=8
        )
        ttk.Button(subtitle_frame, text="发送", command=self.send_subtitle).pack(
            side="left", padx=8
        )

        ttk.Label(
            self.root,
            text="USB-UART：115200 baud / 8N1。上传期间请勿断开串口或复位开发板。",
            foreground="#555555",
        ).pack(anchor="w", padx=14, pady=6)

    def _add_slider(self, parent, label, variable, opcode):
        row = ttk.Frame(parent)
        row.pack(fill="x", padx=8, pady=3)
        ttk.Label(row, text=label, width=8).pack(side="left")
        slider = ttk.Scale(
            row,
            from_=0,
            to=255,
            variable=variable,
            command=lambda value: self._send_parameter(opcode, value),
        )
        slider.pack(side="left", fill="x", expand=True, padx=8)
        ttk.Label(row, textvariable=variable, width=4).pack(side="left")

    def refresh_ports(self):
        ports = [port.device for port in list_ports.comports()]
        self.port_box["values"] = ports
        if ports and self.port_name.get() not in ports:
            self.port_name.set(ports[0])

    def toggle_connection(self):
        if self.serial_port and self.serial_port.is_open:
            self.close_serial()
            return
        name = self.port_name.get().strip()
        if not name:
            messagebox.showwarning("串口", "请选择串口。")
            return
        try:
            self.serial_port = serial.Serial(
                name,
                baudrate=115200,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=1,
                write_timeout=5,
            )
        except serial.SerialException as exc:
            messagebox.showerror("连接失败", str(exc))
            return
        self.status.set(f"已连接 {name}")
        self.connect_button.configure(text="断开")

    def close_serial(self):
        if self.serial_port:
            self.serial_port.close()
            self.serial_port = None
        self.status.set("未连接")
        self.connect_button.configure(text="连接")

    def _write(self, data):
        if not self.serial_port or not self.serial_port.is_open:
            self.status.set("请先连接串口")
            return False
        try:
            with self.serial_lock:
                written = self.serial_port.write(data)
            if written != len(data):
                raise serial.SerialTimeoutException("串口指令未能完整发送")
            return True
        except serial.SerialException as exc:
            self.status.set(f"串口错误：{exc}")
            return False

    def send_command(self, opcode, value=None):
        if self.uploading:
            return
        payload = PACKET_PREFIX + bytes((opcode,))
        if value is not None:
            payload += bytes((value,))
        self._write(payload)

    def _send_parameter(self, opcode, value):
        if self.uploading:
            return
        self.send_command(opcode, max(0, min(255, int(float(value)))))

    def send_subtitle(self):
        text = self.subtitle.get()[:32]
        try:
            data = text.encode("ascii", errors="replace") + b"\r\n"
        except UnicodeEncodeError:
            return
        self._write(data)

    @staticmethod
    def prepare_image(path):
        with Image.open(path) as source:
            rgb = source.convert("RGB")
            fitted = ImageOps.contain(
                rgb,
                (WIDTH, HEIGHT),
                method=Image.Resampling.LANCZOS,
            )
            canvas = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
            canvas.paste(
                fitted,
                ((WIDTH - fitted.width) // 2, (HEIGHT - fitted.height) // 2),
            )
            return canvas.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes()

    def choose_image(self):
        if self.uploading:
            return
        if not self.serial_port or not self.serial_port.is_open:
            messagebox.showwarning("图像上传", "请先连接开发板的 USB-UART 串口。")
            return
        path = filedialog.askopenfilename(
            title="选择待显示的图片",
            filetypes=[
                ("图片文件", "*.png *.jpg *.jpeg *.bmp *.webp *.gif"),
                ("所有文件", "*.*"),
            ],
        )
        if not path:
            return
        try:
            frame = self.prepare_image(path)
        except (OSError, ValueError) as exc:
            messagebox.showerror("图片读取失败", str(exc))
            return
        if len(frame) != IMAGE_BYTES:
            messagebox.showerror("图片错误", "转换后的图像数据长度异常。")
            return
        if not messagebox.askokcancel(
            "上传确认",
            "请确认屏幕已稳定显示图片，且自动轮播已关闭。\n"
            "上传期间不要断开串口或复位开发板。",
        ):
            return
        self.uploading = True
        self.connect_button.configure(state="disabled")
        self.status.set("准备上传...")
        threading.Thread(
            target=self._upload_worker,
            args=(frame,),
            daemon=True,
        ).start()

    def _upload_worker(self, frame):
        try:
            with self.serial_lock:
                command = PACKET_PREFIX + b"\x20"
                if self.serial_port.write(command) != len(command):
                    raise serial.SerialTimeoutException("图像上传指令未能完整发送")
                chunk_size = 4096
                for offset in range(0, len(frame), chunk_size):
                    chunk = frame[offset:offset + chunk_size]
                    if self.serial_port.write(chunk) != len(chunk):
                        raise serial.SerialTimeoutException("图像数据未能完整发送")
                    percent = min(100, (offset + chunk_size) * 100 // len(frame))
                    self.events.put(("progress", percent))
            self.events.put(("complete", None))
        except (serial.SerialException, OSError) as exc:
            self.events.put(("error", str(exc)))

    def _drain_events(self):
        try:
            while True:
                event, value = self.events.get_nowait()
                if event == "progress":
                    self.status.set(f"上传中 {value}%")
                elif event == "complete":
                    self.uploading = False
                    self.connect_button.configure(state="normal")
                    self.status.set("数据已发送；等待 FPGA 完成显示切换")
                elif event == "error":
                    self.uploading = False
                    self.connect_button.configure(state="normal")
                    self.status.set("上传失败")
                    messagebox.showerror("上传失败", value)
        except queue.Empty:
            pass
        self.root.after(100, self._drain_events)

    def close(self):
        if self.uploading:
            messagebox.showwarning("正在上传", "上传完成前请勿关闭上位机。")
            return
        self.close_serial()
        self.root.destroy()


def main():
    root = tk.Tk()
    PlayerHostApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
