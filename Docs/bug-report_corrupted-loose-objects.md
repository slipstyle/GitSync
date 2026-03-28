# Bug Report: Corrupted Loose Objects in Git Repository

## Bug Summary

**Type:** Pull/Push Failure  
**Severity:** High  
**Component:** Git Sync / Repository Integrity  
**Error Message:** `failed to parse loose object: invalid header`
**Error Location:** `rust/src/api/git_manager.rs:4333` (in `prune_corrupted_loose_objects`)

---

## Affected Code Path

Any git operation that reads objects from the object database, particularly during sync operations after a merge conflict or repository corruption.

---

## Reproduction Scenario

1. User resolves merge conflicts in the app
2. During commit/push, the git repository enters a corrupted state (possibly due to:
   - Interrupted sync during write
   - Disk write failure
   - Concurrent file access
   - Corrupted loose object files)
3. Subsequent sync operation attempts to read git objects
4. Error: "failed to parse loose object: invalid header"

---

## Root Cause Analysis

### The Problem

Git stores objects in `.git/objects/` as either packed files or loose objects (individual files). When these loose object files become corrupted (truncated, wrong format, etc.), git cannot parse them.

The existing code at `prune_corrupted_loose_objects` only handled:
- `"failed to parse loose object"`

But not:
- `"invalid header"`

This meant corrupted objects with "invalid header" errors were not being pruned, causing repeated failures.

---

## Fix Implementation

### Strategy

Extend the error detection in `prune_corrupted_loose_objects` to handle both error messages.

### Code Change

**File:** `rust/src/api/git_manager.rs`  
**Function:** `prune_corrupted_loose_objects`  
**Lines:** 4331-4337

**Before:**
```rust
if let Err(e) = odb.read_header(oid) {
    let msg = e.message().to_lowercase();
    if msg.contains("failed to parse loose object") {
        let _ = fs::remove_file(file_entry.path());
        pruned += 1;
    }
}
```

**After:**
```rust
if let Err(e) = odb.read_header(oid) {
    let msg = e.message().to_lowercase();
    if msg.contains("failed to parse loose object") || msg.contains("invalid header") {
        let _ = fs::remove_file(file_entry.path());
        pruned += 1;
    }
}
```

---

## Files Modified

| File | Lines | Change Description |
|------|-------|-------------------|
| `rust/src/api/git_manager.rs` | 4333 | Handle both "failed to parse loose object" and "invalid header" errors |

---

## Testing Recommendations

1. **Corrupted object test:**
   - Manually corrupt a loose object file in `.git/objects/`
   - Run sync operation
   - Verify the corrupted object is pruned and operation succeeds

2. **Invalid header test:**
   - Create a loose object with invalid header
   - Run sync operation
   - Verify proper handling

---

## Log Patterns to Watch For

```
"failed to parse loose object"
"invalid header"
"Pruned N corrupted loose objects"
```

---

## Related Issues

- May occur after failed rebase operations
- May occur with interrupted sync operations
- Related to "file changed before we could read it" errors
