# Bug Report: Client Mode 10-Second Scanning Continues in Background

## Issue Summary

**Issue:** Background sync scans every 10 seconds even when disabled or when app is in background

**Severity:** Battery drain - High

**Platform:** Android (and potentially iOS)

**Status:** Fix Fully Implemented (2026-03-24)

---

## Bug Description

When the GitSync app is in the background, the Client Mode feature continues to scan for file changes every 10 seconds, causing excessive battery drain. This occurs regardless of whether Scheduled Sync or App Sync features are enabled.

### Current Behavior

| State | Behavior | Status |
|-------|----------|--------|
| Foreground + Client Mode | Scans every 10 seconds | Expected |
| Background + No sync enabled | Continues scanning every 10 seconds | Bug |
| Background + Scheduled Sync enabled | Still scans every 10 seconds | Bug |
| Background + App-open/close sync only | Still scans every 10 seconds | Bug |

### Expected Behavior

| State | Behavior | Status |
|-------|----------|--------|
| Foreground + Client Mode | Scans every 10 seconds | Expected |
| Background + Scheduled Sync enabled | Scan at scheduled interval (WorkManager) | Expected |
| Background + App-open/close sync only | NO periodic scan (only on app open/close) | Expected |
| Background + No sync enabled | NO periodic scan | Expected |

---

## Root Cause Analysis

### Problem Location

**File:** `lib/main.dart`
**Class:** `_MyHomePageState`

### Code Flow

1. **Timer Definition** (line 626):
   ```dart
   Timer? autoRefreshTimer;
   ```

2. **Timer Scheduling** (lines 1022-1032):
   ```dart
   void _scheduleNextRecommendedAction(DateTime startTime) {
     autoRefreshTimer?.cancel();
     const minDelay = Duration(seconds: 10);
     final elapsed = DateTime.now().difference(startTime);
     final remaining = minDelay - elapsed;
     if (remaining <= Duration.zero) {
       autoRefreshTimer = Timer(Duration.zero, () async => await updateRecommendedAction());
     } else {
       autoRefreshTimer = Timer(remaining, () async => await updateRecommendedAction());
     }
   }
   ```

3. **Timer Triggered From** `updateRecommendedAction()` (lines 998-1020):
   ```dart
   Future<void> updateRecommendedAction({int? override, bool useOverride = false}) async {
     if (!await uiSettingsManager.getClientModeEnabled()) {
       await updateSyncOptions();
       return;
     }
     // ... schedules timer unconditionally:
     _scheduleNextRecommendedAction(startTime);
   }
   ```

4. **Lifecycle Handling** (lines 1370-1378):
   ```dart
   @override
   void didChangeAppLifecycleState(AppLifecycleState state) async {
     if (state == AppLifecycleState.resumed) {
       await GitManager.clearLocks();
       await reloadAll();  // This calls updateRecommendedAction() which schedules timer
     }
     if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
       autoRefreshTimer?.cancel();
     }
   }
   ```

### Root Cause

**Race Condition in Lifecycle Handling:**

The `didChangeAppLifecycleState()` method has a race condition due to async operations:

1. When `AppLifecycleState.resumed` fires:
   - `reloadAll()` is called (async operation)
   - `reloadAll()` eventually calls `updateRecommendedAction()`
   - `updateRecommendedAction()` calls `_scheduleNextRecommendedAction()`
   - Timer is scheduled

2. When `AppLifecycleState.paused` fires:
   - `autoRefreshTimer?.cancel()` is called

**The Problem:** On Android, the app may briefly transition through multiple states. If `paused` is processed after `reloadAll()` completes, the timer will be rescheduled after the cancellation attempt, effectively overriding the cancel call.

### Design Context

**Client Mode Purpose:**
- Client Mode is designed to watch local files and provide recommendations for the next action
- It should ONLY scan for changes when the app is in the **foreground**
- Scheduled Sync and App Sync handle background syncing via separate mechanisms:
  - **Scheduled Sync:** Uses WorkManager with configurable intervals
  - **App Sync:** Uses Accessibility Service to detect app open/close events
- Neither Scheduled Sync nor App Sync use the 10-second `autoRefreshTimer`

---

## Fix Implementation

### Solution Overview

Add foreground state tracking to prevent the 10-second timer from being scheduled when the app is in the background.

### Changes Made

#### 1. Add Foreground State Tracking Variable

**File:** `lib/main.dart`
**Location:** Line 626 (after `Timer? autoRefreshTimer;`)

```dart
Timer? autoRefreshTimer;
bool _isAppInForeground = true;
```

#### 2. Guard `_scheduleNextRecommendedAction()`

**File:** `lib/main.dart`
**Location:** Lines 1022-1032

**Before:**
```dart
void _scheduleNextRecommendedAction(DateTime startTime) {
  autoRefreshTimer?.cancel();
  const minDelay = Duration(seconds: 10);
  final elapsed = DateTime.now().difference(startTime);
  final remaining = minDelay - elapsed;
  if (remaining <= Duration.zero) {
    autoRefreshTimer = Timer(Duration.zero, () async => await updateRecommendedAction());
  } else {
    autoRefreshTimer = Timer(remaining, () async => await updateRecommendedAction());
  }
}
```

**After:**
```dart
void _scheduleNextRecommendedAction(DateTime startTime) {
  autoRefreshTimer?.cancel();
  
  // Only schedule if app is in foreground
  if (!_isAppInForeground) return;
  
  const minDelay = Duration(seconds: 10);
  final elapsed = DateTime.now().difference(startTime);
  final remaining = minDelay - elapsed;
  if (remaining <= Duration.zero) {
    autoRefreshTimer = Timer(Duration.zero, () async => await updateRecommendedAction());
  } else {
    autoRefreshTimer = Timer(remaining, () async => await updateRecommendedAction());
  }
}
```

#### 3. Update `didChangeAppLifecycleState()`

**File:** `lib/main.dart`
**Location:** Lines 1370-1378

**Before:**
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) async {
  if (state == AppLifecycleState.resumed) {
    await GitManager.clearLocks();
    await reloadAll();
  }
  if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
    autoRefreshTimer?.cancel();
  }
}
```

**After:**
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) async {
  if (state == AppLifecycleState.resumed) {
    _isAppInForeground = true;  // Set flag BEFORE async operations
    await GitManager.clearLocks();
    await reloadAll();
  }
  if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
    _isAppInForeground = false;  // Set flag to prevent re-scheduling
    autoRefreshTimer?.cancel();
  }
}
```

#### 4. Add Foreground Check to `updateRecommendedAction()`

**File:** `lib/main.dart`
**Location:** Lines 998-1002

**Before:**
```dart
Future<void> updateRecommendedAction({int? override, bool useOverride = false}) async {
  if (!await uiSettingsManager.getClientModeEnabled()) {
    await updateSyncOptions();
    return;
  }
```

**After:**
```dart
Future<void> updateRecommendedAction({int? override, bool useOverride = false}) async {
  // Don't run if client mode is disabled OR if app is in background
  if (!await uiSettingsManager.getClientModeEnabled() || !_isAppInForeground) {
    await updateSyncOptions();
    return;
  }
```

---

## Impact Analysis

### What This Fix Does

1. **Prevents 10-second scanning in background:** The `_isAppInForeground` flag ensures the timer is only scheduled when the app is in the foreground
2. **Fixes race condition:** Setting the flag before async operations prevents re-scheduling after cancellation
3. **Maintains existing functionality:** All other sync modes (Scheduled, App) continue to work unchanged

### What This Fix Does NOT Affect

1. **Scheduled Sync:** Uses WorkManager, does not use `autoRefreshTimer`
2. **App Sync:** Uses Accessibility Service, does not use `autoRefreshTimer`
3. **Foreground scanning:** Client Mode continues to work correctly in foreground

---

## Testing Recommendations

1. **Background Battery Test:** Monitor battery drain with app in background for extended period
2. **Foreground Functionality:** Verify Client Mode recommendations still appear in foreground
3. **Scheduled Sync Verification:** Confirm scheduled sync continues to work in background
4. **App Sync Verification:** Confirm app-open/close sync triggers work correctly
5. **Lifecycle Transitions:** Test rapid app open/close to ensure no race conditions

---

## Files Modified

| File | Lines | Change Description |
|------|-------|-------------------|
| `lib/main.dart` | 626 | Added `_isAppInForeground` variable |
| `lib/main.dart` | 1022-1032 | Added foreground check in `_scheduleNextRecommendedAction()` |
| `lib/main.dart` | 1370-1378 | Added foreground flag management in `didChangeAppLifecycleState()` |
| `lib/main.dart` | 998-1002 | Added foreground check in `updateRecommendedAction()` |

---

## Related Code References

- **Timer Definition:** `lib/main.dart:626`
- **Timer Scheduling:** `lib/main.dart:1022-1032`
- **Timer Cancellation:** `lib/main.dart:1376`
- **Client Mode Check:** `lib/main.dart:999`
- **Scheduled Sync Implementation:** `lib/main.dart:147-172` (WorkManager callbackDispatcher)
- **App Sync Implementation:** `lib/gitsync_service.dart:362-398` (accessibilityEvent)

---

## Additional Fix: Complete Background Scanning Stop (2026-03-24)

### Problem Discovered After Initial Fix

Even after the initial fix (stopping the timer), the app was still running git operations in background. This was because `updateRecommendedAction()` was calling `updateSyncOptions()` even when in background, triggering git operations every 10 seconds.

### Root Cause

```dart
// In updateRecommendedAction()
if (!await uiSettingsManager.getClientModeEnabled() || !_isAppInForeground) {
    await updateSyncOptions();  // <-- This was still running in background!
    return;
}
```

### Solution

Removed the `await updateSyncOptions()` call when in background:

```dart
// After fix
if (!await uiSettingsManager.getClientModeEnabled() || !_isAppInForeground) {
    return;  // Do nothing in background - no scanning, no sync options
}
```

### Behavior After Both Fixes

| State | Behavior |
|-------|----------|
| Foreground + Client Mode | Scans every 10 seconds (expected) |
| Background + Client Mode | NO periodic scan at all |
| Background + Scheduled Sync | Still works (WorkManager) |
| Background + App Sync | Still works (Accessibility) |

### Files Modified

- `lib/main.dart:1000-1003` (updateRecommendedAction function)

---

## Testing the Fix

See [build_instructions.md](./build_instructions.md) for detailed build and testing instructions.

### Quick Test Steps

1. **Install dependencies:**
   ```bash
   ./build.sh pub get
   ```

2. **Build the app:**
   ```bash
   ./build.sh build apk --debug
   ```

3. **Install on device:**
   - Transfer the APK to your device
   - Install and open the app
   - Enable Client Mode in settings

4. **Verify the fix:**
   - Put app in background
   - Check that the 10-second scanning has stopped
   - Battery drain should be significantly reduced

### Expected Behavior After Fix

| State | Behavior |
|-------|----------|
| Foreground + Client Mode | Scans every 10 seconds (expected) |
| Background + No sync | NO periodic scan |
| Background + Scheduled Sync | Syncs at scheduled intervals only |
| Background + App Sync | Syncs on app open/close only |

