# Bug Report: Stale FETCH_HEAD OID Error

## Bug Summary

**Type:** Sync Failure  
**Severity:** High  
**Component:** Git Sync / Pull Operations  
**Error Message:** `target OID for the reference doesn't exist on the repository`

---

## Affected Code Paths

- `download_changes` (pull operations)
- `download_and_overwrite` (force pull with overwrite)
- `force_pull` (aggressive force pull)

---

## Reproduction Scenario

1. User has GitSync running with background sync enabled
2. GitSync starts a sync operation:
   - Performs git fetch (FETCH_HEAD created, pointing to commit X)
   - Begins merge/pull operation
3. While GitSync is mid-sync:
   - User continues editing files on desktop
   - User pushes changes to remote
   - Remote branch is updated (commit X may be rebased, force-pushed, or replaced)
4. GitSync's pull operation fails because FETCH_HEAD references commit X which no longer exists

---

## Root Cause Analysis

### Primary Cause: Remote Update During Sync (Race Condition)

GitSync sync operations involve multiple steps:
1. Open repository
2. Fetch from remote (creates FETCH_HEAD pointing to remote commit)
3. Analyze merge
4. Perform merge/pull
5. Update submodules
6. Handle conflicts

This workflow takes longer than a simple `git pull` due to:
- Flutter/Rust bridge overhead
- Additional bookkeeping (submodules, conflicts, etc.)
- Background processing with callbacks

If the remote is updated while GitSync is in the middle of this workflow, FETCH_HEAD becomes stale, pointing to a commit that no longer exists on the remote.

### Secondary Cause: Corrupted Object Pruning

If git object corruption is detected (partial write, disk error, etc.), GitSync may run `pruneCorruptedLooseObjects` which deletes orphaned objects. If FETCH_HEAD references one of these deleted objects, the subsequent pull fails.

Evidence from logs: `"Corruption detected and auto-fixed"` may appear before the OID error.

### Contributing Factors

1. **Long-running sync operations:** GitSync takes longer than desktop git for equivalent operations
2. **Background sync:** Sync may run while user is actively editing
3. **No FETCH_HEAD invalidation:** No mechanism to detect when remote has changed
4. **Multi-step operations:** fetch + merge is not atomic

---

## Error Flow

```
User pushes to remote (commit X is rebased/replaced)
         |
         v
+------------------+
| GitSync starts   |
| sync             |
+------------------+
         |
         v
+------------------+
| Fetch from       |
| remote           |
| (FETCH_HEAD = X)|
+------------------+
         |
         v (delay - merge, submodules, etc.)
         |
         x (commit X no longer exists)
         |
         v
+------------------+
| Pull operation   |
| tries to use     |
| FETCH_HEAD       |
+------------------+
         |
         v
Error: target OID for the reference doesn't exist on the repository
```

---

## Fix Implementation

### Strategy

When an OID error is encountered, re-fetch from the remote to get a fresh FETCH_HEAD, then retry the operation.

### Changes

#### 1. `download_changes` (lines ~2131-2140)

Added error recovery wrapper around `pull_changes_priv` call:

```rust
match pull_result {
    Ok(result) => {
        if result == Ok(Some(false)) {
            return Ok(Some(false));
        }
        Ok(Some(true))
    }
    Err(e) => {
        let err_msg = e.message().to_lowercase();
        if err_msg.contains("target oid") && err_msg.contains("doesn't exist") {
            _log(Arc::clone(&log_callback), LogType::PullFromRepo, 
                "FETCH_HEAD OID stale (remote may have changed), re-fetching...".to_string());
            swl!(fetch_remote_priv(&repo, &remote, &provider, &credentials, &log_callback))?;
            tokio::task::block_in_place(|| {
                pull_changes_priv(&repo, &provider, &credentials, 
                    commit_signing_credentials, sync_callback, &log_callback)
            })?;
            Ok(Some(true))
        } else {
            Err(e)
        }
    }
}
```

#### 2. `download_and_overwrite` (lines ~3323-3325)

Added error recovery for FETCH_HEAD usage:

```rust
let fetch_commit = match swl!(repo.find_reference("FETCH_HEAD")
    .and_then(|r| repo.reference_to_annotated_commit(&r))) {
    Ok(c) => c,
    Err(e) => {
        let err_msg = e.message().to_lowercase();
        if err_msg.contains("target oid") && err_msg.contains("doesn't exist") {
            _log(Arc::clone(&log_callback), LogType::ForcePull, 
                "FETCH_HEAD OID stale, re-fetching...".to_string());
            let callbacks = get_default_callbacks(Some(&provider), Some(&credentials));
            let mut fetch_options = FetchOptions::new();
            fetch_options.update_fetchhead(true);
            fetch_options.remote_callbacks(callbacks);
            swl!(remote.fetch::<&str>(&[], Some(&mut fetch_options), None))?;
            swl!(repo.find_reference("FETCH_HEAD")
                .and_then(|r| repo.reference_to_annotated_commit(&r)))?
        } else {
            return Err(e);
        }
    }
};
```

#### 3. `force_pull` (lines ~2896-2901)

Added fetch step before using FETCH_HEAD, plus error recovery:

```rust
let repo = swl!(Repository::open(&path_string))?;
repo.cleanup_state().unwrap();

// Add fetch to ensure FETCH_HEAD is valid
if let Ok(mut remote) = repo.find_remote("origin") {
    configure_network_timeouts(&repo);
    let callbacks = get_default_callbacks(None, None);
    let mut fetch_options = FetchOptions::new();
    fetch_options.update_fetchhead(true);
    fetch_options.remote_callbacks(callbacks);
    let _ = remote.fetch::<&str>(&[], Some(&mut fetch_options), None);
}

let fetch_commit = match swl!(repo.find_reference("FETCH_HEAD")
    .and_then(|r| repo.reference_to_annotated_commit(&r))) {
    Ok(c) => c,
    Err(e) => {
        let err_msg = e.message().to_lowercase();
        if err_msg.contains("target oid") && err_msg.contains("doesn't exist") {
            _log(Arc::clone(&log_callback), LogType::ForcePull, 
                "FETCH_HEAD OID stale, re-fetching...".to_string());
            if let Ok(mut remote) = repo.find_remote("origin") {
                configure_network_timeouts(&repo);
                let callbacks = get_default_callbacks(None, None);
                let mut fetch_options = FetchOptions::new();
                fetch_options.update_fetchhead(true);
                fetch_options.remote_callbacks(callbacks);
                swl!(remote.fetch::<&str>(&[], Some(&mut fetch_options), None))?;
                swl!(repo.find_reference("FETCH_HEAD")
                    .and_then(|r| repo.reference_to_annotated_commit(&r)))?
            } else {
                return Err(e);
            }
        } else {
            return Err(e);
        }
    }
};
```

---

## Files Modified

| File | Lines | Change Description |
|------|-------|-------------------|
| `rust/src/api/git_manager.rs` | ~2131-2140 | OID error recovery in `download_changes` |
| `rust/src/api/git_manager.rs` | ~3323-3325 | OID error recovery in `download_and_overwrite` |
| `rust/src/api/git_manager.rs` | ~2896-2901 | Added fetch + OID recovery in `force_pull` |

---

## Testing Recommendations

1. **Race condition test:**
   - Start GitSync sync on large repository
   - While sync is running, push changes from desktop
   - Verify sync completes successfully after retry

2. **Multiple rapid pushes test:**
   - Start sync
   - Push multiple times rapidly from desktop
   - Verify sync eventually succeeds

3. **Offline/timeout test:**
   - Start sync
   - Lose network connection
   - Restore connection and push changes
   - Verify sync recovers

---

## Related Issues

- May be related to user reports of "sync getting stuck" or "pull failed"
- Related to long-running sync operations on large repositories

---

## Log Patterns to Watch For

```
"FETCH_HEAD OID stale (remote may have changed), re-fetching..."
"FETCH_HEAD OID stale, re-fetching..."
"target OID for the reference doesn't exist"
```

