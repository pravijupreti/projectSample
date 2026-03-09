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
        if [ "$(stat -c '%U' "$git_dir" 2>/dev/null)" != "$USER" ]; then
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

# Function to check if git repo exists on host and handle branch state
check_git_repo() {
    if [ ! -d ".git" ]; then
        echo "Initializing git repository on host..."
        git init
        
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
        return
    fi
    
    # Check for uncommitted changes first
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${YELLOW}📝 Uncommitted changes detected. Will handle them in commit phase.${NC}"
        # Don't try to switch branches with uncommitted changes
        return
    fi
    
    # Check if we're in detached HEAD state (only if no uncommitted changes)
    if ! git symbolic-ref HEAD >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Detached HEAD state detected. Fixing...${NC}"
        
        # Get the current commit hash
        CURRENT_COMMIT=$(git rev-parse HEAD)
        
        # Check if branch already exists
        if git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
            echo "Branch '$CURRENT_BRANCH' exists. Switching to it..."
            git checkout "$CURRENT_BRANCH"
            
            # Check if the detached commit is already in the branch
            if ! git merge-base --is-ancestor "$CURRENT_COMMIT" "$CURRENT_BRANCH" 2>/dev/null; then
                echo "The detached commit is not in the branch. Cherry-picking..."
                git cherry-pick "$CURRENT_COMMIT" || echo "Cherry-pick failed, but continuing..."
            fi
        else
            echo "Creating branch '$CURRENT_BRANCH' from detached HEAD..."
            git branch "$CURRENT_BRANCH" "$CURRENT_COMMIT"
            git checkout "$CURRENT_BRANCH"
        fi
        echo -e "${GREEN}✅ Now on branch: $CURRENT_BRANCH${NC}"
    else
        # We're on a branch, get its name
        CURRENT_BRANCH_NAME=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
        echo -e "${GREEN}✅ On branch: $CURRENT_BRANCH_NAME${NC}"
        
        # If on a different branch than configured, and no uncommitted changes
        if [ "$CURRENT_BRANCH_NAME" != "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH_NAME" != "unknown" ]; then
            echo "Switching to configured branch: $CURRENT_BRANCH"
            
            # Check if configured branch exists locally
            if git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
                git checkout "$CURRENT_BRANCH"
            else
                # Create the branch from current HEAD
                git checkout -b "$CURRENT_BRANCH"
            fi
            echo -e "${GREEN}✅ Switched to branch: $CURRENT_BRANCH${NC}"
        fi
    fi
    
    # Check if the configured branch exists locally
    if ! git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
        echo "Local branch '$CURRENT_BRANCH' does not exist. Creating it..."
        git checkout -b "$CURRENT_BRANCH" 2>/dev/null || git branch "$CURRENT_BRANCH"
        echo -e "${GREEN}✅ Created local branch: $CURRENT_BRANCH${NC}"
    fi
    
    # Ensure we're on the correct branch
    current_local_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_local_branch" != "$CURRENT_BRANCH" ]; then
        echo "Switching to branch: $CURRENT_BRANCH"
        git checkout "$CURRENT_BRANCH" 2>/dev/null || true
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
# Function to commit and push changes from HOST
commit_and_push() {
    echo -e "${YELLOW}Checking for changes on host...${NC}"
    
    # First, handle detached HEAD state by switching to existing branch if possible
    CURRENT_BRANCH_NAME=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
    
    if [ "$CURRENT_BRANCH_NAME" = "detached" ]; then
        echo -e "${YELLOW}⚠️  In detached HEAD state."
        
        # Check if the configured branch already exists
        if git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
            echo "Branch '$CURRENT_BRANCH' exists. Switching to it..."
            # Stash any uncommitted changes if needed
            if [ -n "$(git status --porcelain)" ]; then
                echo "Stashing uncommitted changes before switching branches..."
                git stash push -m "auto-stash before branch switch"
                git checkout "$CURRENT_BRANCH"
                git stash pop || true
            else
                git checkout "$CURRENT_BRANCH"
            fi
        else
            echo "Creating new branch '$CURRENT_BRANCH' from detached HEAD..."
            git checkout -b "$CURRENT_BRANCH"
        fi
        echo -e "${GREEN}✅ Now on branch: $CURRENT_BRANCH${NC}"
    fi
    
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
<<<<<<< Updated upstream
        git commit -m "$commit_msg"
        echo -e "${GREEN}✅ Changes committed on host${NC}"
        
        # Push if remote is configured
        if git remote | grep -q origin; then
            echo "Pushing to GitHub ($CURRENT_BRANCH) from host..."
            
            # First, try to pull any remote changes (with rebase)
            echo "Checking for remote changes..."
            if git fetch origin "$CURRENT_BRANCH" 2>/dev/null; then
                # Check if local is behind remote
                LOCAL=$(git rev-parse HEAD)
                REMOTE=$(git rev-parse origin/"$CURRENT_BRANCH" 2>/dev/null || echo "")
                
                if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
                    echo "Remote has changes. Pulling and rebasing..."
                    if git pull --rebase origin "$CURRENT_BRANCH" 2>&1; then
                        echo -e "${GREEN}✅ Successfully pulled remote changes${NC}"
                    else
                        echo -e "${YELLOW}⚠️  Pull failed, but will try push anyway${NC}"
                    fi
                fi
            fi
            
            # Check if branch exists on remote
            if git ls-remote --heads origin "$CURRENT_BRANCH" | grep -q "$CURRENT_BRANCH"; then
                echo "Branch '$CURRENT_BRANCH' exists on remote. Pushing to existing branch..."
                if git push origin "$CURRENT_BRANCH" 2>&1; then
                    echo -e "${GREEN}✅ Successfully pushed to GitHub${NC}"
                else
                    echo -e "${RED}❌ Failed to push to GitHub${NC}"
                    echo ""
                    echo "Debugging:"
                    echo "  - Make sure you're logged in to GitHub on your host"
                    echo "  - Try running: git pull origin $CURRENT_BRANCH --rebase"
                    echo "  - Then try: git push origin $CURRENT_BRANCH"
                fi
            else
                echo "Branch '$CURRENT_BRANCH' does not exist on remote. Creating and pushing new branch..."
                if git push -u origin "$CURRENT_BRANCH" 2>&1; then
                    echo -e "${GREEN}✅ Successfully created and pushed new branch '$CURRENT_BRANCH' to GitHub${NC}"
                else
                    echo -e "${RED}❌ Failed to push new branch to GitHub${NC}"
                fi
=======
        if git commit -m "$commit_msg"; then
            echo -e "${GREEN}✅ Changes committed on host${NC}"
        else
            echo -e "${YELLOW}⚠️  No changes to commit${NC}"
        fi
    fi
    
    # Always try to push (even if no new commits, there might be unpushed ones)
    if git remote | grep -q origin; then
        echo "Pushing to GitHub ($CURRENT_BRANCH) from host..."
        
        # Ensure we're on the correct branch
        CURRENT_BRANCH_NAME=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
        
        if [ "$CURRENT_BRANCH_NAME" = "detached" ]; then
            echo -e "${RED}❌ Still in detached HEAD. This should not happen.${NC}"
            # Try to checkout existing branch
            if git show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
                git checkout "$CURRENT_BRANCH"
            else
                git checkout -b "$CURRENT_BRANCH"
>>>>>>> Stashed changes
            fi
        elif [ "$CURRENT_BRANCH_NAME" != "$CURRENT_BRANCH" ]; then
            echo "Switching to branch $CURRENT_BRANCH before push..."
            git checkout "$CURRENT_BRANCH"
        fi
        
        # Check if remote branch exists
        if git ls-remote --heads origin "$CURRENT_BRANCH" 2>/dev/null | grep -q "$CURRENT_BRANCH"; then
            # Branch exists, just push
            PUSH_CMD="git push origin $CURRENT_BRANCH"
        else
            # Branch doesn't exist, set upstream
            PUSH_CMD="git push -u origin $CURRENT_BRANCH"
        fi
        
        echo "Running: $PUSH_CMD"
        
        # Execute push command
        if $PUSH_CMD 2>&1; then
            echo -e "${GREEN}✅ Successfully pushed to GitHub${NC}"
        else
            echo -e "${RED}❌ Failed to push to GitHub${NC}"
            echo ""
            echo "Debugging:"
            echo "  - Current branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
            echo "  - Remote URL: $(git remote get-url origin 2>/dev/null || echo 'unknown')"
            echo "  - Try manually: $PUSH_CMD"
            echo "  - If remote has changes, try: git pull origin $CURRENT_BRANCH --rebase"
        fi
    else
        echo -e "${YELLOW}⚠️  No remote repository configured. Commit saved locally.${NC}"
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
    
    echo -e "\n${BLUE}=== Current Branch ===${NC}"
    git branch --show-current 2>/dev/null || echo "No branch"
    
    echo -e "\n${BLUE}=== Unpushed Commits ===${NC}"
    if git status 2>/dev/null | grep -q "Your branch is ahead"; then
        git log @{u}.. 2>/dev/null || echo "No upstream branch"
    else
        echo "No unpushed commits"
    fi
}

# ==================== MAIN EXECUTION ====================

main() {
    # Go to the workspace directory on host
    cd "$WORKSPACE_PATH"
    
    # Fix Git safe.directory issue
    fix_safe_directory "$WORKSPACE_PATH"
    
    # Fix git permissions and remove stale locks
    fix_git_permissions
    
    # Load or setup configuration
    load_config
    
    # Check if git repo exists on host and handle branch state
    check_git_repo
    
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