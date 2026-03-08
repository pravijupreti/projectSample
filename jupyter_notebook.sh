#!/bin/bash
set -euo pipefail

# -----------------------------
# Detect OS
# -----------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Cannot detect OS"
    exit 1
fi
echo "OS: $NAME"

# -----------------------------
# Sync system time
# -----------------------------
echo "Synchronizing system time..."
if command -v timedatectl >/dev/null 2>&1; then
    sudo timedatectl set-ntp true || true
fi
sleep 2

# -----------------------------
# Detect package manager
# -----------------------------
case "$ID" in
    ubuntu|debian) PKG="apt" ;;
    fedora) PKG="dnf" ;;
    arch) PKG="pacman" ;;
    rhel|centos) PKG="yum" ;;
    opensuse*) PKG="zypper" ;;
    *) echo "Unsupported OS"; exit 1 ;;
esac
echo "Package manager: $PKG"

# -----------------------------
# Function to check if Docker is already installed and working
# -----------------------------
check_docker_installed() {
    # Check if docker command exists
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi
    
    # Check if docker service is running
    if command -v systemctl >/dev/null 2>&1; then
        if ! sudo systemctl is-active --quiet docker 2>/dev/null; then
            return 1
        fi
    fi
    
    # Check if we can run docker commands
    if ! sudo docker info >/dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# -----------------------------
# Check if Docker is already installed
# -----------------------------
if check_docker_installed; then
    echo "✅ Docker is already installed and running: $(sudo docker --version | cut -d, -f1)"
else
    echo "Docker not found or not running. Installing..."

    # -----------------------------
    # Remove old Docker installs (only if we're going to reinstall)
    # -----------------------------
    echo "Removing old Docker versions..."
    case "$PKG" in
        apt) 
            sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            sudo apt remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
            sudo rm -rf /var/lib/docker /etc/docker
            ;;
        dnf|yum) sudo "$PKG" remove -y docker* || true ;;
        pacman) sudo pacman -Rns --noconfirm docker || true ;;
        zypper) sudo zypper remove -y docker || true ;;
    esac

    # -----------------------------
    # Install Docker
    # -----------------------------
    echo "Installing Docker..."
    case "$PKG" in
        apt)
            sudo apt update
            sudo apt install -y ca-certificates curl gnupg lsb-release
            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf|yum) sudo "$PKG" install -y docker ;;
        pacman) sudo pacman -S --noconfirm docker ;;
        zypper) sudo zypper install -y docker ;;
    esac

    # -----------------------------
    # Start and verify Docker service
    # -----------------------------
    if command -v systemctl >/dev/null 2>&1; then
        echo "Starting Docker service..."
        sudo systemctl enable docker
        sudo systemctl start docker
        
        # Wait a moment for Docker to start
        sleep 3
        
        # Verify Docker is running
        if ! sudo systemctl is-active --quiet docker; then
            echo "Docker service failed to start"
            sudo systemctl status docker --no-pager
            exit 1
        fi
        echo "Docker service is running"
    fi

    echo "Docker installed: $(sudo docker --version | cut -d, -f1)"
fi

# -----------------------------
# Add user to docker group (only if not already in group)
# -----------------------------
USE_SUDO="sudo"
if ! groups "$USER" 2>/dev/null | grep -q docker; then
    sudo usermod -aG docker "$USER"
    echo "Added $USER to docker group. Log out and back in to use Docker without sudo."
else
    # Check if we can run without sudo (after group changes take effect)
    if docker info >/dev/null 2>&1; then
        USE_SUDO=""
        echo "✅ Can run Docker without sudo"
    fi
fi

# -----------------------------
# Export USE_SUDO for child scripts
# -----------------------------
export USE_SUDO

# -----------------------------
# Wait for Docker daemon
# -----------------------------
echo "Waiting for Docker daemon..."
MAX_RETRIES=10
RETRY_DELAY=3
for ((i=1; i<=MAX_RETRIES; i++)); do
    if sudo docker info >/dev/null 2>&1; then
        echo "Docker daemon is running."
        break
    fi
    echo "Retry $i/$MAX_RETRIES..."
    sleep "$RETRY_DELAY"
    
    if [ $i -eq $MAX_RETRIES ]; then
        echo "Docker daemon failed to start"
        sudo journalctl -u docker --no-pager -n 20
        exit 1
    fi
done

# -----------------------------
# Test Docker container (only if we haven't tested before)
# -----------------------------
echo "Running test container..."
if sudo docker run --rm hello-world >/dev/null 2>&1; then
    echo "✅ Docker test container ran successfully!"
else
    echo "Docker test failed"
    sudo docker run --rm hello-world
    exit 1
fi

echo "✅ Docker is ready!"

# -----------------------------
# Check if Jupyter container already exists
# -----------------------------
CONTAINER_NAME="jupyter-tf-gpu"
if sudo docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "✅ Jupyter container '$CONTAINER_NAME' already exists"
    if ! sudo docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo "Starting existing container..."
        sudo docker start $CONTAINER_NAME
    else
        echo "Container already running"
    fi
fi

# -----------------------------
# Launch GPU-enabled Jupyter Notebook
# -----------------------------
if [ -f ./launch_jupyter_gpu.sh ]; then
    echo "Launching GPU-enabled Jupyter Notebook..."
    chmod +x ./launch_jupyter_gpu.sh
    bash ./launch_jupyter_gpu.sh
else
    echo "launch_jupyter_gpu.sh not found. Please create it to launch Jupyter Notebook."
fi