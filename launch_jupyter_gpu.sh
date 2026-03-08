#!/bin/bash
# launch_jupyter_gpu.sh - GPU-enabled Jupyter Notebook launcher with TensorFlow GPU support

set -e

# Default port (can be changed by editing this variable)
PORT=8888

echo "Using port $PORT for Jupyter Notebook."

# Use sudo for Docker commands
DOCKER_CMD="sudo docker"

# Function to install NVIDIA Container Toolkit
install_nvidia_toolkit() {
    echo "Installing NVIDIA Container Toolkit..."
    
    # Add NVIDIA's repository (updated method without apt-key)
    distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    # Add the repository based on Ubuntu version
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    # Update and install
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    
    # Configure Docker to use NVIDIA runtime
    sudo nvidia-ctk runtime configure --runtime=docker
    
    # Restart Docker
    sudo systemctl restart docker
    
    echo "NVIDIA Container Toolkit installed and configured successfully!"
    
    # Wait for Docker to restart
    sleep 5
}

# Function to open browser in NEW WINDOW (not tab) and capture its PID
open_browser_new_window() {
    local url=$1
    echo "Opening browser in NEW WINDOW at $url"
    
    # Detect OS and open browser in new window
    case "$(uname -s)" in
        Linux)
            # Try different browsers with new-window flag
            if command -v google-chrome >/dev/null 2>&1; then
                google-chrome --new-window "$url" >/dev/null 2>&1 &
                browser_pid=$!
                echo $browser_pid > /tmp/jupyter_browser.pid
                echo "Browser PID: $browser_pid"
            elif command -v chrome-browser >/dev/null 2>&1; then
                chrome-browser --new-window "$url" >/dev/null 2>&1 &
                browser_pid=$!
                echo $browser_pid > /tmp/jupyter_browser.pid
            elif command -v firefox >/dev/null 2>&1; then
                firefox --new-window "$url" >/dev/null 2>&1 &
                browser_pid=$!
                echo $browser_pid > /tmp/jupyter_browser.pid
            elif command -v brave-browser >/dev/null 2>&1; then
                brave-browser --new-window "$url" >/dev/null 2>&1 &
                browser_pid=$!
                echo $browser_pid > /tmp/jupyter_browser.pid
            elif command -v chromium >/dev/null 2>&1; then
                chromium --new-window "$url" >/dev/null 2>&1 &
                browser_pid=$!
                echo $browser_pid > /tmp/jupyter_browser.pid
            elif command -v xdg-open >/dev/null 2>&1; then
                # Fallback to xdg-open but we can't guarantee new window
                xdg-open "$url" >/dev/null 2>&1 &
                echo "⚠️  Using xdg-open - may open in new tab"
                # Try to find the browser PID
                sleep 2
                browser_pid=$(pgrep -n "chrome|firefox|brave|opera|chromium" 2>/dev/null || echo "")
                if [ -n "$browser_pid" ]; then
                    echo $browser_pid > /tmp/jupyter_browser.pid
                fi
            else
                echo "⚠️  Could not detect browser. Please open $url manually in a NEW WINDOW."
            fi
            ;;
        Darwin)  # macOS
            # On macOS, open in new window
            open -na "Google Chrome" --args --new-window "$url" 2>/dev/null || \
            open -na "Firefox" --args --new-window "$url" 2>/dev/null || \
            open -na "Safari" "$url" 2>/dev/null &
            echo $! > /tmp/jupyter_browser.pid
            ;;
        CYGWIN*|MINGW*|MSYS*)  # Windows
            start "chrome" --new-window "$url" 2>/dev/null || \
            start "firefox" --new-window "$url" 2>/dev/null || \
            start "$url" 2>/dev/null &
            echo $! > /tmp/jupyter_browser.pid
            ;;
        *)
            echo "⚠️  Unsupported OS. Please open $url manually in a NEW WINDOW."
            ;;
    esac
}

# Function to wait for Jupyter to be ready
wait_for_jupyter() {
    local port=$1
    local max_attempts=30
    local attempt=1
    
    echo "Waiting for Jupyter to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s http://localhost:$port >/dev/null 2>&1; then
            echo "✅ Jupyter is ready!"
            return 0
        fi
        echo -n "."
        sleep 1
        attempt=$((attempt + 1))
    done
    echo ""
    echo "⚠️  Jupyter did not respond within $max_attempts seconds."
    return 1
}

# Function to monitor browser window and trigger git push when closed
monitor_browser_window() {
    local container_name=$1
    
    if [ ! -f /tmp/jupyter_browser.pid ]; then
        echo "⚠️  Browser PID not found."
        echo "   Please close the browser window manually and then run:"
        echo "   ./git_auto_push.sh $container_name manual"
        return
    fi
    
    browser_pid=$(cat /tmp/jupyter_browser.pid)
    
    # Verify the PID is still running
    if ! kill -0 $browser_pid 2>/dev/null; then
        echo "⚠️  Browser PID $browser_pid is not valid."
        rm -f /tmp/jupyter_browser.pid
        return
    fi
    
    echo "🖥️  Monitoring dedicated browser window (PID: $browser_pid)..."
    echo "   CLOSE THE BROWSER WINDOW when you're done working to trigger git backup"
    echo "   (This is a dedicated window - closing it will not affect your other browser tabs)"
    
    # Monitor the specific browser process
    while kill -0 $browser_pid 2>/dev/null; do
        sleep 2
    done
    
    echo ""
    echo "🔍 Browser window closed! Triggering git backup..."
    
    # Small delay to ensure any final saves are complete
    sleep 3
    
    # Call the git push script
    if [ -f "./git_auto_push.sh" ]; then
        chmod +x ./git_auto_push.sh
        ./git_auto_push.sh "window_closed"
    else
        echo "❌ git_auto_push.sh not found! Please create it."
    fi
    
    # Clean up
    rm -f /tmp/jupyter_browser.pid
}

# Check for NVIDIA GPU
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "Nvidia GPU detected, using TensorFlow GPU container..."
    CONTAINER_NAME="jupyter-tf-gpu"
    
    # Check if NVIDIA Container Toolkit is installed
    if ! $DOCKER_CMD info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
        echo "NVIDIA Container Toolkit not detected or not configured."
        read -p "Do you want to install NVIDIA Container Toolkit? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_nvidia_toolkit
        else
            echo "Cannot proceed without NVIDIA Container Toolkit. Exiting."
            exit 1
        fi
    fi
    
    # Check again after potential installation
    if $DOCKER_CMD info | grep -q "Runtimes:.*nvidia"; then
        echo "NVIDIA runtime detected, launching TensorFlow GPU container..."
        
        # Check if container already exists and remove it
        if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
            echo "Removing existing $CONTAINER_NAME container..."
            $DOCKER_CMD rm -f $CONTAINER_NAME
        fi
        
        # Use TensorFlow's official GPU Jupyter image
        echo "Pulling TensorFlow GPU Jupyter image..."
        $DOCKER_CMD pull tensorflow/tensorflow:2.15.0-gpu-jupyter
        
        # Run with GPU support
        $DOCKER_CMD run --gpus all -d \
            -p $PORT:8888 \
            -v "$(pwd):/tf/notebooks" \
            -w /tf/notebooks \
            --name $CONTAINER_NAME \
            --restart unless-stopped \
            tensorflow/tensorflow:2.15.0-gpu-jupyter \
            jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''
        
        echo "✅ Jupyter Notebook with TensorFlow GPU support is running!"
        
        # Wait for Jupyter to be ready
        if wait_for_jupyter $PORT; then
            # Open browser in NEW WINDOW
            open_browser_new_window "http://localhost:$PORT/tree"
        else
            echo "Please access it manually at: http://localhost:$PORT"
        fi
        
        # Show container logs
        echo ""
        echo "Container logs:"
        $DOCKER_CMD logs $CONTAINER_NAME --tail 10
        
        # Provide verification instructions
        echo ""
        echo "📝 To verify GPU is working, create a new notebook and run:"
        echo "import tensorflow as tf"
        echo "print('TensorFlow version:', tf.__version__)"
        echo "print('GPU Available:', tf.config.list_physical_devices('GPU'))"
        echo ""
        echo "If you see GPU devices listed, everything is working correctly!"
        
        # Monitor the dedicated browser window
        monitor_browser_window "$CONTAINER_NAME"
        
    else
        echo "Failed to configure NVIDIA runtime. Checking Docker runtime configuration..."
        $DOCKER_CMD info | grep -A 5 "Runtimes"
        echo ""
        echo "Please configure manually:"
        echo "sudo nvidia-ctk runtime configure --runtime=docker"
        echo "sudo systemctl restart docker"
        exit 1
    fi
else
    echo "No Nvidia GPU detected, using CPU-only TensorFlow container..."
    CONTAINER_NAME="jupyter-tf-cpu"
    
    # Check if container already exists and remove it
    if $DOCKER_CMD ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo "Removing existing $CONTAINER_NAME container..."
        $DOCKER_CMD rm -f $CONTAINER_NAME
    fi
    
    # Pull the CPU image
    echo "Pulling TensorFlow CPU Jupyter image..."
    $DOCKER_CMD pull tensorflow/tensorflow:2.15.0-jupyter
    
    # Run CPU version
    $DOCKER_CMD run -d \
        -p $PORT:8888 \
        -v "$(pwd):/tf/notebooks" \
        -w /tf/notebooks \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        tensorflow/tensorflow:2.15.0-jupyter \
        jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''
    
    echo "Jupyter Notebook with TensorFlow CPU is running!"
    
    # Wait for Jupyter to be ready
    if wait_for_jupyter $PORT; then
        # Open browser in NEW WINDOW
        open_browser_new_window "http://localhost:$PORT/tree"
    else
        echo "Please access it manually at: http://localhost:$PORT"
    fi
    
    # Show container logs
    echo ""
    echo "Container logs:"
    $DOCKER_CMD logs $CONTAINER_NAME --tail 10
    
    # Monitor the dedicated browser window
    monitor_browser_window "$CONTAINER_NAME"
fi

echo ""
echo "✨ Session ended. Container still running with: $DOCKER_CMD ps"
echo "✨ To stop the container later, run: $DOCKER_CMD stop $CONTAINER_NAME"
echo "✨ To start it again, run: $DOCKER_CMD start $CONTAINER_NAME"
echo "✨ To remove it, run: $DOCKER_CMD rm -f $CONTAINER_NAME"