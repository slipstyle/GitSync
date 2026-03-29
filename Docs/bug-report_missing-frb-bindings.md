# Bug Report: Missing FRB Bindings

## Summary

**Type:** Runtime Error / Missing Functionality  
**Severity:** High  
**Component:** Flutter Rust Bridge (FRB)  
**Issue:** Multiple Git operations were not exposed to Dart due to missing FRB-generated bindings

---

## Affected Functions

The following Rust functions existed but were not available in Dart:

| Function | Description |
|----------|-------------|
| `squash_commits` | Squash multiple commits into one |
| `amend_commit` | Amend the last commit message/files |
| `revert_commit` | Revert a commit |
| `undo_commit` | Undo the last commit (soft reset) |
| `reset_to_commit` | Reset HEAD to a specific commit |
| `cherry_pick_commit` | Cherry-pick a commit onto current branch |

---

## Symptom

When users attempted to use these features from the Flutter app, they would receive a runtime error:

```
MissingPluginException(ChannelInvokedMethod)
```

Or more specifically:
```
Error: Function 'crateApiGitManagerSquashCommits' not found in FRB generated bindings
```

---

## Root Cause

The FRB (Flutter Rust Bridge) code generator was not run after certain Rust functions were added to `git_manager.rs`. The Dart API wrappers existed at `lib/src/rust/api/git_manager.dart`, but the generated bindings at `lib/src/rust/frb_generated.dart` were missing the corresponding function declarations.

---

## Fix

Regenerated the FRB bindings by running:

```bash
flutter_rust_bridge_codegen generate \
    --rust-input "crate::api" \
    --dart-output "lib/src/rust" \
    --rust-root "rust/"
```

This regenerated `lib/src/rust/frb_generated.dart` to include all public Rust functions.

---

## Files Modified

| File | Change |
|------|--------|
| `lib/src/rust/frb_generated.dart` | Regenerated to include all missing functions |
| `lib/src/rust/api/git_manager.dart` | Updated comment listing ignored functions |

---

## Verification

After the fix, all functions should be accessible from Dart:

```dart
// All these calls should work without errors
await GitManager.squashCommits(...);
await GitManager.amendCommit(...);
await GitManager.revertCommit(...);
await GitManager.undoCommit(...);
await GitManager.resetToCommit(...);
await GitManager.cherryPickCommit(...);
```

---

## Branch

**Branch:** `fix/frb-bindings`  
**Commit:** `2c872f4`
