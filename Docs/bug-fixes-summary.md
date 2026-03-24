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

### 7. Corrupted Loose Objects in upload_changes

**Error:** `failed to parse loose object: invalid header` during merge commit

**Root Cause:** The `upload_changes` function (used for merge commits) did NOT call `prune_corrupted_loose_objects` before attempting to write tree/commit objects. Only `commit_changes` had this cleanup.

**Fix:** Added `prune_corrupted_loose_objects` call at the start of `upload_changes` function, similar to what's done in `commit_changes`. Also added pruning between retry attempts.

**Branch:** `fix/merge_conflict_and_sync_race`  
**Commit:** `6ecdf15`

**Files Modified:**
- `rust/src/api/git_manager.rs` - upload_changes function

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

### 8. Invalid Refspec refs/heads/HEAD (Detached HEAD)

**Error:** `src refspec 'refs/heads/HEAD' does not match any existing object`

**Root Cause:** When detached HEAD, `head.shorthand()` returns literal "HEAD", which gets formatted as `refs/heads/HEAD` (invalid).

**Fix:** Added handling for detached HEAD state in two places in `push_changes`:
- When rebase head-name file exists (rebase state)
- Normal push path (non-rebase state)

Logic:
- Detects when branch_name is literal "HEAD" (detached HEAD)
- Finds local branches containing the current commit
- If 1 branch matches → use that branch
- If 0 branches match → fall back to default (master/main)
- If 2+ branches match → use first one

**Branch:** `fix/invalid-refspec-head-detached`  
**Commit:** `e066b09`

**Files Modified:**
- `rust/src/api/git_manager.rs` - Lines 2327-2368 and 2374-2416

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

### 9. "This Patch Has Already Been Applied"

**Error:** `this patch has already been applied`

**Root Cause:** In `commit_changes`, the first `rebase.commit()` call didn't handle `ErrorCode::Applied`. The handler only existed inside the loop.

**Fix:** Added error handling for `ErrorCode::Applied` at two locations:
- `commit_changes` function - first rebase.commit() call
- `push_changes` function - first rebase.commit() in the loop

**Branch:** `fix/rebase-already-applied-handling`  
**Commit:** `0216f6d`

**Files Modified:**
- `rust/src/api/git_manager.rs` - Lines 2467 and 2841

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

### 10. MERGE → REBASE State Transition

**Description:** Repository incorrectly transitions from MERGE state to REBASE state.

**Root Cause:** In `push_changes`, starting a new rebase without checking if the repo is in MERGE state first. This leaves the repo in an inconsistent state.

**Fix:** Added check for MERGE state before attempting to start a rebase:
- If in MERGE state, abort the merge first (reset to HEAD, cleanup)
- Then proceed with the rebase as normal
- If in REBASE state, abort existing rebase (existing behavior)

**Branch:** `fix/merge-to-rebase-transition`  
**Commit:** `38fe42f`

**Files Modified:**
- `rust/src/api/git_manager.rs` - Lines 2506-2522

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

### 11. Scheduled Sync During Merge Conflicts

**Description:** Background sync runs while user is resolving merge conflicts, causing remote to change during merge.

**Root Cause:** `debouncedSync` and scheduled sync don't check for ongoing merge before running.

**Fix:** Added two checks:
1. In WorkManager.executeTask: Check for merge conflicts before triggering scheduled sync
2. In FORCE_SYNC handler: Check for 'scheduled' flag and skip merge conflict check for user-triggered syncs

Uses `GitManager.getConflicting()` to detect unmerged files. If conflicts exist, scheduled sync is skipped until conflicts are resolved.

**Branch:** `fix/skip-sync-during-merge`  
**Commit:** `5b45a24`

**Files Modified:**
- `lib/main.dart` - WorkManager.executeTask and FORCE_SYNC handler

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

### 12. Sync Retry Loop (Battery Drain)

**Error:** Sync retries infinitely when failing repeatedly

**Root Cause:** The retry logic in `_sync` finally block could cause rapid-fire retries when sync keeps failing, leading to battery drain when user is away.

**Fix:** Added exponential backoff with failure limit:
- Tracks consecutive sync failures with `syncFailureCount` counter
- On success: resets counter to 0
- On failure: increments counter with exponential backoff:
  - Failure 1: retry after 2 seconds
  - Failure 2: retry after 4 seconds
  - Failure 3: retry after 8 seconds
  - Failure 4: retry after 16 seconds
  - Failure 5: retry after 30 seconds
  - Failure 6+: give up until new sync event triggers

This prevents battery drain from infinite retry loops while user is away, but still retries while user is actively editing files.

**Branch:** `fix/sync-retry-backoff`  
**Commit:** `effc96a`

**Files Modified:**
- `lib/gitsync_service.dart` - Added syncFailureCount counter and exponential backoff logic

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

### 13. Abort Rebase Only in Sync Operations

**Issue:** User-initiated merge conflict resolution was failing due to over-aggressive rebase abort

**Root Cause:** The detached HEAD check was in both push_changes (sync) and commit_changes (user merge), causing user merges to fail.

**Fix:** Removed detached HEAD check from commit_changes, keeping it only in push_changes. This allows user-initiated merges to work while sync operations still handle broken rebase states properly.

**Branch:** `fix/abort-rebase-sync-only`  
**Commit:** `6bc87e7`

**Files Modified:**
- `rust/src/api/git_manager.rs` - Removed check from commit_changes

**See:** `bug-report_merge_conflict_and_sync_race.md`

---

## All Fix Branches

| Bug # | Description | Branch | Commit |
|-------|-------------|--------|--------|
| 1 | Malformed Rebase Refspec | (already merged) | - |
| 2 | Corrupted Loose Objects | (already merged) | - |
| 3 | Race Condition | (already merged) | - |
| 4 | Detached HEAD Recovery | (already merged) | - |
| 5 | Commit Corruption | (already merged) | - |
| 6 | Background Scanning | (already merged) | - |
| 7 | Loose objects in upload | `fix/merge_conflict_and_sync_race` | `6ecdf15` |
| 8 | refs/heads/HEAD | `fix/invalid-refspec-head-detached` | `e066b09` |
| 9 | Already applied | `fix/rebase-already-applied-handling` | `0216f6d` |
| 10 | MERGE→REBASE | `fix/merge-to-rebase-transition` | `38fe42f` |
| 11 | Sync during merge | `fix/skip-sync-during-merge` | `5b45a24` |
| 12 | Sync retry backoff | `fix/sync-retry-backoff` | `effc96a` |
| 13 | Abort rebase sync only | `fix/abort-rebase-sync-only` | `6bc87e7` |

---

## Testing Checklist

- [x] Sync after merge conflict resolution
- [x] Sync with corrupted loose objects
- [x] Sync with active rebase state
- [x] Multiple concurrent sync operations
- [x] Detached HEAD state recovery
- [x] Background scanning stops when app is in background
- [x] Foreground scanning continues normally
- [x] Scheduled sync skipped during active merge conflict
- [x] MERGE state handled correctly before rebase
- [x] Sync retry with exponential backoff (prevents battery drain)

## Log Patterns to Watch For

```
"failed to parse loose object"
"invalid header"  
"file changed"
"Sync Unavailable on DETACHED HEAD"
"Retrying index operations"
"Detached HEAD: "
"Corruption detected and auto-fixed"
"Repository in MERGE state, aborting merge before rebase"
"First rebase commit already applied"
"Sync failed, retrying in"
"Sync failed too many times, giving up"
```
