# Bug Report: Merge Conflicts and Sync Race Conditions

**Date:** 2026-03-24  
**Status:** Documented (Not Fixed)  
**Category:** Merge Conflicts, Sync, Race Conditions

## Summary

Multiple interrelated bugs cause merge operations to fail when scheduled sync runs concurrently, or when the repository is in an inconsistent state (MERGE + REBASE simultaneously).

---

## Bug 1: Corrupted Loose Objects During Merge Commits

### Error Message
```
Error: failed to parse loose object: invalid header (at line 2572)
```

### Root Cause

The `upload_changes` function (used for merge commits via `backgroundStageAndCommit`) does NOT call `prune_corrupted_loose_objects` before attempting to write tree/commit objects.

**Location:** `rust/src/api/git_manager.rs` - `upload_changes` function (line 2854+)

The `commit_changes` function (line 2719) does call `prune_corrupted_loose_objects` at line 2747, but `upload_changes` does not have this cleanup.

### Why It Happens

1. Scheduled sync downloads objects from remote
2. Objects may become corrupted or incompatible during download
3. User resolves merge conflicts and clicks "Merge"
4. `upload_changes` tries to write tree/commit
5. Git encounters corrupted loose objects → fails with "invalid header"

### Fix Required

Add `prune_corrupted_loose_objects` call at the start of `upload_changes` function, similar to what's done in `commit_changes`.

---

## Bug 2: Invalid Refspec refs/heads/HEAD

### Error Message
```
Error: src refspec 'refs/heads/HEAD' does not match any existing object (at line 2518)
```

### Root Cause

When the repository is in detached HEAD state after a failed merge, the code at line 2327-2333 constructs a refspec incorrectly:

```rust
if trimmed.is_empty() || trimmed == "HEAD" || !trimmed.contains('/') {
    let head = swl!(repo.head())?;
    let resolved_head = swl!(head.resolve())?;
    let branch_name = swl!(resolved_head
        .shorthand()
        .ok_or_else(|| git2::Error::from_str("Could not determine branch name")))?;
    format!("refs/heads/{}", branch_name)  // BUG: If shorthand() returns "HEAD", this becomes "refs/heads/HEAD"
}
```

When `head.shorthand()` returns the literal string `"HEAD"` (which happens in detached HEAD state), it gets formatted as `refs/heads/HEAD`, which is invalid.

### Why It Happens

1. Merge fails and leaves repository in detached HEAD state
2. Repository state: detached HEAD + possibly rebase state
3. Next push operation tries to get the branch name
4. `shorthand()` returns literal "HEAD" 
5. Code formats as `refs/heads/HEAD` → invalid refspec

### Fix Required

Check if `branch_name` is "HEAD" and handle it specially - either find a local branch that contains the current commit, or fall back to a default branch.

---

## Bug 3: "This Patch Has Already Been Applied"

### Error Message
```
Error: this patch has already been applied (at line 2772)
```

### Root Cause

In `commit_changes` function, line 2772 attempts the first rebase commit without handling the `ErrorCode::Applied` case:

```rust
swl!(rebase.commit(None, &sig, None))?;  // Line 2772 - doesn't handle Applied error
```

The error handler for `Applied` only exists inside the loop at line 2780, not for the initial commit.

### Why It Happens

1. Repository in REBASE state (from Bug 4)
2. Code tries to continue/complete the rebase
3. First rebase commit was already applied (possibly from previous attempt)
4. `rebase.commit()` fails with "this patch has already been applied"
5. No handler for this error at line 2772 → crash

### Fix Required

Add error handling for `ErrorCode::Applied` at line 2772:

```rust
match swl!(rebase.commit(None, &sig, None)) {
    Ok(_) => {}
    Err(e) if e.code() == ErrorCode::Applied => {
        // First commit already applied, continue to next
    }
    Err(e) => return Err(e),
}
```

---

## Bug 4: MERGE → REBASE State Transition

### Description

The repository transitions from MERGE state to REBASE state incorrectly, causing the repository to be in an inconsistent state.

### Root Cause

In `push_changes` function, lines 2433-2442:

```rust
// Line 2433: If not in clean state (includes MERGE state!)
if repo.state() != RepositoryState::Clean {
    // Line 2434: Try to abort any existing rebase
    if let Some(mut rebase) = repo.open_rebase(None).ok() {
        swl!(rebase.abort())?;
    }
}

// Line 2441: Start a NEW rebase - BUG: Doesn't check if we were in MERGE state!
let mut rebase = swl!(repo.rebase(None, Some(&annotated_commit), Some(&annotated_commit), None))?;
```

### Why It Happens

1. Pull detects merge conflicts → repo enters MERGE state (MERGE_HEAD exists)
2. Later, push fails with NotFastForward
3. Code checks `repo.state() != Clean` → true (it's MERGE)
4. Code attempts to abort rebase (but we're in MERGE, not REBASE) - does nothing
5. Line 2441 starts a NEW rebase → repo now in REBASE state
6. Old MERGE_HEAD might still exist → inconsistent state

### Sequence of Events (from logs)

```
08:34:59 PullFromRepo: Merge conflicts detected     # MERGE state
08:37:14 Global: Detached HEAD: no branch contains current commit
08:37:18 PushToRepo: Rebase in progress — committing via rebase
Error: this patch has already beeen applied         # BUG 3
08:37:18 Sync: Merge Failed
```

### Fix Required

Before starting a new rebase (line 2441), check if in MERGE state and abort/handle it first:

```rust
if repo.state() == RepositoryState::Merge {
    // Abort merge first
    let head = swl!(repo.head()?.peel_to_commit())?;
    swl!(repo.reset(head.as_object(), ResetType::Hard, None))?;
    swl!(repo.cleanup_state())?;
} else if repo.state() != RepositoryState::Clean {
    // Existing rebase abort logic
    if let Some(mut rebase) = repo.open_rebase(None).ok() {
        swl!(rebase.abort())?;
    }
}
```

---

## Bug 5: Scheduled Sync During Merge Conflicts

### Description

Background scheduled sync runs while the user is resolving merge conflicts, causing the remote to change while the user is working on the merge.

### Root Cause

The `debouncedSync` function and scheduled sync trigger (main.dart lines 154-162) do NOT check if the repository is in a merge state before running.

```dart
// main.dart lines 154-162
if (task.contains(scheduledSyncKey)) {
    // BUG: No check for ongoing merge!
    FlutterBackgroundService().invoke(GitsyncService.FORCE_SYNC, {...});
}
```

### Why It Happens

1. User opens merge conflict dialog to resolve conflicts
2. Scheduled sync triggers (in background)
3. Sync fetches from remote → remote has NEW commits
4. Objects downloaded to .git/objects
5. User clicks "Merge" → merge commits fail due to corruption/state issues
6. Remote changed "underneath" the user during merge resolution

### Fix Required

Check for ongoing merge before running scheduled sync:

1. Check for `.git/MERGE_HEAD` existence
2. Check if repository state is `RepositoryState::Merge`
3. Check if index has conflicts (`index.has_conflicts()`)
4. If any true, skip or delay the scheduled sync

---

## Bug 6: File Changed Before We Could Read It (Race Condition)

### Error Message
```
Error: file changed before we could read it (at line 2955)
```

### Description

This is partially user-induced - occurs when the user is actively editing files on their phone while sync is running.

### Root Cause

The retry logic in `upload_changes` (lines 2933-2986) has a 2-second delay between attempts, but doesn't check if the file was modified by an external process (the user).

### Why It Happens

1. Background sync starts
2. User opens file in editor and makes changes
3. Sync tries to read file → "file changed before we could read it"
4. Retry after 2 seconds → may still be changed

### Fix Options

1. **Accept as user behavior** - This is expected when user edits files during sync
2. **Check file mtime before reading** - Add check to see if file was modified recently
3. **Longer/exponential backoff** - Increase delay between retries

This bug is considered lower priority since it's user-induced behavior.

---

## Summary of Required Fixes

| Bug | Location | Fix |
|-----|----------|-----|
| 1: Loose objects | `upload_changes` (line 2854) | Add `prune_corrupted_loose_objects` call |
| 2: refs/heads/HEAD | `push_changes` (line 2327-2346) | Handle "HEAD" branch name specially |
| 3: Already applied | `commit_changes` (line 2772) | Add Applied error handling |
| 4: MERGE→REBASE | `push_changes` (line 2441) | Check MERGE state before starting rebase |
| 5: Sync during merge | `debouncedSync` / main.dart | Check for merge state before sync |
| 6: File changed | `upload_changes` (line 2955) | Lower priority - user-induced |

---

## Related Files

- `rust/src/api/git_manager.rs` - Main Rust implementation
- `lib/gitsync_service.dart` - Dart service layer
- `lib/main.dart` - Main app with scheduled sync triggers
- `lib/ui/dialog/merge_conflict.dart` - Merge conflict dialog

---

## Test Scenario

To reproduce:

1. Set up a repo with remote changes
2. Trigger a pull that causes merge conflicts
3. BEFORE resolving conflicts, let scheduled sync run
4. Try to resolve merge conflicts and click Merge
5. Observe failures

Alternative:
1. Have merge conflicts
2. Push fails with NotFastForward  
3. Observe MERGE → REBASE transition
4. Try to commit → "already applied" error
