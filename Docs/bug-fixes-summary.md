# Bug Fixes Summary

This document summarizes all bug fixes implemented in the recent releases.

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

**Fix:** Added retry logic with 3 attempts in `upload_changes()`. Uses 2-second delays (2s, 4s) between retries to handle disk I/O operations.

**Files Modified:**
- `rust/src/api/git_manager.rs:2832-2892` (upload_changes)

---

### 4. Detached HEAD Auto-Recovery

**Issue:** Repository ends up in detached HEAD state after failed sync operations. Using the branch dropdown to recover orphans local commits.

**Solution:** Added `ensure_head_attached()` function that:
- Detects detached HEAD state using `repo.head_detached()`
- Scans all local branches for one containing the current commit
- If exactly 1 branch matches, auto-reattaches HEAD (safe - no ambiguity)
- If 0 or 2+ branches match, falls back to manual UI
- Does NOT abort or cleanup state (preserves user commits!)

**Integration Points:**
- `download_changes()` - calls before pull
- `push_changes()` - calls before push
- `upload_changes()` - calls before staging
- `commit_changes()` - calls before commit

**Files Modified:**
- `rust/src/api/git_manager.rs:2186-2226` (ensure_head_attached function)
- Multiple integration points in push/download/upload/commit functions

**See:** `bug-report_detached-head-recovery.md`

---

### 5. Commit Changes Corruption Handling

**Error:** `failed to parse loose object: invalid header` during commit operations

**Root Cause:** The commit operation wasn't checking for or cleaning up corrupted loose objects before attempting to write.

**Fix:** Added both detached HEAD recovery and corrupted loose object pruning to `commit_changes()` function.

**Files Modified:**
- `rust/src/api/git_manager.rs:2733-2757` (commit_changes)

---

### 6. Background Scanning (Constant Battery Drain)

**Issue:** App continuously scans every 10 seconds in background with Client Mode enabled, causing battery drain.

**Root Cause:** The 10-second timer was cancelled when app went to background, but `updateSyncOptions()` was still being called, triggering git operations in background.

**Fix:** In `updateRecommendedAction()`, removed the `await updateSyncOptions()` call when app is in background. Now:
- Background: No scanning, no git operations at all
- Foreground: Continues scanning every 10 seconds (unchanged)
- Scheduled sync (WorkManager): Still works independently
- App sync (Accessibility): Still works independently

**Files Modified:**
- `lib/main.dart:1000-1003` (updateRecommendedAction function)

**See:** `bug-report_background_scanning.md` (already exists, updated)

---

## Testing Checklist

- [ ] Sync after merge conflict resolution
- [ ] Sync with corrupted loose objects
- [ ] Sync with active rebase state
- [ ] Multiple concurrent sync operations
- [ ] Detached HEAD state recovery
- [ ] Background scanning stops when app is in background
- [ ] Foreground scanning continues normally

## Log Patterns to Watch For

```
"failed to parse loose object"
"invalid header"  
"file changed"
"Sync Unavailable on DETACHED HEAD"
"Retrying index operations"
"Detached HEAD: "
"Corruption detected and auto-fixed"
```