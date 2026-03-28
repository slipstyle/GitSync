# Bug Report: Detached HEAD Recovery Via Dropdown Orphans Commits

## Summary

**Type:** Data Loss / Data Integrity  
**Severity:** High  
**Component:** Branch Checkout / UI  

## The Problem

When the app shows "DETACHED HEAD" in the UI, the user can select a branch from the dropdown to "switch" to it. However, this operation orphans any local commits that were made while in detached HEAD state.

### What Happens

1. User is in detached HEAD state with local commits
2. User selects "main" or "master" from branch dropdown
3. The app calls `checkout_branch()` which:
   - Uses `force()` checkout to overwrite working directory
   - Sets HEAD to the selected branch
4. **Local commits are now orphaned** - they exist in git database but aren't on any branch
5. Eventually these commits will be garbage collected

### Code Location

`rust/src/api/git_manager.rs` - `checkout_branch()` function (lines 4106-4151):

```rust
pub async fn checkout_branch(
    path_string: &String,
    remote: &String,
    branch_name: &String,
    log: impl Fn(LogType, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), git2::Error> {
    // ... branch lookup code ...

    let object = swl!(branch.get().peel(git2::ObjectType::Commit))?;

    let mut checkout_builder = git2::build::CheckoutBuilder::new();
    checkout_builder.force();  // <-- This overwrites working directory

    tokio::task::block_in_place(|| swl!(repo.checkout_tree(&object, Some(&mut checkout_builder))))?;

    let refname = format!("refs/heads/{}", branch_name);
    swl!(repo.set_head(&refname))?;

    Ok(())
}
```

### What Gets Lost

| Change Type | Status | Notes |
|-------------|--------|-------|
| Working directory files | ⚠️ OVERWRITTEN | Replaced with target branch files |
| Staged files (index) | ⚠️ LOST | Index reset during checkout |
| Local commits | ⚠️ ORPHANED | Commits exist but not on any branch |

The commits aren't immediately deleted - they become "orphaned" (reachable in the object database but not on any branch). Git's garbage collector will eventually prune them.

## Why This Is Problematic

1. **Users expect their commits to be preserved** - They think "switching branches" is safe
2. **Orphaned commits are not immediately obvious** - UI doesn't warn about this
3. **Eventually garbage collected** - Without user noticing, commits are lost
4. **Warning message is misleading** - Says "click the DETACHED HEAD label, choose main or master" without explaining the data loss risk

## Current Warning Message (Misleading)

```
"Sync Unavailable on DETACHED HEAD

You can't sync while on a detached HEAD. That means your repository isn't 
on a branch right now, so changes can't be pushed. To fix this, click the 
'DETACHED HEAD' label, choose either 'main' or 'master' from the dropdown 
to switch back onto a branch, then press sync again."
```

This message doesn't explain that:
- Using the dropdown will overwrite working directory files
- Local commits will become orphaned
- There are better alternatives

## Recommendations

### For Users

1. **Don't use the branch dropdown to recover from detached HEAD** - It will overwrite your files and orphan your commits
2. **Wait for auto-recovery** (when implemented) - It re-attaches HEAD without touching working directory
3. **If you must use dropdown**: First ensure all changes are committed/pushed, then switch branches

### For Development (Future Improvements)

1. **Fix checkout_branch()** - Instead of force checkout, first check if current commit exists on target branch
2. **Add warning dialog** - Before dropdown checkout, warn about data loss
3. **Show orphaned commits** - Option to see commits that would be orphaned before switching

## Related Issues

- bug-report_detached-head-recovery.md (planned fix - safer auto-recovery)
- bug-report_malformed-rebase-refspec.md
- bug-report_corrupted-loose-objects.md
