#!/bin/bash
# git_auto_push.sh - Git versioning and auto-push for Jupyter notebooks
# This script is called by launch_jupyter_gpu.sh when browser closes

set -e

# ==================== CONFIGURATION ====================
CONFIG_FILE="$HOME/.jupyter_git_config"
DEFAULT_BRANCH="main"
WORKSPACE_PATH="/tf/notebooks"
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
    echo "Usage: $0 <container_name>"
    exit 1
fi

CONTAINER_NAME="$1"
DOCKER_CMD="sudo docker"

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
        GITHUB_REPO=""
        CURRENT_BRANCH="$DEFAULT_BRANCH"
    fi
}

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Jupyter Git Auto-Push Configuration
# Last updated: $(date)
GITHUB_REPO="$GITHUB_REPO"
CURRENT_BRANCH="$CURRENT_BRANCH"
EOF
    echo -e "${GREEN}✅ Configuration saved to $CONFIG_FILE${NC}"
}

# ==================== BRANCH MANAGEMENT ====================

# Get current branch from container
get_current_branch() {
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# List available branches
list_branches() {
    echo -e "${CYAN}Available branches:${NC}"
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git branch -a 2>/dev/null | sed 's/^/  /'
}

# Create new branch
create_branch() {
    local new_branch=$1
    echo -e "${YELLOW}Creating new branch: $new_branch${NC}"
    
    # Create and switch to new branch
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git checkout -b "$new_branch"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Created and switched to branch: $new_branch${NC}"
        CURRENT_BRANCH="$new_branch"
        save_config
    else
        echo -e "${RED}❌ Failed to create branch${NC}"
        return 1
    fi
}

# Switch branch
switch_branch() {
    local target_branch=$1
    
    # Check if branch exists locally
    if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git show-ref --verify --quiet refs/heads/"$target_branch"; then
        echo -e "${YELLOW}Switching to existing branch: $target_branch${NC}"
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git checkout "$target_branch"
    else
        # Check if branch exists remotely
        if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git ls-remote --heads origin "$target_branch" | grep -q "$target_branch"; then
            echo -e "${YELLOW}Switching to remote branch: $target_branch${NC}"
            $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git checkout -b "$target_branch" origin/"$target_branch"
        else
            echo -e "${RED}❌ Branch '$target_branch' does not exist${NC}"
            return 1
        fi
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Switched to branch: $target_branch${NC}"
        CURRENT_BRANCH="$target_branch"
        save_config
    else
        echo -e "${RED}❌ Failed to switch branch${NC}"
        return 1
    fi
}

# ==================== REPOSITORY SETUP ====================

# Configure git user if needed
setup_git_user() {
    if ! $DOCKER_CMD exec $CONTAINER_NAME git config --global user.name >/dev/null 2>&1; then
        echo -e "${YELLOW}First time setup - Configure git user:${NC}"
        read -p "Enter your git user name: " git_user
        read -p "Enter your git email: " git_email
        $DOCKER_CMD exec $CONTAINER_NAME git config --global user.name "$git_user"
        $DOCKER_CMD exec $CONTAINER_NAME git config --global user.email "$git_email"
        echo -e "${GREEN}✅ Git user configured${NC}"
    fi
}

# Setup or update repository
setup_repository() {
    local repo_url=$1
    
    # Check if remote exists
    if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote | grep -q origin; then
        current_remote=$($DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote get-url origin)
        
        if [ "$current_remote" != "$repo_url" ]; then
            echo -e "${YELLOW}Remote URL differs:${NC}"
            echo "  Current: $current_remote"
            echo "  New: $repo_url"
            read -p "Update remote URL? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote set-url origin "$repo_url"
                echo -e "${GREEN}✅ Remote URL updated${NC}"
            fi
        fi
    else
        echo "Adding remote origin: $repo_url"
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote add origin "$repo_url"
    fi
}

# ==================== GIT OPERATIONS ====================

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
    
    # Fix directory ownership
    fix_directory_ownership
    
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
    
    # Setup git user
    setup_git_user
}

# Function to ask about repository
ask_repo_config() {
    echo -e "\n${PURPLE}========================================${NC}"
    echo -e "${CYAN}📊 GitHub Repository Configuration${NC}"
    echo -e "${PURPLE}========================================${NC}"
    
    if [ -n "$GITHUB_REPO" ]; then
        echo -e "Current repository: ${GREEN}$GITHUB_REPO${NC}"
        echo -e "Current branch: ${GREEN}$CURRENT_BRANCH${NC}"
        echo ""
        echo "1) Use same repository and branch"
        echo "2) Change repository (use different repo)"
        echo "3) Change branch only"
        read -p "Select option (1-3): " repo_option
        
        case $repo_option in
            1)
                echo -e "${GREEN}✅ Using existing configuration${NC}"
                ;;
            2)
                read -p "Enter new GitHub repository URL: " new_repo
                GITHUB_REPO="$new_repo"
                read -p "Enter branch name (default: $DEFAULT_BRANCH): " new_branch
                CURRENT_BRANCH="${new_branch:-$DEFAULT_BRANCH}"
                save_config
                ;;
            3)
                ask_branch_config
                ;;
            *)
                echo -e "${RED}Invalid option, using existing configuration${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}No repository configured yet.${NC}"
        read -p "Enter GitHub repository URL: " GITHUB_REPO
        read -p "Enter branch name (default: $DEFAULT_BRANCH): " new_branch
        CURRENT_BRANCH="${new_branch:-$DEFAULT_BRANCH}"
        save_config
    fi
}

# Function to ask about branch
ask_branch_config() {
    echo -e "\n${CYAN}📌 Branch Management${NC}"
    echo "Current branch: $(get_current_branch)"
    echo ""
    echo "1) Stay on current branch"
    echo "2) Switch to existing branch"
    echo "3) Create new branch"
    echo "4) List all branches"
    read -p "Select option (1-4): " branch_option
    
    case $branch_option in
        1)
            echo -e "${GREEN}✅ Staying on current branch${NC}"
            CURRENT_BRANCH=$(get_current_branch)
            ;;
        2)
            list_branches
            read -p "Enter branch name to switch to: " target_branch
            switch_branch "$target_branch"
            ;;
        3)
            read -p "Enter new branch name: " new_branch
            create_branch "$new_branch"
            ;;
        4)
            list_branches
            ask_branch_config  # Recursively ask again
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ask_branch_config
            ;;
    esac
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
        
        # Ask for commit message
        echo ""
        echo "1) Use auto-generated commit message"
        echo "2) Write custom commit message"
        read -p "Select option (1-2): " commit_option
        
        case $commit_option in
            1)
                commit_msg="Auto-commit: Notebook work on $(date '+%Y-%m-%d %H:%M:%S')"
                ;;
            2)
                read -p "Enter commit message: " commit_msg
                ;;
            *)
                commit_msg="Auto-commit: Notebook work on $(date '+%Y-%m-%d %H:%M:%S')"
                ;;
        esac
        
        # Add all changes
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git add .
        
        # Create commit
        $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git commit -m "$commit_msg"
        echo -e "${GREEN}✅ Changes committed${NC}"
        
        # Push if remote is configured
        if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git remote | grep -q origin; then
            echo "Pushing to GitHub ($CURRENT_BRANCH)..."
            
            # Push to current branch
            if $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git push -u origin "$CURRENT_BRANCH"; then
                echo -e "${GREEN}✅ Successfully pushed to GitHub${NC}"
            else
                echo -e "${RED}❌ Failed to push to GitHub${NC}"
                echo "You may need to set up authentication:"
                echo "  Run: $DOCKER_CMD exec -it $CONTAINER_NAME bash"
                echo "  Then run: git config --global credential.helper store"
                echo "  Then push manually: git push origin $CURRENT_BRANCH"
            fi
        else
            echo -e "${YELLOW}⚠️  No remote repository configured. Commit saved locally.${NC}"
        fi
    else
        echo -e "${GREEN}✅ No changes detected since last commit${NC}"
    fi
}

# Function to show status
show_status() {
    echo -e "\n${BLUE}=== Git Status ===${NC}"
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git status
    
    echo -e "\n${BLUE}=== Recent Commits ===${NC}"
    $DOCKER_CMD exec -w $WORKSPACE_PATH $CONTAINER_NAME git log --oneline -5 2>/dev/null || echo "No commits yet"
    
    echo -e "\n${BLUE}=== Current Branch ===${NC}"
    echo "$(get_current_branch)"
}

# ==================== MAIN EXECUTION ====================

main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}📦 Git Auto-Push for Jupyter Notebooks${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Container: $CONTAINER_NAME"
    echo "Workspace: $WORKSPACE_PATH"
    echo ""
    
    # Check if container is running
    if ! $DOCKER_CMD ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        echo -e "${RED}❌ Container $CONTAINER_NAME is not running!${NC}"
        exit 1
    fi
    
    # Load saved configuration
    load_config
    
    # Initialize git if needed
    init_git
    
    # Ask for repository configuration
    ask_repo_config
    
    # Setup repository with selected URL
    setup_repository "$GITHUB_REPO"
    
    # Switch to configured branch if needed
    current_branch=$(get_current_branch)
    if [ "$current_branch" != "$CURRENT_BRANCH" ]; then
        echo -e "${YELLOW}Switching to configured branch: $CURRENT_BRANCH${NC}"
        switch_branch "$CURRENT_BRANCH" || true
    fi
    
    # Show status
    show_status
    
    # Ask if user wants to push changes
    echo ""
    read -p "Push changes to GitHub now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        commit_and_push
    else
        echo -e "${YELLOW}Changes committed locally. Run this script again to push.${NC}"
    fi
    
    echo -e "\n${GREEN}✅ Git operations completed!${NC}"
    echo -e "${CYAN}Configuration saved for next time.${NC}"
}

# Run main function
main