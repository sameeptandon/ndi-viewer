import sys
import time
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
    QPushButton, QLabel, QListWidget, QListWidgetItem, QFrame,
    QSizePolicy
)
from PySide6.QtCore import Qt, QThread, Signal, Slot, QPoint, QSize
from PySide6.QtGui import QPainter, QImage, QColor, QFont, QPolygon, QPainterPath

from cyndilib.finder import Finder
from cyndilib.receiver import Receiver
from cyndilib.video_frame import VideoFrameSync
from cyndilib.wrapper.ndi_recv import RecvColorFormat, RecvBandwidth

class NDIWorker(QThread):
    """
    Background worker thread to handle NDI discovery and frame capture
    without blocking the PySide main GUI thread.
    """
    sources_updated = Signal(list)
    frame_ready = Signal(QImage)
    status_changed = Signal(str)

    def __init__(self):
        super().__init__()
        self.running = True
        self.selected_source_name = None
        self.source_change_pending = False
        
        # Initialize NDI Finder and Receiver
        self.finder = Finder()
        self.receiver = Receiver(
            color_format=RecvColorFormat.RGBX_RGBA,
            bandwidth=RecvBandwidth.highest
        )
        self.video_frame = VideoFrameSync()
        self.receiver.frame_sync.set_video_frame(self.video_frame)

    def set_source(self, name):
        """Request the worker thread to switch to a different NDI source."""
        self.selected_source_name = name
        self.source_change_pending = True

    def stop(self):
        """Signal the thread to shut down and block until finished."""
        self.running = False
        self.wait()

    def run(self):
        # Open Finder to listen on network
        try:
            self.finder.open()
            self.status_changed.emit("Searching network for NDI sources...")
        except Exception as e:
            self.status_changed.emit(f"Scanner error: {str(e)}")
            return

        last_discovery_time = 0
        known_sources = []

        while self.running:
            t_now = time.time()
            
            # Periodically scan for sources (every 1.5 seconds)
            if t_now - last_discovery_time > 1.5:
                try:
                    current_sources = self.finder.get_source_names()
                    if current_sources != known_sources:
                        known_sources = current_sources
                        self.sources_updated.emit(known_sources)
                except Exception as e:
                    print("Error during network source scan:", e)
                last_discovery_time = t_now

            # Switch NDI streams if a change is requested
            if self.source_change_pending:
                self.source_change_pending = False
                
                # Disconnect current source if connected
                if self.receiver.is_connected():
                    self.receiver.set_source(None)
                    self.receiver.disconnect()
                    self.status_changed.emit("Disconnected.")
                
                if self.selected_source_name:
                    try:
                        self.status_changed.emit(f"Connecting to {self.selected_source_name}...")
                        source = self.finder.get_source(self.selected_source_name)
                        if source:
                            self.receiver.set_source(source)
                            # Wait a brief moment to stabilize NDI connection state
                            time.sleep(0.15)
                            if self.receiver.is_connected():
                                self.status_changed.emit(f"Streaming: {self.selected_source_name}")
                            else:
                                self.status_changed.emit("Connecting stream...")
                        else:
                            self.status_changed.emit("Source not found on network.")
                    except Exception as e:
                        self.status_changed.emit(f"Stream error: {str(e)}")
                else:
                    self.status_changed.emit("No active stream. Choose a source.")

            # Capture video frame if receiver is active and connected
            if self.selected_source_name and self.receiver.is_connected():
                try:
                    self.receiver.frame_sync.capture_video()
                    w = self.video_frame.xres
                    h = self.video_frame.yres
                    if w > 0 and h > 0:
                        arr = self.video_frame.get_array()
                        # Construct a QImage using the flat RGBA array buffer.
                        # We perform a deep copy (.copy()) to detach from the NDI C buffer,
                        # making it thread-safe for the main thread.
                        qimg = QImage(arr.data, w, h, w * 4, QImage.Format_RGBA8888).copy()
                        self.frame_ready.emit(qimg)
                except Exception as e:
                    print("Frame capture error:", e)

            # Prevent 100% CPU thread starvation
            time.sleep(0.005)

        # Thread exit cleanup
        if self.receiver.is_connected():
            self.receiver.set_source(None)
            self.receiver.disconnect()
        self.finder.close()


class NDIVideoWidget(QWidget):
    """
    Custom widget designed for low-latency, aspect-ratio-correct rendering of
    NDI video frames using QPainter. Includes a real-time HUD (FPS/resolution)
    and a custom vector camera placeholder.
    """
    double_clicked = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.image = None
        self.fps = 0.0
        self.frame_times = []
        self.resolution_str = "No Signal"
        self.status_text = "Select an NDI source from the sidebar"
        
        # Enable styling for standard styling hooks
        self.setAttribute(Qt.WA_OpaquePaintEvent, False)

    def set_frame(self, image):
        """Set the current video frame and calculate the active render FPS."""
        self.image = image
        self.resolution_str = f"{image.width()}x{image.height()}"
        
        current_time = time.time()
        self.frame_times.append(current_time)
        
        # Filter out frame timestamps older than 1 second
        self.frame_times = [t for t in self.frame_times if current_time - t <= 1.0]
        
        if len(self.frame_times) > 1:
            duration = self.frame_times[-1] - self.frame_times[0]
            if duration > 0:
                self.fps = (len(self.frame_times) - 1) / duration
            else:
                self.fps = 0.0
        else:
            self.fps = 0.0
            
        self.update()

    def set_status(self, text):
        """Set status text to show when no video stream is active."""
        self.status_text = text
        self.update()

    def clear(self):
        """Reset video and statistics."""
        self.image = None
        self.resolution_str = "No Signal"
        self.fps = 0.0
        self.frame_times = []
        self.update()

    def mouseDoubleClickEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.double_clicked.emit()
            event.accept()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        
        # Solid dark void fill
        painter.fillRect(self.rect(), QColor("#0e0e11"))
        
        if self.image and not self.image.isNull():
            # Calculate aspect ratio constraints
            widget_w = self.width()
            widget_h = self.height()
            img_w = self.image.width()
            img_h = self.image.height()
            
            widget_aspect = widget_w / widget_h
            img_aspect = img_w / img_h
            
            if widget_aspect > img_aspect:
                # Pillarbox rendering
                new_h = widget_h
                new_w = int(new_h * img_aspect)
                x = (widget_w - new_w) // 2
                y = 0
            else:
                # Letterbox rendering
                new_w = widget_w
                new_h = int(new_w / img_aspect)
                x = 0
                y = (widget_h - new_h) // 2
                
            # Render scaled video frame
            painter.drawImage(
                x, y, 
                self.image.scaled(new_w, new_h, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            )
            
            # Render HUD Display (Translucent Overlay Box)
            hud_bg = QColor(14, 14, 17, 180)
            painter.setPen(Qt.NoPen)
            painter.setBrush(hud_bg)
            
            hud_w = 170
            hud_h = 52
            margin = 15
            painter.drawRoundedRect(widget_w - hud_w - margin, margin, hud_w, hud_h, 8, 8)
            
            # Print resolution and render performance
            painter.setPen(QColor("#cbd5e1"))
            painter.setFont(QFont("Monospace", 9, QFont.Bold))
            painter.drawText(widget_w - hud_w - margin + 12, margin + 20, f"RES: {self.resolution_str}")
            
            # Accentuate FPS with color
            fps_color = "#10b981" if self.fps >= 24 else ("#f59e0b" if self.fps > 10 else "#ef4444")
            painter.setPen(QColor(fps_color))
            painter.drawText(widget_w - hud_w - margin + 12, margin + 38, f"FPS: {self.fps:.1f}")
            
        else:
            # Render beautiful vector graphic for idle/signal-less states
            center_x = self.width() // 2
            center_y = self.height() // 2
            
            # Draw a modern camera silhouette
            body_w, body_h = 60, 38
            bx = center_x - body_w // 2 - 10
            by = center_y - body_h // 2 - 20
            
            painter.setPen(Qt.NoPen)
            # Base camera color: deep modern blue
            painter.setBrush(QColor("#2563eb"))
            painter.drawRoundedRect(bx, by, body_w, body_h, 6, 6)
            
            # Camera lens cone
            lens_x = bx + body_w
            lens_y_center = by + body_h // 2
            points = [
                QPoint(lens_x, lens_y_center - 10),
                QPoint(lens_x + 16, lens_y_center - 18),
                QPoint(lens_x + 16, lens_y_center + 18),
                QPoint(lens_x, lens_y_center + 10)
            ]
            painter.drawPolygon(QPolygon(points))
            
            # Aperture highlight detail
            painter.setBrush(QColor("#60a5fa"))
            painter.drawEllipse(bx + 14, by + 11, 16, 16)
            
            # Signal text descriptor
            painter.setPen(QColor("#64748b"))
            painter.setFont(QFont("Segoe UI", 11, QFont.Medium))
            painter.drawText(
                0, center_y + 35,
                self.width(), 35,
                Qt.AlignCenter,
                self.status_text
            )


class NDIViewerApp(QMainWindow):
    """
    Main desktop window coordinating the NDI scanner sidebar and stream viewer.
    Uses high-quality dark styling.
    """
    def __init__(self):
        super().__init__()
        self.setWindowTitle("NDI Network Viewer")
        self.resize(1100, 700)
        
        # State tracker
        self.selected_source = None
        self.is_fullscreen = False

        # Build application structures
        self.setup_ui()
        self.apply_stylesheet()
        
        # Launch background NDI processing thread
        self.worker = NDIWorker()
        self.worker.sources_updated.connect(self.on_sources_updated)
        self.worker.frame_ready.connect(self.video_widget.set_frame)
        self.worker.status_changed.connect(self.on_status_changed)
        self.worker.start()

    def setup_ui(self):
        """Construct side-by-side main window layout."""
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QHBoxLayout(central_widget)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # -------------------------------------------------------------
        # Sidebar: Controls and Source List
        # -------------------------------------------------------------
        self.sidebar = QWidget()
        self.sidebar.setObjectName("sidebar")
        self.sidebar.setFixedWidth(290)
        
        sidebar_layout = QVBoxLayout(self.sidebar)
        sidebar_layout.setContentsMargins(15, 20, 15, 15)
        sidebar_layout.setSpacing(15)

        # Header Title
        title_container = QWidget()
        title_layout = QVBoxLayout(title_container)
        title_layout.setContentsMargins(0, 0, 0, 0)
        title_layout.setSpacing(4)
        
        app_title = QLabel("NDI VIEWER")
        app_title.setObjectName("app_title")
        subtitle = QLabel("Network Source Monitor")
        subtitle.setObjectName("app_subtitle")
        
        title_layout.addWidget(app_title)
        title_layout.addWidget(subtitle)
        sidebar_layout.addWidget(title_container)

        # Separator Line
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setFrameShadow(QFrame.Sunken)
        line.setStyleSheet("background-color: #2e2e36; height: 1px; border: none;")
        sidebar_layout.addWidget(line)

        # Source List Header and Refresh controls
        list_header_layout = QHBoxLayout()
        list_title = QLabel("Discovered Devices")
        list_title.setObjectName("section_title")
        
        self.scan_btn = QPushButton("Scan")
        self.scan_btn.setObjectName("scan_btn")
        self.scan_btn.clicked.connect(self.trigger_refresh)
        
        list_header_layout.addWidget(list_title)
        list_header_layout.addWidget(self.scan_btn)
        sidebar_layout.addLayout(list_header_layout)

        # Main List Widget
        self.source_list_widget = QListWidget()
        self.source_list_widget.setObjectName("source_list")
        self.source_list_widget.itemClicked.connect(self.on_source_selected)
        sidebar_layout.addWidget(self.source_list_widget)

        # Network scanner status bar
        self.network_status_label = QLabel("Initializing network monitor...")
        self.network_status_label.setObjectName("network_status")
        self.network_status_label.setWordWrap(True)
        sidebar_layout.addWidget(self.network_status_label)

        # -------------------------------------------------------------
        # Main View Frame: Video widget & Controls
        # -------------------------------------------------------------
        self.main_view_frame = QWidget()
        self.main_view_frame.setObjectName("main_view_frame")
        view_layout = QVBoxLayout(self.main_view_frame)
        view_layout.setContentsMargins(0, 0, 0, 0)
        view_layout.setSpacing(0)

        # Custom high-performance video drawing widget
        self.video_widget = NDIVideoWidget()
        self.video_widget.double_clicked.connect(self.toggle_fullscreen)
        view_layout.addWidget(self.video_widget, 1)

        # Bottom stream control panel
        self.control_panel = QWidget()
        self.control_panel.setObjectName("control_panel")
        self.control_panel.setFixedHeight(65)
        
        control_layout = QHBoxLayout(self.control_panel)
        control_layout.setContentsMargins(20, 10, 20, 10)
        
        # Connection status label
        self.connection_info_label = QLabel("Select a source to begin stream")
        self.connection_info_label.setObjectName("connection_info")
        control_layout.addWidget(self.connection_info_label, 1)

        # Action Buttons
        self.btn_fullscreen = QPushButton("Fullscreen")
        self.btn_fullscreen.setObjectName("btn_fullscreen")
        self.btn_fullscreen.clicked.connect(self.toggle_fullscreen)
        control_layout.addWidget(self.btn_fullscreen)

        self.btn_stop = QPushButton("Disconnect")
        self.btn_stop.setObjectName("btn_stop")
        self.btn_stop.clicked.connect(self.stop_current_stream)
        control_layout.addWidget(self.btn_stop)

        view_layout.addWidget(self.control_panel)

        # Assemble layout splits
        main_layout.addWidget(self.sidebar)
        main_layout.addWidget(self.main_view_frame, 1)

    def apply_stylesheet(self):
        """Build premium dark mode layout formatting with styling tokens."""
        self.setStyleSheet("""
            QMainWindow {
                background-color: #0e0e11;
            }
            
            QWidget#sidebar {
                background-color: #15151a;
                border-right: 1px solid #24242e;
            }
            
            QLabel#app_title {
                color: #ffffff;
                font-family: 'Segoe UI', 'Outfit', sans-serif;
                font-size: 19px;
                font-weight: 800;
                letter-spacing: 1.5px;
            }
            
            QLabel#app_subtitle {
                color: #5b6477;
                font-family: 'Segoe UI', sans-serif;
                font-size: 11px;
                font-weight: 500;
            }
            
            QLabel#section_title {
                color: #8b9bb4;
                font-family: 'Segoe UI', sans-serif;
                font-size: 12px;
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }
            
            QPushButton#scan_btn {
                background-color: #1a1a24;
                border: 1px solid #313143;
                border-radius: 4px;
                color: #94a3b8;
                padding: 4px 10px;
                font-size: 11px;
                font-weight: 600;
            }
            
            QPushButton#scan_btn:hover {
                background-color: #282837;
                color: #ffffff;
                border-color: #4b5563;
            }
            
            QListWidget#source_list {
                background-color: transparent;
                border: none;
                outline: 0;
            }
            
            QListWidget#source_list::item {
                background-color: #1e1e26;
                color: #e2e8f0;
                border: 1px solid #2d2d3c;
                border-radius: 6px;
                padding: 10px 12px;
                margin-bottom: 8px;
                font-family: 'Segoe UI', sans-serif;
                font-size: 12px;
            }
            
            QListWidget#source_list::item:hover {
                background-color: #272733;
                border-color: #3b82f6;
                color: #ffffff;
            }
            
            QListWidget#source_list::item:selected {
                background-color: #2563eb;
                border-color: #60a5fa;
                color: #ffffff;
                font-weight: 600;
            }
            
            QLabel#network_status {
                color: #64748b;
                font-family: 'Segoe UI', sans-serif;
                font-size: 11px;
                background-color: #101014;
                border: 1px solid #1a1a20;
                border-radius: 4px;
                padding: 8px;
            }
            
            QWidget#control_panel {
                background-color: #111115;
                border-top: 1px solid #1e1e26;
            }
            
            QLabel#connection_info {
                color: #94a3b8;
                font-family: 'Segoe UI', sans-serif;
                font-size: 13px;
                font-weight: 500;
            }
            
            QPushButton#btn_stop {
                background-color: #991b1b;
                border: none;
                border-radius: 4px;
                color: #fca5a5;
                padding: 6px 14px;
                font-size: 12px;
                font-weight: 600;
            }
            
            QPushButton#btn_stop:hover {
                background-color: #b91c1c;
                color: #ffffff;
            }
            
            QPushButton#btn_fullscreen {
                background-color: #1e293b;
                border: 1px solid #334155;
                border-radius: 4px;
                color: #cbd5e1;
                padding: 6px 14px;
                font-size: 12px;
                font-weight: 600;
                margin-right: 6px;
            }
            
            QPushButton#btn_fullscreen:hover {
                background-color: #334155;
                color: #ffffff;
            }
        """)

    @Slot(list)
    def on_sources_updated(self, sources_list):
        """Update list UI with current active network broadcasts."""
        self.source_list_widget.clear()
        
        if not sources_list:
            item = QListWidgetItem("No NDI sources found")
            item.setFlags(Qt.NoItemFlags) # Disable interactions
            self.source_list_widget.addItem(item)
            return

        for name in sources_list:
            item = QListWidgetItem(name)
            self.source_list_widget.addItem(item)
            
            # Preserve current selection highlight if still online
            if self.selected_source and name == self.selected_source:
                item.setSelected(True)

    @Slot(str)
    def on_status_changed(self, status):
        """Pipe scanner and stream status messages to user info labels."""
        self.network_status_label.setText(status)
        
        # Reflect connection status on control panel
        if "Streaming" in status:
            self.connection_info_label.setText(status)
        elif "Connecting" in status:
            self.connection_info_label.setText(status)
        elif "Disconnected" in status:
            self.connection_info_label.setText("Stream stopped.")
            self.video_widget.set_status("Stream disconnected.")
        else:
            if not self.selected_source:
                self.connection_info_label.setText("Select a source to begin stream")

    def on_source_selected(self, item):
        """Handler triggered when an item in the sidebar list is clicked."""
        if not item.flags() & Qt.ItemIsSelectable:
            return
            
        source_name = item.text()
        if source_name == self.selected_source:
            return
            
        self.selected_source = source_name
        self.video_widget.clear()
        self.video_widget.set_status(f"Opening connection to {source_name}...")
        self.worker.set_source(source_name)

    def stop_current_stream(self):
        """Disconnect active receiver and reset the view."""
        self.source_list_widget.clearSelection()
        self.selected_source = None
        self.video_widget.clear()
        self.video_widget.set_status("Select an NDI source from the sidebar")
        self.worker.set_source(None)

    def trigger_refresh(self):
        """Forces the worker thread to check for network devices immediately."""
        self.on_status_changed("Scanning network for devices...")
        self.worker.set_source(self.selected_source) # Triggers update cycle

    def toggle_fullscreen(self):
        """Toggle presentation fullscreen mode."""
        if self.is_fullscreen:
            # Revert to standard presentation layout
            self.sidebar.show()
            self.control_panel.show()
            self.showNormal()
            self.btn_fullscreen.setText("Fullscreen")
            self.is_fullscreen = False
        else:
            # Mask panels and present borderless video widget
            self.sidebar.hide()
            self.control_panel.hide()
            self.showFullScreen()
            self.is_fullscreen = True

    def closeEvent(self, event):
        """Intercept application closure to safely shut down background threads."""
        self.worker.stop()
        event.accept()


def main():
    # Set display scaling environment flags
    QApplication.setAttribute(Qt.AA_EnableHighDpiScaling, True)
    QApplication.setAttribute(Qt.AA_UseHighDpiPixmaps, True)
    
    app = QApplication(sys.argv)
    
    # Establish font rendering override (prefer modern Inter if present)
    font = QFont("Inter")
    font.setStyleHint(QFont.SansSerif)
    app.setFont(font)
    
    viewer = NDIViewerApp()
    viewer.show()
    sys.exit(app.exec())


if __name__ == '__main__':
    main()
