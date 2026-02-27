# Makefile for formatting and maintenance
# Uses npx (no installation required - just needs Node.js)

.PHONY: format check help git-force git-reset

# Default target
help:
	@echo "Available commands:"
	@echo "  make format    - Format all markdown files"
	@echo "  make check     - Dry-run format (show what would change)"
	@echo "  make git-force - Safely force push to remote using --force-with-lease"
	@echo "  make git-reset - Reset HEAD to the previous commit"

# Format all markdown files (no install needed - uses npx)
format:
	npx prettier --write "**/*.md" --prose-wrap always --print-width 125

# Check formatting without making changes
check:
	npx prettier --check "**/*.md" --prose-wrap always --print-width 125

git-force: ## Safely force push to remote using --force-with-lease
	@echo "Performing safe force push to remote..."
	@echo "This will push local commits and overwrite remote ONLY if remote hasn't changed since last fetch."
	@echo ""
	@git status --porcelain | grep -q . && echo "Warning: You have unstaged changes. Consider committing them first." || true
	@echo "Pushing with --force-with-lease..."
	git push --force-with-lease

git-reset: ## Reset HEAD to the previous commit
	@echo "Resetting HEAD to the previous commit..."
	git reset --soft HEAD~1
