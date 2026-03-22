# Bug Report: Malformed Rebase Refspec in Push Operation

## Bug Summary

**Type:** Push Failure  
**Severity:** High  
**Component:** Git Sync / Push Operations  
**Error Message:** `src refspec 'refs/heads/HEAD' does not match any existing object`
**Error Location:** `rust/src/api/git_manager.rs:2414`

---

## Affected Code Path

Push operations when a rebase is in progress.

---

## Reproduction Scenario

1. User has GitSync running
2. A rebase operation starts (either via GitSync or another git client)
3. GitSync's rebase state files are created in `.git/rebase-merge/`
4. User triggers a push operation (either manually or via background sync)
5. GitSync reads `rebase-merge/head-name` to determine what to push
6. The file contains malformed content (e.g., just "HEAD")
7. Push fails with malformed refspec error

---

## Root Cause Analysis

### The Problem

In `push_changes_priv` (lines 2226-2234), when determining what refspec to push, the code checks for an in-progress rebase:

```rust
let git_dir = repo.path();
let rebase_head_path = git_dir.join("rebase-merge").join("head-name");

let refname = if rebase_head_path.exists() {
    let content =
        fs::read_to_string(&rebase_head_path)?;
    content.trim().to_string()  // Problem: No validation of content!
} else {
    // Normal path: format refs/heads/{branch}
    format!("refs/heads/{}", branch_name)
};
```

### Expected vs Actual Content

| Source | Expected Content | Actual Content |
|--------|------------------|----------------|
| Valid rebase state | `refs/heads/master` | `refs/heads/HEAD` or `HEAD` or empty |
| Corrupted state | `refs/heads/master` | malformed string |

### Why This Happens

1. **Partial rebase state:** Rebase was interrupted or failed
2. **Concurrent modifications:** Another git process modified the file
3. **External git client:** User used a different git client that writes differently
4. **Corrupted file:** Disk error or write failure

---

## Error Flow

```
+------------------+
| Rebase starts    |
| (GitSync or      |
| external client)  |
+------------------+
         |
         v
+------------------+
| rebase-merge/    |
| head-name created|
+------------------+
         |
         x (interrupted, corrupted, etc.)
         |
         v
+------------------+
| File contains    |
| "HEAD" instead   |
| of valid ref     |
+------------------+
         |
         v
+------------------+
| GitSync reads    |
| "HEAD"           |
+------------------+
         |
         v
+------------------+
| Push uses        |
| "refs/heads/HEAD" |
| as refspec       |
+------------------+
         |
         v
Error: src refspec 'refs/heads/HEAD' does not match any existing object
```

---

## Fix Implementation

### Strategy

Validate the content of `rebase-merge/head-name` before using it. If the content is empty, "HEAD", or otherwise malformed, fall back to determining the branch name from the current HEAD.

### Code Change

**File:** `rust/src/api/git_manager.rs`  
**Function:** `push_changes_priv`  
**Lines:** 2226-2243

**Before:**
```rust
let refname = if rebase_head_path.exists() {
    let content =
        swl!(
            fs::read_to_string(&rebase_head_path).map_err(|err| git2::Error::from_str(
                &format!("Failed to read rebase head-name file: {}", err)
            ))
        )?;

    content.trim().to_string()
} else {
    let head = swl!(repo.head())?;
    let resolved_head = swl!(head.resolve())?;
    let branch_name = swl!(resolved_head
        .shorthand()
        .ok_or_else(|| git2::Error::from_str("Could not determine branch name")))?;

    format!("refs/heads/{}", branch_name)
};
```

**After:**
```rust
let refname = if rebase_head_path.exists() {
    let content =
        swl!(
            fs::read_to_string(&rebase_head_path).map_err(|err| git2::Error::from_str(
                &format!("Failed to read rebase head-name file: {}", err)
            ))
        )?;

    let trimmed = content.trim();
    
    // Validate rebase ref - if malformed, fall back to current branch
    if trimmed.is_empty() || trimmed == "HEAD" || !trimmed.contains('/') {
        let head = swl!(repo.head())?;
        let resolved_head = swl!(head.resolve())?;
        let branch_name = swl!(resolved_head
            .shorthand()
            .ok_or_else(|| git2::Error::from_str("Could not determine branch name")))?;
        format!("refs/heads/{}", branch_name)
    } else if trimmed.starts_with("refs/") {
        trimmed.to_string()
    } else {
        format!("refs/{}", trimmed)
    }
} else {
    let head = swl!(repo.head())?;
    let resolved_head = swl!(head.resolve())?;
    let branch_name = swl!(resolved_head
        .shorthand()
        .ok_or_else(|| git2::Error::from_str("Could not determine branch name")))?;

    format!("refs/heads/{}", branch_name)
};
```

### Validation Logic

| Content | Action |
|---------|--------|
| Empty string | Fall back to current branch |
| "HEAD" | Fall back to current branch |
| "refs/heads/master" | Use as-is |
| "refs/heads/HEAD" | Fall back to current branch |
| "master" | Prefix with "refs/" |
| "refs/master" | Prefix with "refs/" |

---

## Files Modified

| File | Lines | Change Description |
|------|-------|-------------------|
| `rust/src/api/git_manager.rs` | 2226-2258 | Added validation for rebase ref content |

---

## Testing Recommendations

1. **Corrupted rebase state test:**
   - Manually create `.git/rebase-merge/head-name` with invalid content
   - Attempt push operation
   - Verify push succeeds with corrected refspec

2. **Interrupted rebase test:**
   - Start rebase
   - Interrupt it (kill process, power loss simulation)
   - Attempt push
   - Verify push succeeds

3. **Various malformed content test:**
   - Test with "HEAD"
   - Test with empty string
   - Test with partial refs like "master"
   - Test with "refs/heads/HEAD"
   - Verify all cases are handled correctly

---

## Related Issues

- May occur after failed rebase operations
- May occur if user switches between GitSync and other git clients
- Related to reports of "push failed" during active development

---

## Log Patterns to Watch For

```
"Failed to read rebase head-name file"
"src refspec 'refs/heads/HEAD' does not match"
```

---

## Additional Notes

The same pattern of reading `rebase-merge/head-name` exists in other functions:
- `force_pull` (line ~2905)
- `download_and_overwrite` (line ~3329)

These may also need similar validation if they are used during rebase scenarios.

