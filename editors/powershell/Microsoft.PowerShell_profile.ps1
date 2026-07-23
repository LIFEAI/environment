# PowerShell profile — managed additions below.

# regen-root: auto-isolate ad-hoc Claude sessions into a warm worktree pool.
# Typing `claude` claims a warm pool slot (claude-1..N), cd's into it, and runs
# plain claude there. SAFE in the supervisor shell: claude-iso.ps1 passes through
# (plain claude on the main tree) when CELL_ROLE=sv, when already inside a
# *.wt/* worktree, or for -p/--print runs. Bypass once with `claude.cmd ...`.
function claude { & 'C:/Dev/regen-root/scripts/claude-iso.ps1' @args }
