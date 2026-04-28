#!/usr/bin/env python3
"""
Jupyter Notebook Manager - Python UI Only
All actual work is done by shell scripts for maximum speed
"""

import sys
import os
import subprocess
import threading
import json
from datetime import datetime
from pathlib import Path

try:
    from PyQt5.QtWidgets import *
    from PyQt5.QtCore import *
    from PyQt5.QtGui import *
except ImportError:
    print("Please install PyQt5: pip install PyQt5")
    sys.exit(1)


class ScriptWorker(QThread):
    """Thread for running shell scripts without blocking UI"""
    output_signal = pyqtSignal(str)
    finished_signal = pyqtSignal(int, str)
    
    def __init__(self, script_path, args=None, cwd=None):
        super().__init__()
        self.script_path = script_path
        self.args = args or []
        self.cwd = cwd or os.getcwd()
        
    def run(self):
        try:
            # Build command - use bash to ensure proper execution
            cmd = ["bash", self.script_path] + self.args
            
            process = subprocess.Popen(
                cmd,
                cwd=self.cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                universal_newlines=True
            )
            
            output_lines = []
            for line in iter(process.stdout.readline, ''):
                if line:
                    output_lines.append(line)
                    self.output_signal.emit(line.strip())
                    
            process.wait()
            full_output = '\n'.join(output_lines)
            self.finished_signal.emit(process.returncode, full_output)
            
        except Exception as e:
            self.finished_signal.emit(-1, str(e))


class JupyterManager(QMainWindow):
    """Main UI Window - Calls shell scripts"""
    
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jupyter Notebook Manager")
        self.setGeometry(100, 100, 1200, 800)
        
        # Get script directory
        self.script_dir = Path(__file__).parent / "scripts"
        self.config_file = Path.home() / ".jupyter_manager.json"
        
        # Ensure scripts are executable
        self.setup_scripts()
        
        # Load config
        self.load_config()
        
        # Setup UI
        self.setup_ui()
        
        # Timer for status updates
        self.status_timer = QTimer()
        self.status_timer.timeout.connect(self.update_status)
        self.status_timer.start(5000)
        
    def setup_scripts(self):
        """Make sure all scripts are executable"""
        scripts = [
            "git.sh",                    # Main git entry point
            "git/git.sh",                # Actual git script
            "launch_jupyter_gpu.sh",
            "jupyter_notebook.sh"
        ]
        
        for script in scripts:
            script_path = self.script_dir / script
            if script_path.exists():
                os.chmod(script_path, 0o755)
                print(f"✅ Made executable: {script}")
            else:
                print(f"⚠️  Script not found: {script}")
                
    def setup_ui(self):
        """Setup the UI"""
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        
        # Header
        header = QLabel("🚀 Jupyter Notebook Manager")
        header.setStyleSheet("font-size: 28px; font-weight: bold; color: #4CAF50; padding: 10px;")
        header.setAlignment(Qt.AlignCenter)
        main_layout.addWidget(header)
        
        # Status bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Ready")
        
        # Progress bar
        self.progress_bar = QProgressBar()
        self.progress_bar.setVisible(False)
        self.status_bar.addPermanentWidget(self.progress_bar)
        
        # Tab widget
        self.tab_widget = QTabWidget()
        main_layout.addWidget(self.tab_widget)
        
        # Create tabs
        self.create_control_tab()
        self.create_git_tab()
        self.create_output_tab()
        self.create_settings_tab()
        
        # Apply dark theme
        self.apply_dark_theme()
        
    def create_control_tab(self):
        """Create container control tab"""
        tab = QWidget()
        layout = QHBoxLayout(tab)
        
        # Left panel - Controls
        left_panel = QWidget()
        left_layout = QVBoxLayout(left_panel)
        
        # Container settings
        settings_group = QGroupBox("Container Settings")
        settings_layout = QFormLayout()
        
        self.container_type = QComboBox()
        self.container_type.addItems(["gpu", "cpu"])
        settings_layout.addRow("Type:", self.container_type)
        
        self.port = QLineEdit("8888")
        self.port.setValidator(QIntValidator(1024, 65535))
        settings_layout.addRow("Port:", self.port)
        
        self.container_status = QLabel("⚪ Unknown")
        self.container_status.setStyleSheet("color: #FFA500; font-weight: bold;")
        settings_layout.addRow("Status:", self.container_status)
        
        settings_group.setLayout(settings_layout)
        left_layout.addWidget(settings_group)
        
        # Control buttons
        button_group = QGroupBox("Container Control")
        button_layout = QGridLayout()
        
        self.start_btn = QPushButton("▶ Start Container")
        self.start_btn.clicked.connect(self.start_container)
        self.start_btn.setStyleSheet("background-color: #4CAF50;")
        
        self.stop_btn = QPushButton("⏹ Stop Container")
        self.stop_btn.clicked.connect(self.stop_container)
        self.stop_btn.setEnabled(False)
        self.stop_btn.setStyleSheet("background-color: #f44336;")
        
        self.restart_btn = QPushButton("🔄 Restart Container")
        self.restart_btn.clicked.connect(self.restart_container)
        self.restart_btn.setEnabled(False)
        
        self.open_btn = QPushButton("🌐 Open Jupyter")
        self.open_btn.clicked.connect(self.open_jupyter)
        self.open_btn.setEnabled(False)
        
        button_layout.addWidget(self.start_btn, 0, 0)
        button_layout.addWidget(self.stop_btn, 0, 1)
        button_layout.addWidget(self.restart_btn, 1, 0)
        button_layout.addWidget(self.open_btn, 1, 1)
        
        button_group.setLayout(button_layout)
        left_layout.addWidget(button_group)
        
        # Quick stats
        stats_group = QGroupBox("Quick Stats")
        stats_layout = QVBoxLayout()
        self.stats_text = QTextEdit()
        self.stats_text.setReadOnly(True)
        self.stats_text.setMaximumHeight(150)
        stats_layout.addWidget(self.stats_text)
        stats_group.setLayout(stats_layout)
        left_layout.addWidget(stats_group)
        
        # Right panel - Output
        right_panel = QWidget()
        right_layout = QVBoxLayout(right_panel)
        
        output_group = QGroupBox("Container Output")
        output_layout = QVBoxLayout()
        self.container_output = QTextEdit()
        self.container_output.setReadOnly(True)
        self.container_output.setFont(QFont("Monospace", 9))
        output_layout.addWidget(self.container_output)
        output_group.setLayout(output_layout)
        right_layout.addWidget(output_group)
        
        # Add panels
        layout.addWidget(left_panel, stretch=1)
        layout.addWidget(right_panel, stretch=1)
        
        self.tab_widget.addTab(tab, "Control")
        
    def create_git_tab(self):
        """Create Git control tab"""
        tab = QWidget()
        layout = QVBoxLayout(tab)
        
        # Git info
        info_group = QGroupBox("Git Information")
        info_layout = QFormLayout()
        
        self.repo_status = QLabel("Not configured")
        info_layout.addRow("Repository:", self.repo_status)
        
        self.branch_status = QLabel("Unknown")
        info_layout.addRow("Branch:", self.branch_status)
        
        self.commit_status = QLabel("None")
        info_layout.addRow("Last Commit:", self.commit_status)
        
        info_group.setLayout(info_layout)
        layout.addWidget(info_group)
        
        # Git actions
        actions_group = QGroupBox("Git Operations")
        actions_layout = QGridLayout()
        
        git_actions = [
            ("📊 Status", self.git_status),
            ("📜 Log", self.git_log),
            ("🌿 Branches", self.git_branches),
            ("💾 Commit", self.git_commit),
            ("⬆️ Push", self.git_push),
            ("⬇️ Pull", self.git_pull),
            ("✨ New Branch", self.git_new_branch),
            ("🔄 Switch Branch", self.git_switch_branch),
            ("🗑️ Discard", self.git_discard),
            ("🔧 Fix Permissions", self.git_fix_permissions)
        ]
        
        for i, (text, callback) in enumerate(git_actions):
            btn = QPushButton(text)
            btn.clicked.connect(callback)
            actions_layout.addWidget(btn, i // 3, i % 3)
            
        actions_group.setLayout(actions_layout)
        layout.addWidget(actions_group)
        
        # Git output
        output_group = QGroupBox("Git Output")
        output_layout = QVBoxLayout()
        self.git_output = QTextEdit()
        self.git_output.setReadOnly(True)
        self.git_output.setFont(QFont("Monospace", 9))
        output_layout.addWidget(self.git_output)
        output_group.setLayout(output_layout)
        layout.addWidget(output_group)
        
        self.tab_widget.addTab(tab, "Git")
        
    def create_output_tab(self):
        """Create consolidated output tab"""
        tab = QWidget()
        layout = QVBoxLayout(tab)
        
        # All operations output
        output_group = QGroupBox("All Operations Output")
        output_layout = QVBoxLayout()
        
        self.all_output = QTextEdit()
        self.all_output.setReadOnly(True)
        self.all_output.setFont(QFont("Monospace", 9))
        self.all_output.setStyleSheet("background-color: #000000; color: #00ff00;")
        output_layout.addWidget(self.all_output)
        
        # Clear button
        clear_btn = QPushButton("Clear Output")
        clear_btn.clicked.connect(lambda: self.all_output.clear())
        output_layout.addWidget(clear_btn)
        
        output_group.setLayout(output_layout)
        layout.addWidget(output_group)
        
        self.tab_widget.addTab(tab, "Output")
        
    def create_settings_tab(self):
        """Create settings tab"""
        tab = QWidget()
        layout = QVBoxLayout(tab)
        
        # Workspace settings
        workspace_group = QGroupBox("Workspace")
        workspace_layout = QHBoxLayout()
        
        self.workspace_path = QLineEdit(os.getcwd())
        browse_btn = QPushButton("Browse...")
        browse_btn.clicked.connect(self.browse_workspace)
        apply_btn = QPushButton("Apply")
        apply_btn.clicked.connect(self.apply_workspace)
        
        workspace_layout.addWidget(QLabel("Path:"))
        workspace_layout.addWidget(self.workspace_path)
        workspace_layout.addWidget(browse_btn)
        workspace_layout.addWidget(apply_btn)
        workspace_group.setLayout(workspace_layout)
        layout.addWidget(workspace_group)
        
        # Auto-save settings
        auto_group = QGroupBox("Auto-Save")
        auto_layout = QVBoxLayout()
        
        self.auto_commit = QCheckBox("Auto-commit on window close")
        self.auto_commit.setChecked(True)
        auto_layout.addWidget(self.auto_commit)
        
        self.auto_push = QCheckBox("Auto-push after commit")
        self.auto_push.setChecked(False)
        auto_layout.addWidget(self.auto_push)
        
        auto_group.setLayout(auto_layout)
        layout.addWidget(auto_group)
        
        # Script paths
        scripts_group = QGroupBox("Script Locations")
        scripts_layout = QVBoxLayout()
        
        self.scripts_info = QTextEdit()
        self.scripts_info.setReadOnly(True)
        self.scripts_info.setMaximumHeight(100)
        self.update_scripts_info()
        scripts_layout.addWidget(self.scripts_info)
        
        scripts_group.setLayout(scripts_layout)
        layout.addWidget(scripts_group)
        
        layout.addStretch()
        self.tab_widget.addTab(tab, "Settings")
        
    def run_script(self, script_name, args=None, callback=None, output_widget=None):
        """Run a shell script and display output"""
        script_path = self.script_dir / script_name
        
        if not script_path.exists():
            self.log_output(f"❌ Script not found: {script_path}", output_widget)
            return
            
        # Show progress
        self.progress_bar.setVisible(True)
        self.progress_bar.setRange(0, 0)
        self.status_bar.showMessage(f"Running {script_name}...")
        
        # Create worker
        cwd = self.workspace_path.text()
        worker = ScriptWorker(str(script_path), args or [], cwd)
        
        # Connect signals
        if output_widget:
            worker.output_signal.connect(lambda x: self.append_output(x, output_widget))
        else:
            worker.output_signal.connect(lambda x: self.log_output(x))
            
        worker.finished_signal.connect(lambda code, out: self.script_finished(script_name, code, out, callback))
        
        # Store worker reference
        self.current_worker = worker
        worker.start()
        
    def script_finished(self, script_name, exit_code, output, callback):
        """Handle script completion"""
        self.progress_bar.setVisible(False)
        
        if exit_code == 0:
            self.status_bar.showMessage(f"{script_name} completed successfully", 3000)
            self.log_output(f"✅ {script_name} completed", None)
        else:
            self.status_bar.showMessage(f"{script_name} failed with exit code {exit_code}", 5000)
            self.log_output(f"❌ {script_name} failed (exit code: {exit_code})", None)
            
        if callback:
            callback(exit_code, output)
            
    def log_output(self, message, widget=None):
        """Log output to specified widget or all output tab"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        formatted = f"[{timestamp}] {message}"
        
        # Add to all output
        self.all_output.append(formatted)
        
        # Add to specific widget if provided
        if widget:
            widget.append(message)
            
        # Scroll to bottom
        if widget:
            widget.verticalScrollBar().setValue(
                widget.verticalScrollBar().maximum()
            )
        self.all_output.verticalScrollBar().setValue(
            self.all_output.verticalScrollBar().maximum()
        )
        
    def append_output(self, message, widget):
        """Append output to widget"""
        if widget:
            widget.append(message)
            
    # ========== Container Operations ==========
    
    def start_container(self):
        """Start Jupyter container"""
        self.log_output("Starting Jupyter container...")
        self.container_output.clear()
        
        # Set environment variables for the script
        os.environ['PORT'] = self.port.text()
        os.environ['CONTAINER_TYPE'] = self.container_type.currentText()
        
        # Run launch script
        self.run_script(
            "launch_jupyter_gpu.sh",
            output_widget=self.container_output,
            callback=self.container_started
        )
        
    def container_started(self, exit_code, output):
        """Handle container start"""
        if exit_code == 0:
            self.start_btn.setEnabled(False)
            self.stop_btn.setEnabled(True)
            self.restart_btn.setEnabled(True)
            self.open_btn.setEnabled(True)
            self.container_status.setText("🟢 Running")
            self.container_status.setStyleSheet("color: #4CAF50; font-weight: bold;")
            
    def stop_container(self):
        """Stop Jupyter container"""
        self.log_output("Stopping container...")
        
        # Run docker stop command
        cmd = "docker stop $(docker ps -q --filter name=jupyter) 2>/dev/null || true"
        subprocess.run(cmd, shell=True)
        
        self.start_btn.setEnabled(True)
        self.stop_btn.setEnabled(False)
        self.restart_btn.setEnabled(False)
        self.open_btn.setEnabled(False)
        self.container_status.setText("🔴 Stopped")
        self.container_status.setStyleSheet("color: #f44336; font-weight: bold;")
        self.log_output("Container stopped")
        
    def restart_container(self):
        """Restart container"""
        self.log_output("Restarting container...")
        self.stop_container()
        QTimer.singleShot(2000, self.start_container)
        
    def open_jupyter(self):
        """Open Jupyter in browser"""
        import webbrowser
        url = f"http://localhost:{self.port.text()}"
        webbrowser.open(url)
        self.log_output(f"Opened {url}")
        
    # ========== Git Operations ==========
    
    def git_status(self):
        """Show git status using git.sh"""
        self.git_output.clear()
        self.run_script(
            "git.sh",
            ["manual"],
            output_widget=self.git_output
        )
        
    def git_log(self):
        """Show git log"""
        self.git_output.clear()
        self.run_command("git log --oneline --graph -20", self.git_output)
        
    def git_branches(self):
        """Show branches"""
        self.git_output.clear()
        self.run_command("git branch -a", self.git_output)
        
    def git_commit(self):
        """Commit changes"""
        message, ok = QInputDialog.getText(
            self, "Commit", "Commit message:",
            text=f"Auto-commit: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        )
        if ok and message:
            self.git_output.clear()
            self.run_command('git add .', self.git_output)
            self.run_command(f'git commit -m "{message}"', self.git_output)
            
    def git_push(self):
        """Push to GitHub using git.sh"""
        self.git_output.clear()
        self.run_script("git.sh", ["manual"], output_widget=self.git_output)
        
    def git_pull(self):
        """Pull from GitHub"""
        self.git_output.clear()
        self.run_command("git pull", self.git_output)
        
    def git_new_branch(self):
        """Create new branch"""
        branch, ok = QInputDialog.getText(self, "New Branch", "Branch name:")
        if ok and branch:
            self.git_output.clear()
            self.run_command(f"git checkout -b {branch}", self.git_output)
            
    def git_switch_branch(self):
        """Switch branch"""
        # Get branches
        result = subprocess.run("git branch", shell=True, capture_output=True, text=True,
                               cwd=self.workspace_path.text())
        branches = [b.strip().replace('*', '').strip() for b in result.stdout.split('\n') if b.strip()]
        
        branch, ok = QInputDialog.getItem(self, "Switch Branch", "Branch:", branches, 0, False)
        if ok and branch:
            self.git_output.clear()
            self.run_command(f"git checkout {branch}", self.git_output)
            
    def git_discard(self):
        """Discard changes"""
        reply = QMessageBox.question(self, "Confirm", "Discard all changes?",
                                    QMessageBox.Yes | QMessageBox.No)
        if reply == QMessageBox.Yes:
            self.git_output.clear()
            self.run_command("git checkout -- .", self.git_output)
            
    def git_fix_permissions(self):
        """Fix git permissions using the permissions module"""
        self.git_output.clear()
        # Call the permissions fix script
        permissions_script = self.script_dir / "git/permissions.sh"
        if permissions_script.exists():
            self.run_script("git/permissions.sh", output_widget=self.git_output)
        else:
            # Fallback to manual commands
            self.run_command("sudo chown -R $USER:$USER .git 2>/dev/null || true", self.git_output)
            self.run_command("find .git -type f -exec chmod 644 {} \\; 2>/dev/null || true", self.git_output)
            self.run_command("find .git -type d -exec chmod 755 {} \\; 2>/dev/null || true", self.git_output)
        self.log_output("Git permissions fixed")
        
    def run_command(self, command, output_widget):
        """Run a shell command"""
        try:
            result = subprocess.run(command, shell=True, cwd=self.workspace_path.text(),
                                  capture_output=True, text=True)
            output_widget.append(f"$ {command}")
            if result.stdout:
                output_widget.append(result.stdout)
            if result.stderr:
                output_widget.append(result.stderr)
            output_widget.append(f"Exit code: {result.returncode}\n")
        except Exception as e:
            output_widget.append(f"Error: {e}")
            
    # ========== Status Updates ==========
    
    def update_status(self):
        """Update status information"""
        # Check container status
        result = subprocess.run("docker ps --filter name=jupyter --format '{{.Names}}'",
                              shell=True, capture_output=True, text=True)
        
        if result.stdout.strip():
            if not self.stop_btn.isEnabled():
                self.container_status.setText("🟢 Running")
                self.container_status.setStyleSheet("color: #4CAF50; font-weight: bold;")
                self.start_btn.setEnabled(False)
                self.stop_btn.setEnabled(True)
                self.restart_btn.setEnabled(True)
                self.open_btn.setEnabled(True)
        else:
            if self.stop_btn.isEnabled():
                self.container_status.setText("🔴 Stopped")
                self.container_status.setStyleSheet("color: #f44336; font-weight: bold;")
                self.start_btn.setEnabled(True)
                self.stop_btn.setEnabled(False)
                self.restart_btn.setEnabled(False)
                self.open_btn.setEnabled(False)
                
        # Update git info
        git_dir = os.path.join(self.workspace_path.text(), ".git")
        if os.path.exists(git_dir):
            result = subprocess.run("git remote get-url origin 2>/dev/null", shell=True,
                                  capture_output=True, text=True, cwd=self.workspace_path.text())
            if result.stdout:
                self.repo_status.setText(result.stdout.strip()[:50])
                
            result = subprocess.run("git branch --show-current", shell=True,
                                  capture_output=True, text=True, cwd=self.workspace_path.text())
            if result.stdout:
                self.branch_status.setText(result.stdout.strip())
                
            result = subprocess.run("git log -1 --oneline", shell=True,
                                  capture_output=True, text=True, cwd=self.workspace_path.text())
            if result.stdout:
                self.commit_status.setText(result.stdout.strip()[:50])
                
        # Update stats
        stats = f"Workspace: {self.workspace_path.text()}\n"
        stats += f"Container: {'Running' if self.stop_btn.isEnabled() else 'Stopped'}\n"
        stats += f"Branch: {self.branch_status.text()}\n"
        
        result = subprocess.run("git status --porcelain 2>/dev/null | wc -l", shell=True,
                              capture_output=True, text=True, cwd=self.workspace_path.text())
        if result.stdout:
            stats += f"Uncommitted changes: {result.stdout.strip()} files"
            
        self.stats_text.setText(stats)
        
    # ========== Settings ==========
    
    def browse_workspace(self):
        """Browse for workspace directory"""
        directory = QFileDialog.getExistingDirectory(self, "Select Workspace")
        if directory:
            self.workspace_path.setText(directory)
            self.apply_workspace()
            
    def apply_workspace(self):
        """Apply workspace change"""
        if os.path.exists(self.workspace_path.text()):
            os.chdir(self.workspace_path.text())
            self.save_config()
            self.log_output(f"Workspace changed to {self.workspace_path.text()}")
            self.update_status()
        else:
            QMessageBox.warning(self, "Error", "Directory does not exist")
            
    def update_scripts_info(self):
        """Update scripts information display"""
        info = "Available Scripts:\n"
        info += "=" * 40 + "\n\n"
        
        # Check main scripts
        for script in ["git.sh", "launch_jupyter_gpu.sh", "jupyter_notebook.sh"]:
            path = self.script_dir / script
            if path.exists():
                info += f"  ✅ {script}\n"
            else:
                info += f"  ❌ {script}\n"
                
        # Check git module
        git_dir = self.script_dir / "git"
        if git_dir.exists():
            info += "\nGit Module Scripts:\n"
            for script in ["git.sh", "config.sh", "permissions.sh", "git_ops.sh", "utils.sh"]:
                path = git_dir / script
                if path.exists():
                    info += f"  ✅ git/{script}\n"
                else:
                    info += f"  ❌ git/{script}\n"
                    
        self.scripts_info.setText(info)
        
    def load_config(self):
        """Load configuration"""
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    config = json.load(f)
                self.workspace_path.setText(config.get("workspace", os.getcwd()))
                self.port.setText(config.get("port", "8888"))
                self.container_type.setCurrentText(config.get("container_type", "gpu"))
                self.auto_commit.setChecked(config.get("auto_commit", True))
                self.auto_push.setChecked(config.get("auto_push", False))
                
                # Change to workspace
                if os.path.exists(self.workspace_path.text()):
                    os.chdir(self.workspace_path.text())
            except Exception as e:
                print(f"Error loading config: {e}")
                
    def save_config(self):
        """Save configuration"""
        config = {
            "workspace": self.workspace_path.text(),
            "port": self.port.text(),
            "container_type": self.container_type.currentText(),
            "auto_commit": self.auto_commit.isChecked(),
            "auto_push": self.auto_push.isChecked()
        }
        try:
            with open(self.config_file, 'w') as f:
                json.dump(config, f, indent=2)
        except Exception as e:
            print(f"Error saving config: {e}")
            
    def apply_dark_theme(self):
        """Apply dark theme to UI"""
        self.setStyleSheet("""
            QMainWindow, QWidget {
                background-color: #1e1e1e;
                color: #d4d4d4;
            }
            QTabWidget::pane {
                border: 1px solid #3c3c3c;
                background-color: #2b2b2b;
            }
            QTabBar::tab {
                background-color: #3c3c3c;
                color: #ffffff;
                padding: 8px 16px;
                margin-right: 2px;
            }
            QTabBar::tab:selected {
                background-color: #4CAF50;
                color: white;
            }
            QGroupBox {
                color: #4CAF50;
                border: 2px solid #3c3c3c;
                border-radius: 8px;
                margin-top: 12px;
                font-weight: bold;
            }
            QPushButton {
                background-color: #0d7377;
                color: white;
                border: none;
                padding: 8px 16px;
                border-radius: 5px;
                font-weight: bold;
            }
            QPushButton:hover {
                background-color: #14a085;
            }
            QPushButton:disabled {
                background-color: #555555;
                color: #888888;
            }
            QLineEdit, QTextEdit {
                background-color: #2d2d2d;
                color: #d4d4d4;
                border: 1px solid #3c3c3c;
                border-radius: 5px;
                padding: 5px;
            }
            QLabel {
                color: #d4d4d4;
            }
            QStatusBar {
                background-color: #1e1e1e;
                color: #d4d4d4;
            }
            QCheckBox {
                color: #d4d4d4;
            }
        """)
        
    def closeEvent(self, event):
        """Handle window closing"""
        if self.auto_commit.isChecked():
            reply = QMessageBox.question(self, "Auto Commit", 
                                        "Auto-commit changes before closing?",
                                        QMessageBox.Yes | QMessageBox.No)
            if reply == QMessageBox.Yes:
                self.log_output("Auto-committing changes...")
                self.git_commit()
                if self.auto_push.isChecked():
                    self.git_push()
                    
        self.save_config()
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setFont(QFont("Arial", 10))
    
    # Check if scripts directory exists
    script_dir = Path(__file__).parent / "scripts"
    if not script_dir.exists():
        os.makedirs(script_dir)
        print(f"✅ Created {script_dir}")
        print("\n⚠️  Please copy your scripts to this directory:")
        print("  - git.sh (the main entry point)")
        print("  - git/ (the entire git module folder)")
        print("  - launch_jupyter_gpu.sh")
        print("  - jupyter_notebook.sh")
        print("\nOr run the setup script to create them automatically.")
        
    window = JupyterManager()
    window.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()