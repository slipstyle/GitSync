# Bug Fixes Summary - Release 2026-03-23

This document summarizes all bug fixes implemented in the release.

## Bugs Fixed

### 1. Malformed Rebase Refspec

**Error:** `src refspec 'refs/heads/HEAD' does not match any existing object`

**Root Cause:** When reading the rebase state file `.git/rebase-merge/head-name`, the code didn't validate the content. If the file contained malformed content (like just "HEAD" instead of "refs/heads/master"), the push would fail.

**Fix:** Added validation in both `push_changes_priv()` and `download_and_overwrite()` to check if the rebase ref content is valid. If empty, "HEAD", or malformed, it falls back to determining the branch from current HEAD.

**Files Modified:**
- `rust/src/api/git_manager.rs:2260-2273` (push_changes_priv)
- `rust/src/api/git_manager.rs:3456-3479` (download_and_overwrite)

**See:** `bug-report_malformed-rebase-refspec.md`

---

### 2. Corrupted Loose Objects (Invalid Header)

**Error:** `failed to parse loose object: invalid header`

**Root Cause:** The `prune_corrupted_loose_objects()` function only handled "failed to parse loose object" errors, but not "invalid header" errors. Both indicate corrupted loose objects that should be pruned.

**Fix:** Extended error detection to handle both error messages.

**Files Modified:**
- `rust/src/api/git_manager.rs:4367` (prune_corrupted_loose_objects)

**See:** `bug-report_corrupted-loose-objects.md`

---

### 3. Race Condition (File Changed Before Read)

**Error:** `file changed before we could read it`

**Root Cause:** When adding files to the git index, concurrent operations could cause the error "file changed before we could read it". The code didn't have retry logic.

**Fix:** Added retry logic with 3 attempts in `upload_changes()`. If the error contains "file changed", it retries after a short delay. After 3 attempts, it fails gracefully.

**Files Modified:**
- `rust/src/api/git_manager.rs:2832-2892` (upload_changes)

---

### 4. Detached HEAD Recovery (Planned)

**Issue:** Repository ends up in detached HEAD state after failed sync operations. Current recovery via branch dropdown orphans local commits.

**Planned Fix:** Auto-recovery function that:
- Detects detached HEAD state
- Scans all local branches for one containing the current commit
- If exactly 1 branch matches, auto-reattaches HEAD (safe - no ambiguity)
- If 0 or 2+ branches match, falls back to manual UI

**See:** `bug-report_detached-head-recovery.md`

---

### 5. Detached HEAD Dropdown Data Loss (Documented)

**Issue:** Using the branch dropdown to recover from detached HEAD orphans local commits.

**Documentation:** See `bug-report_detached-head-dropdown-data-loss.md`

**Recommendation:** Don't use the dropdown to recover - wait for auto-recovery or manually manage via git.

---

## Testing Checklist

- [ ] Sync after merge conflict resolution
- [ ] Sync with corrupted loose objects
- [ ] Sync with active rebase state
- [ ] Multiple concurrent sync operations
- [ ] Detached HEAD state recovery

## Log Patterns to Watch For

```
"failed to parse loose object"
"invalid header"  
"file changed"
"Sync Unavailable on DETACHED HEAD"
"Retrying index operations"
```
