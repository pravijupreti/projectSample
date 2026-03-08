#!/bin/bash
# git_auto_push.sh - Git versioning and auto-push for Jupyter notebooks
# RUNS ON HOST MACHINE - NOT IN CONTAINER!

set -e

# ==================== CONFIGURATION ====================
CONFIG_FILE="$HOME/.jupyter_git_config"
DEFAULT_BRANCH="main"
WORKSPACE_PATH="$(pwd)"  # Current directory on host
# ========================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get trigger reason from argument (container name no longer needed)
if [ $# -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No trigger reason provided, assuming manual trigger${NC}"
    TRIGGER_REASON="manual"
else
    TRIGGER_REASON="$1"
fi

# Only proceed if triggered by window close or manual
if [ "$TRIGGER_REASON" != "window_closed" ] && [ "$TRIGGER_REASON" != "manual" ]; then
    echo -e "${YELLOW}⚠️  This script should only be called when browser window closes.${NC}"
    echo "Exiting..."
    exit 0
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}📦 Git Auto-Push for Jupyter Notebooks${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Workspace: $WORKSPACE_PATH (on host)"
echo "Trigger: $TRIGGER_REASON - backing up your work..."
echo ""

# ==================== FIX PERMISSIONS AND LOCKS ====================

# Function to fix Git safe.directory issue
fix_safe_directory() {
    local dir="$1"
    
    # Check if we need to add this directory to safe.directory
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -q "^$dir$"; then
        echo "Adding $dir to Git safe.directory..."
        git config --global --add safe.directory "$dir"
        echo -e "${GREEN}✅ Directory added to safe list${NC}"
    fi
}

# Function to handle git lock files and permissions
fix_git_permissions() {
    local git_dir="$WORKSPACE_PATH/.git"
    
    # Check if .git directory exists
    if [ -d "$git_dir" ]; then
        echo "Checking git permissions..."
        
        # Fix ownership of .git directory (run with sudo if needed)
        if [ "$(stat -c '%U' "$git_dir")" != "$USER" ]; then
            echo "Fixing .git directory ownership..."
            sudo chown -R "$USER":"$USER" "$git_dir" 2>/dev/null || true
        fi
        
        # Remove stale lock files
        local lock_files=(
            "$git_dir/index.lock"
            "$git_dir/HEAD.lock"
            "$git_dir/refs/heads/*.lock"
            "$git_dir/refs/tags/*.lock"
            "$git_dir/refs/remotes/*/*.lock"
        )
        
        for lock_pattern in "${lock_files[@]}"; do
            # Use find to handle wildcards safely
            find "$git_dir" -path "$lock_pattern" -type f 2>/dev/null | while read -r lock_file; do
                # Check if the lock file is stale (older than 5 minutes)
                if [ -f "$lock_file" ]; then
                    lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_file") ))
                    if [ $lock_age -gt 300 ]; then  # 5 minutes = 300 seconds
                        echo "Removing stale lock file: $lock_file"
                        rm -f "$lock_file"
                    else
                        # Check if any git process is actually running
                        if ! pgrep -f "git.*$WORKSPACE_PATH" > /dev/null; then
                            echo "No git process found. Removing stale lock file: $lock_file"
                            rm -f "$lock_file"
                        fi
                    fi
                fi
            done
        done
        
        # Fix permissions on all git files
        find "$git_dir" -type f -exec chmod 644 {} \; 2>/dev/null || true
        find "$git_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
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
        # First time setup - ask for repo
        echo -e "${PURPLE}========================================${NC}"
        echo -e "${CYAN}📊 First Time GitHub Repository Setup${NC}"
        echo -e "${PURPLE}========================================${NC}"
        
        read -p "Enter GitHub repository URL: " GITHUB_REPO
        read -p "Enter branch name (default: $DEFAULT_BRANCH): " new_branch
        CURRENT_BRANCH="${new_branch:-$DEFAULT_BRANCH}"
        
        # Save configuration
        cat > "$CONFIG_FILE" << EOF
# Jupyter Git Auto-Push Configuration
# Last updated: $(date)
GITHUB_REPO="$GITHUB_REPO"
CURRENT_BRANCH="$CURRENT_BRANCH"
EOF
        echo -e "${GREEN}✅ Configuration saved to $CONFIG_FILE${NC}"
        echo ""
    fi
}

# ==================== GIT OPERATIONS ON HOST ====================

# Function to check if git repo exists on host
check_git_repo() {
    if [ ! -d ".git" ]; then
        echo "Initializing git repository on host..."
        git init
        git checkout -b "$CURRENT_BRANCH" 2>/dev/null || git checkout -b main
        
        # Create .gitignore
        cat > .gitignore << 'EOF'
.ipynb_checkpoints/
*/.ipynb_checkpoints/*
__pycache__/
*.pyc
.DS_Store
.env
*.log
*.tmp
EOF
        
        git add .
        git commit -m "Initial commit from Jupyter workspace" || true
        echo -e "${GREEN}✅ Git repository initialized on host${NC}"
    fi
}

# Function to setup remote on host
setup_remote() {
    if [ -n "$GITHUB_REPO" ]; then
        # Check if remote exists
        if git remote | grep -q origin; then
            current_remote=$(git remote get-url origin 2>/dev/null)
            if [ "$current_remote" != "$GITHUB_REPO" ]; then
                echo "Updating remote URL..."
                git remote set-url origin "$GITHUB_REPO"
            fi
        else
            echo "Adding remote origin: $GITHUB_REPO"
            git remote add origin "$GITHUB_REPO"
        fi
    fi
}

# Function to commit and push changes from HOST
commit_and_push() {
    echo -e "${YELLOW}Checking for changes on host...${NC}"
    
    # Try git status with retry on lock
    local max_retries=3
    local retry_count=0
    local changes=""
    
    while [ $retry_count -lt $max_retries ]; do
        changes=$(git status --porcelain 2>/dev/null || echo "LOCK_ERROR")
        
        if [ "$changes" != "LOCK_ERROR" ]; then
            break
        fi
        
        echo "Git is locked. Waiting 2 seconds... (Attempt $((retry_count+1))/$max_retries)"
        sleep 2
        retry_count=$((retry_count + 1))
        
        # Fix permissions on retry
        fix_git_permissions
    done
    
    if [ -n "$changes" ] && [ "$changes" != "LOCK_ERROR" ]; then
        echo -e "${GREEN}📝 Changes detected:${NC}"
        echo "$changes" | while read line; do
            echo "  $line"
        done
        
        # Add all changes
        git add .
        
        # Create commit with timestamp
        commit_msg="Auto-commit: Notebook work saved on $(date '+%Y-%m-%d %H:%M:%S')"
        git commit -m "$commit_msg"
        echo -e "${GREEN}✅ Changes committed on host${NC}"
        
        # Push if remote is configured
        if git remote | grep -q origin; then
            echo "Pushing to GitHub ($CURRENT_BRANCH) from host..."
            
            # Push from host (uses your host's git credentials!)
            if git push -u origin "$CURRENT_BRANCH" 2>&1; then
                echo -e "${GREEN}✅ Successfully pushed to GitHub${NC}"
            else
                echo -e "${RED}❌ Failed to push to GitHub${NC}"
                echo ""
                echo "Debugging:"
                echo "  - Make sure you're logged in to GitHub on your host"
                echo "  - Try running: git push origin $CURRENT_BRANCH"
            fi
        else
            echo -e "${YELLOW}⚠️  No remote repository configured. Commit saved locally.${NC}"
        fi
    elif [ "$changes" = "LOCK_ERROR" ]; then
        echo -e "${RED}❌ Git is locked and couldn't be accessed after $max_retries attempts${NC}"
        echo "Try running manually: rm -f .git/index.lock"
    else
        echo -e "${GREEN}✅ No changes detected since last commit${NC}"
    fi
}

# Function to show final status
show_final_status() {
    echo -e "\n${BLUE}=== Git Status ===${NC}"
    git status --short 2>/dev/null || echo "No git repo"
    
    echo -e "\n${BLUE}=== Last Commit ===${NC}"
    git log --oneline -1 2>/dev/null || echo "No commits yet"
    
    echo -e "\n${BLUE}=== Remote URL ===${NC}"
    git remote -v 2>/dev/null || echo "No remote"
}

# ==================== MAIN EXECUTION ====================

main() {
    # Go to the workspace directory on host
    cd "$WORKSPACE_PATH"
    
    # Fix Git safe.directory issue
    fix_safe_directory "$WORKSPACE_PATH"
    
    # Fix git permissions and remove stale locks
    fix_git_permissions
    
    # Check if git repo exists on host, initialize if needed
    check_git_repo
    
    # Load or setup configuration
    load_config
    
    # Setup remote on host
    setup_remote
    
    # Commit and push changes from host
    commit_and_push
    
    # Show final status
    show_final_status
    
    echo -e "\n${GREEN}✅ Your work has been backed up!${NC}"
}

# Run main function
main