#!/bin/bash
# git_auto_push.sh - Git versioning and auto-push for Jupyter notebooks

set -e

# ==================== CONFIGURATION ====================
CONFIG_FILE="$HOME/.jupyter_git_config"
DEFAULT_BRANCH="main"
WORKSPACE_PATH="/tf/notebooks"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
# ========================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get container name from argument
if [ $# -eq 0 ]; then
    echo -e "${RED}❌ Error: Container name not provided${NC}"
    echo "Usage: $0 <container_name> [window_closed|manual]"
    exit 1
fi

CONTAINER_NAME="$1"
TRIGGER_REASON="${2:-}"  # Second argument indicates why script was called
DOCKER_CMD="sudo docker"

# Only proceed if triggered by window close or manual
if [ "$TRIGGER_REASON" != "window_closed" ] && [ "$TRIGGER_REASON" != "manual" ]; then
    echo -e "${YELLOW}⚠️  This script should only be called when browser window closes.${NC}"
    echo "Exiting..."
    exit 0
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}📦 Git Auto-Push for Jupyter Notebooks${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Container: $CONTAINER_NAME"
echo "Workspace: $WORKSPACE_PATH"
echo "Trigger: Browser window closed - backing up your work..."
echo ""

# ==================== SSH KEY MANAGEMENT ====================

# Function to setup SSH key on host
setup_ssh_key() {
    echo -e "${YELLOW}🔑 Setting up SSH key for GitHub...${NC}"
    
    # Check if SSH key already exists
    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo "No SSH key found. Generating one..."
        
        # Get email for SSH key
        read -p "Enter your GitHub email address: " github_email
        
        # Generate SSH key
        ssh-keygen -t ed25519 -C "$github_email" -f "$SSH_KEY_PATH" -N ""
        
        echo -e "${GREEN}✅ SSH key generated at $SSH_KEY_PATH${NC}"
    else
        echo -e "${GREEN}✅ SSH key already exists at $SSH_KEY_PATH${NC}"
    fi
    
    # Start ssh-agent and add key
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add "$SSH_KEY_PATH" 2>/dev/null || true
    
    # Display public key for GitHub
    echo ""
    echo -e "${YELLOW}📋 Your public SSH key (add this to GitHub):${NC}"
    echo "=================================================================="
    cat "$SSH_KEY_PATH.pub"
    echo "=================================================================="
    echo ""
    
    # Ask if user has added the key to GitHub
    read -p "Have you added this SSH key to GitHub? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Please add the key to GitHub first:${NC}"
        echo "1. Copy the key above"
        echo "2. Go to GitHub.com → Settings → SSH and GPG keys"
        echo "3. Click 'New SSH key', paste the key, and save"
        echo ""
        read -p "Press Enter once you've added the key to continue..."
    fi
    
    # Test SSH connection
    echo "Testing SSH connection to GitHub..."
    if ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1 | grep -q "successfully authenticated"; then
        echo -e "${GREEN}✅ SSH authentication successful!${NC}"
    else
        echo -e "${RED}❌ SSH authentication failed. Please check your setup.${NC}"
        exit 1
    fi
}

# Function to convert HTTPS remote to SSH
convert_to_ssh_remote() {
    local https_url=$1
    
    # Extract username and repo from HTTPS URL
    # https://github.com/username/repo.git -> git@github.com:username/repo.git
    if [[ "$https_url" =~ https://github.com/(.+)/(.+).git ]]; then
        local username="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        echo "git@github.com:$username/$repo.git"
    else
        # Return original if pattern doesn't match
        echo "$https_url"
    fi
}

# ==================== CONFIGURATION MANAGEMENT ====================

# Load saved configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}✅ Loaded saved configuration${NC}"
        echo "   Repository: $GITHUB_REPO"
        echo "   Branch: $CURRENT_BRANCH"
        echo ""
    else
        # First time setup - ask for repo and setup SSH
        echo -e "${PURPLE}========================================${NC}"
        echo -e "${CYAN}📊 First Time GitHub Repository Setup${NC}"
        echo -e "${PURPLE}========================================${NC}"
        
        # Setup SSH key first
        setup_ssh_key
        
        # Ask for repository
        read -p "Enter GitHub repository URL (HTTPS or SSH): " GITHUB_REPO
        
        # Convert HTTPS to SSH if needed
        if [[ "$GITHUB_REPO" == https://github.com/* ]]; then
            echo "Converting HTTPS URL to SSH format..."
            GITHUB_REPO=$(convert_to_ssh_remote "$GITHUB_REPO")
            echo "Using: $GITHUB_REPO"
        fi
        
        read -p "Enter branch name (default: $DEFAULT_BRANCH): " new_branch
        CURRENT_BRANCH="${new_branch:-$DEFAULT_BRANCH}"
        
        # Save configuration
        cat > "$CONFIG_FILE" << EOF
# Jupyter Git Auto-Push Configuration
# Last updated: $(date)
GITHUB_REPO="$GITHUB_REPO"
CURRENT_BRANCH="$CURRENT_BRANCH"
# SSH key: $SSH_KEY_PATH
EOF
        echo -e "${GREEN}✅ Configuration saved to $CONFIG_FILE${NC}"
        echo ""
    fi
}

# ==================== GIT OPERATIONS ====================

# Function to copy SSH keys into container
copy_ssh_keys_to_container() {
    echo "Copying SSH keys to container..."
    
    # Create .ssh directory in container
    $DOCKER_CMD exec $CONTAINER_NAME mkdir -p /root/.ssh
    
    # Copy SSH keys from host to container
    cat "$SSH_KEY_PATH" | $DOCKER_CMD exec -i $CONTAINER_NAME sh -c 'cat > /root/.ssh/id_ed25519'
    cat "$SSH_KEY_PATH.pub" | $DOCKER_CMD exec -i $CONTAINER_NAME sh -c 'cat > /root/.ssh/id_ed25519.pub'
    
    # Set correct permissions
    $DOCKER_CMD exec $CONTAINER_NAME chmod 600 /root/.ssh/id_ed25519
    $DOCKER_CMD exec $CONTAINER_NAME chmod 644 /root/.ssh/id_ed25519.pub
    
    # Add GitHub to known hosts
    $DOCKER_CMD exec $CONTAINER_NAME sh -c 'ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null'
    
    echo -e "${GREEN}✅ SSH keys copied to container${NC}"
}

# Function to fix directory ownership
fix_directory_ownership() {
    $DOCKER_CMD exec $CONTAINER_NAME git config --global --add safe.directory $WORKSPACE_PATH 2>/dev/null || true
}

# Function to initialize git in the container if needed
init_git() {
    echo -e "${YELLOW}Checking git configuration...${NC}"
    
    # Check if git is installed in container
    if ! $DOCKER_CMD exec $CONTAINER_NAME which git >/dev/null 2>&1; then
        echo "Installing git in container..."
        $DOCKER_CMD exec $CONTAINER_NAME apt-get update
        $DOCKER_CMD exec $CONTAINER_NAME apt-get install -y git
    fi
    
    # Copy SSH keys to container
    if [ -f "$SSH_KEY_PATH" ]; then
        copy_ssh_keys_to_container
    fi
    
    # Fix directory ownership
    fix_directory_ownership
    
    # Get system username and email (from host)
    HOST_USER=$(whoami)
    HOST_EMAIL="$HOST_USER@$(hostname)"
    
    # Configure git user in container (use host info)
    $DOCKER_CMD exec $CONTAINER_NAME git config --global user.name "$HOST_USER" 2>/dev/null || true
    $DOCKER_CMD exec $CONTAINER_NAME git config --global user.email "$HOST_EMAIL" 2>/dev/null || true
    
    echo -e "${GREEN}✅ Git configured with: $HOST_USER <$HOST_EMAIL>${NC}"
    
    # Check if git repo exists in workspace
    if ! $DOCKER_CMD exec $CONTAINER_NAME test -d "$WORKSPACE_PATH/.git"; then
        echo "Initializing git repository in workspace..."
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git init
        
        # Set default branch
        $DOCKER_CMD exec $CONTAINER_NAME git config --global init.defaultBranch "$DEFAULT_BRANCH"
        
        # Create .gitignore
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME bash -c "cat > .gitignore << 'EOF'
.ipynb_checkpoints/
*/.ipynb_checkpoints/*
__pycache__/
*.pyc
.DS_Store
.env
*.log
*.tmp
EOF"
        
        # Initial commit
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git add .
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git commit -m "Initial commit from Jupyter container"
        echo -e "${GREEN}✅ Git repository initialized${NC}"
    fi
}

# Function to setup remote
setup_remote() {
    if [ -n "$GITHUB_REPO" ]; then
        # Check if remote exists
        if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote | grep -q origin; then
            current_remote=$($DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote get-url origin 2>/dev/null)
            if [ "$current_remote" != "$GITHUB_REPO" ]; then
                echo "Updating remote URL..."
                $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote set-url origin "$GITHUB_REPO"
            fi
        else
            echo "Adding remote origin: $GITHUB_REPO"
            $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote add origin "$GITHUB_REPO"
        fi
    fi
}

# Function to handle branch
setup_branch() {
    if [ -z "$CURRENT_BRANCH" ]; then
        CURRENT_BRANCH="$DEFAULT_BRANCH"
    fi
    
    # Get current branch
    current_branch=$($DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "none")
    
    if [ "$current_branch" != "$CURRENT_BRANCH" ]; then
        echo "Setting up branch: $CURRENT_BRANCH"
        
        # Check if branch exists locally
        if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git show-ref --verify --quiet refs/heads/"$CURRENT_BRANCH"; then
            $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git checkout "$CURRENT_BRANCH"
        else
            # Check if branch exists remotely
            if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git ls-remote --heads origin "$CURRENT_BRANCH" 2>/dev/null | grep -q "$CURRENT_BRANCH"; then
                $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git checkout -b "$CURRENT_BRANCH" origin/"$CURRENT_BRANCH"
            else
                # Create new branch
                $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git checkout -b "$CURRENT_BRANCH"
            fi
        fi
        echo -e "${GREEN}✅ Switched to branch: $CURRENT_BRANCH${NC}"
    fi
}

# Function to commit and push changes
commit_and_push() {
    echo -e "${YELLOW}Checking for changes...${NC}"
    
    # Fix directory ownership again before git operations
    fix_directory_ownership
    
    # Check for changes
    changes=$($DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git status --porcelain 2>/dev/null || echo "")
    
    if [ -n "$changes" ]; then
        echo -e "${GREEN}📝 Changes detected:${NC}"
        echo "$changes" | while read line; do
            echo "  $line"
        done
        
        # Add all changes
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git add .
        
        # Create commit with timestamp
        commit_msg="Auto-commit: Notebook work saved on $(date '+%Y-%m-%d %H:%M:%S')"
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git commit -m "$commit_msg"
        echo -e "${GREEN}✅ Changes committed${NC}"
        
        # Push if remote is configured
        if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote | grep -q origin; then
            echo "Pushing to GitHub ($CURRENT_BRANCH)..."
            
            # Try to push (SSH should work automatically now)
            if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git push -u origin "$CURRENT_BRANCH" 2>/dev/null; then
                echo -e "${GREEN}✅ Successfully pushed to GitHub${NC}"
            else
                echo -e "${RED}❌ Failed to push to GitHub${NC}"
                echo "Testing SSH connection..."
                $DOCKER_CMD exec $CONTAINER_NAME ssh -T git@github.com -o StrictHostKeyChecking=accept-new || true
            fi
        else
            echo -e "${YELLOW}⚠️  No remote repository configured. Commit saved locally.${NC}"
        fi
    else
        echo -e "${GREEN}✅ No changes detected since last commit${NC}"
    fi
}

# Function to show final status
show_final_status() {
    echo -e "\n${BLUE}=== Git Status ===${NC}"
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git status --short 2>/dev/null || echo "No git repo"
    
    echo -e "\n${BLUE}=== Last Commit ===${NC}"
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git log --oneline -1 2>/dev/null || echo "No commits yet"
}

# ==================== MAIN EXECUTION ====================

main() {
    # Check if container is running
    if ! $DOCKER_CMD ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo -e "${RED}❌ Container $CONTAINER_NAME is not running!${NC}"
        exit 1
    fi
    
    # Initialize git
    init_git
    
    # Load or setup configuration
    load_config
    
    # Setup remote
    setup_remote
    
    # Setup branch
    setup_branch
    
    # Commit and push changes
    commit_and_push
    
    # Show final status
    show_final_status
    
    echo -e "\n${GREEN}✅ Your work has been backed up!${NC}"
    echo -e "${CYAN}Container is still running. You can:${NC}"
    echo "  - Start working again by opening http://localhost:8888"
    echo "  - Stop container: sudo docker stop $CONTAINER_NAME"
    echo "  - Remove container: sudo docker rm $CONTAINER_NAME"
}

# Run main function
main