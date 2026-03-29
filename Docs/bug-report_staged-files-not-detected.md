# Bug Report: Staged Files Not Detected During Push

## Summary

**Type:** Logic Error / Inconsistent State Detection  
**Severity:** High  
**Component:** Git Sync / Push Operations  
**Issue:** Staged files were detected by the recommended action system, but not included in the push operation, causing "No changes to index" errors even when changes existed.

---

## Symptom

1. User has staged files in their repository
2. App correctly shows "Staged or uncommitted files exist" (action 2)
3. When user triggers push/sync, it logs "No changes to index, skipping commit"
4. Files are NOT pushed to remote

---

## Root Cause

### The Bug

In `get_uncommitted_file_paths_priv()` function, the line:
```rust
opts.show(git2::StatusShow::Workdir);
```

This explicitly restricts the status check to **only working tree changes**, excluding index/staged changes.

### Why It Exists

The line was added by ViscousPot in commit `787b3a5` (Feb 15, 2026) titled "fix: update recommended action faster".

Likely intent was to optimize the function for a specific use case, but this created an **inconsistency**:
- `has_local_changes_priv()` - checks **both** index AND working tree
- `get_uncommitted_file_paths_priv()` - checks **only** working tree

When action 2 is triggered (by `has_local_changes_priv()` detecting changes), the push operation uses `get_uncommitted_file_paths_priv()` which can't see staged files!

### The Logic Gap

```
has_local_changes_priv()     → checks index + workdir → returns true (action 2)
get_uncommitted_file_paths() → checks only workdir   → returns 0 files
                                                         ↓
                                               "No changes to index"
```

---

## Fix

### Solution

Remove the `opts.show(git2::StatusShow::Workdir)` line from `get_uncommitted_file_paths_priv()`:

```rust
// REMOVED: opts.show(git2::StatusShow::Workdir);
```

This makes the function check **both** index AND working tree, matching the behavior of `has_local_changes_priv()`.

### Files Modified

| File | Line | Change |
|------|------|--------|
| `rust/src/api/git_manager.rs` | 4430 | Removed `opts.show(git2::StatusShow::Workdir)` |

---

## Related Bug Fix

This fix builds on an earlier incomplete fix. The first attempt (commit `20cee16` in branch `fix/uncommitted-files-detection`) added index status checking in the code logic:

```rust
let is_index_modified = status.intersects(Status::INDEX_NEW | Status::INDEX_MODIFIED | Status::INDEX_DELETED);
let is_wt_modified = status.intersects(Status::WT_NEW | Status::WT_MODIFIED | Status::WT_DELETED);
```

However, this fix alone wasn't sufficient because the `.show(StatusShow::Workdir)` line filters out index changes BEFORE they reach the status check. Both fixes are required.

---

## Testing

1. Stage a file using the app
2. Trigger a sync
3. Verify the file is committed and pushed to remote
4. Check logs for "Found X uncommitted files" message

---

## Branch

**Branch:** `fix/status-show-workdir`  
**Commit:** (pending)
