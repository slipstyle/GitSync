# Bug Report: Detached HEAD State - Detection and Auto-Recovery

## Summary

**Type:** Sync Failure  
**Severity:** High  
**Component:** Git Sync / HEAD State  
**Error Message:** "DETACHED HEAD" shown in app UI

## What is Detached HEAD?

In normal git, HEAD points to a branch (e.g., "main" or "master"). When HEAD is detached, it points directly to a commit with no branch association.

```
Normal:  HEAD -> refs/heads/master -> commit abc123
Detached HEAD:  HEAD -> commit abc123 (no branch)
```

## How It Happens

1. **Merge conflict resolution fails** - The commit operation fails partway through
2. **Corrupted git objects** - Corrupted loose objects or rebase state corrupt HEAD reference
3. **Race conditions** - Concurrent operations leave HEAD in inconsistent state

## Current App Behavior

### Detection

The app detects detached HEAD via `get_branch_name_priv()` in `rust/src/api/git_manager.rs`:

```rust
fn get_branch_name_priv(repo: &Repository) -> Option<String> {
    let head = match repo.head() {
        Ok(h) => h,
        Err(_) => return None,
    };

    if head.is_branch() {
        return Some(head.shorthand().unwrap().to_string());
    }
    // Also checks for remote branches...
    None  // Not a branch = detached HEAD
}
```

The key check is `head.is_branch()` - this returns false when HEAD is detached.

### Manual Recovery (Current)

When detached HEAD is detected:
- Sync is blocked with warning message
- User can use the branch dropdown to select main/master
- WARNING: This orphans local commits (see bug-report_detached-head-dropdown-data-loss.md)

## Planned Implementation: Auto-Recovery

### Function: `ensure_head_attached()`

Location: `rust/src/api/git_manager.rs`

```rust
fn ensure_head_attached(repo: &Repository) -> Result<bool, git2::Error> {
    // 1. Check if already attached
    if !repo.head_detached()? {
        return Ok(false);
    }

    // 2. Get current commit OID
    let head = repo.head()?;
    let current_oid = head.target()
        .ok_or_else(|| git2::Error::from_str("Could not get HEAD target"))?;

    // 3. Scan ALL branches for matching commit
    let mut matching_branches: Vec<String> = Vec::new();
    let branches = repo.branches(Some(BranchType::Local))?;
    for branch_result in branches {
        let (branch, _) = branch_result?;
        if let Some(name) = branch.name().ok().flatten() {
            if let Ok(commit) = branch.peel_to_commit() {
                if commit.id() == current_oid {
                    matching_branches.push(name.to_string());
                }
            }
        }
    }

    // 4. Decision based on match count
    match matching_branches.len() {
        0 => Err(git2::Error::from_str(
            "Detached HEAD: no branch contains current commit"
        )),
        1 => {
            // Safe: exactly one match - auto-recover
            repo.set_head(&format!("refs/heads/{}", matching_branches[0]))?;
            Ok(true)
        }
        _ => Err(git2::Error::from_str(&format!(
            "Detached HEAD: current commit is on {} branches: {}. Choose manually.",
            matching_branches.len(),
            matching_branches.join(", ")
        ))),
    }
}
```

### Integration Points

| Function | Where to Call | Purpose |
|----------|---------------|---------|
| `pull_changes_priv()` | Start of function | Recover before pull |
| `push_changes_priv()` | After opening repo | Recover before push |
| `upload_changes()` | After opening repo | Recover before staging |

### Behavior

| Scenario | Action |
|----------|--------|
| 0 branches contain commit | Return error → triggers existing DETACHED HEAD UI |
| 1 branch contains commit | Auto-recover silently, continue sync |
| 2+ branches contain commit | Return error → triggers existing DETACHED HEAD UI |

### Why Scan ALL Branches?

We scan ALL branches because:
- Need full list to know if 1 match (safe auto-recover) or 2+ (must fail to UI)
- User may need to know all possible branches to choose manually
- Single-pass scan is simpler and sufficient

## Related Issues

- bug-report_detached-head-dropdown-data-loss.md
- bug-report_malformed-rebase-refspec.md
- bug-report_corrupted-loose-objects.md
