# Bug Report: Merge Conflicts and Sync Race Conditions

**Date:** 2026-03-24  
**Status:** FIXED
**Category:** Merge Conflicts, Sync, Race Conditions

## Summary

Multiple interrelated bugs cause merge operations to fail when scheduled sync runs concurrently, or when the repository is in an inconsistent state (MERGE + REBASE simultaneously).

All 6 bugs have been fixed and merged.

---

## Bug 1: Corrupted Loose Objects During Merge Commits

### Error Message
```
Error: failed to parse loose object: invalid header (at line 2572)
```

### Status: FIXED

### Root Cause

The `upload_changes` function (used for merge commits via `backgroundStageAndCommit`) did NOT call `prune_corrupted_loose_objects` before attempting to write tree/commit objects.

**Location:** `rust/src/api/git_manager.rs` - `upload_changes` function

### Fix Applied

Added `prune_corrupted_loose_objects` call at the start of `upload_changes` function, similar to what's done in `commit_changes`. Also added pruning between retry attempts to clean up any corruption that occurs during retries.

**Commit:** `6ecdf15` (branch: `fix/merge_conflict_and_sync_race`)

**Files Modified:**
- `rust/src/api/git_manager.rs` - Added prune_corrupted_loose_objects calls in upload_changes

---

## Bug 2: Invalid Refspec refs/heads/HEAD

### Error Message
```
Error: src refspec 'refs/heads/HEAD' does not match any existing object
```

### Status: FIXED

### Root Cause

When the repository is in detached HEAD state after a failed merge, `head.shorthand()` returns the literal string "HEAD", which was being formatted as "refs/heads/HEAD" (invalid).

**Location:** `rust/src/api/git_manager.rs` - `push_changes` function

### Fix Applied

Added handling for detached HEAD state in two places in `push_changes`:
1. When rebase head-name file exists (rebase state)
2. Normal push path (non-rebase state)

Logic:
- Detects when `branch_name` is literal "HEAD" (detached HEAD)
- Finds local branches containing the current commit
- If 1 branch matches → use that branch
- If 0 branches match → fall back to default (master/main)
- If 2+ branches match → use first one (safer than failing)

**Commit:** `e066b09` (branch: `fix/invalid-refspec-head-detached`)

**Files Modified:**
- `rust/src/api/git_manager.rs` - Lines 2327-2368 and 2374-2416

---

## Bug 3: "This Patch Has Already Been Applied"

### Error Message
```
Error: this patch has already been applied
```

### Status: FIXED

### Root Cause

In `commit_changes` function, the first `rebase.commit()` call didn't handle `ErrorCode::Applied`. The handler only existed inside the loop for subsequent commits.

**Location:** `rust/src/api/git_manager.rs` - `commit_changes` function, line 2841

### Fix Applied

Added error handling for `ErrorCode::Applied` at two locations:
1. `commit_changes` function - first rebase.commit() call
2. `push_changes` function - first rebase.commit() in the loop

Both now handle Applied error and continue gracefully instead of crashing.

**Commit:** `0216f6d` (branch: `fix/rebase-already-applied-handling`)

**Files Modified:**
- `rust/src/api/git_manager.rs` - Lines 2467 and 2841

---

## Bug 4: MERGE → REBASE State Transition

### Description

The repository incorrectly transitions from MERGE state to REBASE state, causing the repository to be in an inconsistent state.

### Status: FIXED

### Root Cause

In `push_changes` function, the code started a new rebase without first aborting an existing MERGE state. This caused the repo to transition from MERGE to REBASE state.

**Location:** `rust/src/api/git_manager.rs` - `push_changes` function, around line 2506

### Fix Applied

Added check for MERGE state before attempting to start a rebase:
1. If in MERGE state, abort the merge first (reset to HEAD, cleanup)
2. Then proceed with the rebase as normal
3. If in REBASE state, abort existing rebase (existing behavior)

This prevents the MERGE → REBASE transition that causes subsequent errors.

**Commit:** `38fe42f` (branch: `fix/merge-to-rebase-transition`)

**Files Modified:**
- `rust/src/api/git_manager.rs` - Lines 2506-2522

---

## Bug 5: Scheduled Sync During Merge Conflicts

### Description

Background scheduled sync runs while the user is resolving merge conflicts, causing the remote to change while the user is working on the merge.

### Status: FIXED

### Root Cause

The `debouncedSync` function and scheduled sync trigger did NOT check if the repository is in a merge state before running.

**Location:** 
- `lib/main.dart` - WorkManager.executeTask and FORCE_SYNC handler

### Fix Applied

Added two checks:
1. In WorkManager.executeTask: Check for merge conflicts before triggering scheduled sync. If conflicts exist, skip the sync.
2. In FORCE_SYNC handler: Check for 'scheduled' flag and skip merge conflict check for user-triggered syncs.

The check uses `GitManager.getConflicting()` to detect unmerged files. If conflicts exist, scheduled sync is skipped until conflicts are resolved.

**Commit:** `5b45a24` (branch: `fix/skip-sync-during-merge`)

**Files Modified:**
- `lib/main.dart` - WorkManager.executeTask and FORCE_SYNC handler

---

## Bug 6: File Changed Before We Could Read It (Race Condition)

### Error Message
```
Error: file changed before we could read it
```

### Status: FIXED

### Root Cause

The retry logic in `_sync` finally block could cause rapid-fire retries when sync keeps failing (e.g., file being edited, merge conflicts, network issues). This could lead to battery drain when user is away.

### Fix Applied

Added exponential backoff with failure limit:

1. **Added failure counter** (`syncFailureCount`) in gitsync_service.dart
2. **On sync success**: resets counter to 0
3. **On sync failure**: increments counter with exponential backoff:
   - Failure 1: retry after 2 seconds
   - Failure 2: retry after 4 seconds
   - Failure 3: retry after 8 seconds
   - Failure 4: retry after 16 seconds
   - Failure 5: retry after 30 seconds
   - Failure 6+: give up until new sync event triggers

This prevents battery drain from infinite retry loops while user is away, but still retries while user is actively editing files.

**Commit:** `effc96a` (branch: `fix/sync-retry-backoff`)

**Files Modified:**
- `lib/gitsync_service.dart` - Added syncFailureCount counter and exponential backoff logic

---

## Additional Fix: Abort Rebase Only in Sync Operations

### Status: FIXED

### Root Cause

The initial fix for aborting rebase during detached HEAD was too aggressive - it aborted rebase in both sync operations AND user-initiated merge conflict resolution.

This caused user-initiated merge resolution to fail when the repo was in detached HEAD state.

### Fix Applied

Removed the detached HEAD check from `commit_changes` function (which handles user-initiated merges) while keeping it in `push_changes` function (which handles sync operations).

- `push_changes`: Aborts rebase when in detached HEAD during sync
- `commit_changes`: Does NOT abort rebase (allows user to resolve merge conflicts)

**Commit:** `6bc87e7` (branch: `fix/abort-rebase-sync-only`)

**Files Modified:**
- `rust/src/api/git_manager.rs` - Removed detached HEAD check from commit_changes (line ~2896)

---

## Bug 7: Detached HEAD After Rebase

### Status: FIXED

### Error Message

User sees "unable to sync while in detached HEAD state" even though sync completed successfully.

### Root Cause

After the rebase block in `commit_changes`, the code returned without ensuring HEAD was attached to a branch. This happened in two scenarios:
1. After successful rebase completion (`rebase.finish()`)
2. When subsequent rebase steps have conflicts (returns early with `Ok(())`)

The rebase itself completed successfully, but HEAD was left pointing to the rebased commit without being attached to a branch.

### How It Works

When there are multiple local commits being rebased:
1. First commit rebases successfully
2. Second commit has conflicts → returns early with `Ok(())`, leaving index/working directory intact
3. UI shows merge conflict dialog → user resolves
4. Next sync continues rebase
5. If successful rebase at end → `rebase.finish()` succeeds but HEAD remains detached

The fix ensures HEAD is reattached to the branch after the rebase block completes.

### Fix Applied

Added code after the rebase block to reattach HEAD to the branch:

```rust
if repo.head_detached().unwrap_or(false) {
    if let Some(branch_name) = get_branch_name_priv(&repo) {
        swl!(repo.set_head(&format!("refs/heads/{}", branch_name)))?;
        _log(..., format!("Reattached HEAD to branch: {}", branch_name));
    }
}
```

This fix was initially applied in commit_changes function in two locations:
1. After successful rebase completion (line ~2943)
2. After conflict on subsequent rebase step (line ~2929)

**Additional Fix (Bug 8):** The same fix was later extended to `push_changes` function to handle the same issue when sync operations use push_changes instead of commit_changes:
- First rebase path (existing rebase state): Line ~2870
- Second rebase path (new rebase): Line ~2970

**Branch:** `fix/rebase-cleanup-state`

**Files Modified:**
- `rust/src/api/git_manager.rs` - commit_changes function (Lines ~3285-3315)
- `rust/src/api/git_manager.rs` - push_changes function (Lines ~2870 and ~2970)

---

## Summary of Fixes

| Bug | Branch | Commit | Status |
|-----|--------|--------|--------|
| 1: Loose objects in upload | `fix/merge_conflict_and_sync_race` | `6ecdf15` | ✅ Fixed |
| 2: refs/heads/HEAD | `fix/invalid-refspec-head-detached` | `e066b09` | ✅ Fixed |
| 3: Already applied | `fix/rebase-already-applied-handling` | `0216f6d` | ✅ Fixed |
| 4: MERGE→REBASE | `fix/merge-to-rebase-transition` | `38fe42f` | ✅ Fixed |
| 5: Sync during merge | `fix/skip-sync-during-merge` | `5b45a24` | ✅ Fixed |
| 6: File changed retry | `fix/sync-retry-backoff` | `effc96a` | ✅ Fixed |
| 7: Detached HEAD after rebase (commit) | `fix/rebase-cleanup-state` | (pending) | ✅ Fixed |
| 8: Detached HEAD after rebase (push) | `fix/rebase-cleanup-state` | (pending) | ✅ Fixed |

---

## Related Files

- `rust/src/api/git_manager.rs` - Main Rust implementation
- `lib/gitsync_service.dart` - Dart service layer
- `lib/main.dart` - Main app with scheduled sync triggers
- `lib/ui/dialog/merge_conflict.dart` - Merge conflict dialog
