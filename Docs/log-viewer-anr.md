# GitSync Log Viewer ANR Bug Report

## Bug Summary

**Type:** ANR (Application Not Responding)  
**Severity:** High  
**Component:** Log Viewer / Code Editor  
**Trigger:** Opening the logs window  

## Affected Versions

| Field | Value |
|-------|-------|
| App Package | com.viscouspot.gitsync |
| Version Code | 3836 |
| Target SDK | 36 |
| Android Version | 16 (BP4A.260205.001) |
| Device | Google Husky (Pixel 9 Pro) |
| Install Source | dev.imranr.obtainium |

## Reproduction

1. User has accumulated log files (log_0.log, log_1.log, etc.) in app temp directory
2. User taps to open the logs viewer window
3. App UI freezes for 5+ seconds
4. Android system displays ANR dialog and kills the app

## Stack Traces

### Crash 1
- **File:** `Error in GitSync 9480683a2247.txt`
- **Time:** 2026-03-21 05:47:40
- **Trigger:** MotionEvent timeout (5000ms)
- **Memory:** RSS=432MB, Heap High Water Mark=432MB

### Crash 2
- **File:** `Error in GitSync 277b5d76c8b3.txt`
- **Time:** 2026-03-21 05:45:09
- **Trigger:** MotionEvent + FocusEvent timeout (5001ms)
- **Memory:** RSS=417MB, Heap High Water Mark=417MB

### Crash 3
- **File:** `Error in GitSync 1b9063c01f0d.txt`
- **Time:** 2026-03-21 05:37:20
- **Trigger:** MotionEvent timeout (5002ms)
- **Memory:** RSS=516MB, VmSwap=281MB (memory pressure)

### Crash 4
- **File:** `Error in GitSync 09d4bef344e9.txt`
- **Time:** 2026-03-21 05:41:29
- **Trigger:** MotionEvent + FocusEvent timeout (5005ms)
- **Memory:** RSS=447MB

### Common Pattern in All Crashes

All crashes show the main thread blocked in native Flutter code:
```
"main" prio=5 tid=1 Native
  native: #00 pc 000932ec  libc.so (pthread_mutex_unlock)
  native: #01-#46 /libflutter.so (???)
  native: #47-#74 /libapp.so (???)
  at android.os.MessageQueue.nativePollOnce(Native method)
  at android.os.Looper.loopOnce(Looper.java:197)
  at android.os.ActivityThread.main(ActivityThread.java:9331)
```

The main thread is waiting in `Looper.loopOnce()` which processes UI events, but cannot respond because it's blocked doing work.

## Root Cause Analysis

### File Location
`lib/ui/page/code_editor.dart`

### Problematic Code (lines 430-464)

```dart
// Lines 430-433: Synchronous file loading
try {
  _mapFile();
  controller.text = writeMmap == null 
      ? widget.text ?? "" 
      : utf8.decode(writeMmap!.writableData, allowMalformed: true);
  
  // This creates MULTIPLE copies of the entire string:
  if (widget.type == EditorType.LOGS) 
    controller.text = controller.text.split("\n").reversed.join("\n");
  
  controller.addListener(_onTextChanged);
} catch (e) {
  print(e);
}

// Lines 440-464: Blocking chunk analysis with polling loop
WidgetsBinding.instance.addPostFrameCallback((_) {
  initAsync(() async {
    if (widget.type != EditorType.LOGS || controller.text.isEmpty) return;
    
    final chunkController = ReEditor.CodeChunkController(controller, LogsChunkAnalyzer());
    try {
      // PROBLEM: Busy-wait loop blocks main thread
      while (chunkController.value.isEmpty) {
        await Future.delayed(Duration(milliseconds: 100));  // Still on main thread!
      }
      // ... collapse chunks ...
      logsCollapsed = true;
    } catch (e) { ... }
  });
});
```

### Why This Causes ANR

1. **Main thread blocking:** All file I/O happens on the main/UI thread
2. **No loading indicator:** User sees frozen UI with no feedback
3. **Large string operations:** `split().reversed().join()` creates O(n) memory copies
4. **Busy-wait loop:** `while (chunkController.value.isEmpty)` with 100ms delays keeps main thread busy
5. **Log file size:** Log files can be megabytes in size, especially for long-running sync operations

### Memory Usage Pattern

| Phase | Memory Impact |
|-------|--------------|
| File read | ~file size |
| utf8.decode | ~file size (2nd copy) |
| split("\n") | ~file size (3rd copy) |
| reversed | ~file size (4th copy) |
| join("\n") | ~file size (5th copy) |

For a 5MB log file, this creates 25MB+ of temporary allocations, causing GC pressure.

## Existing Architecture

### File Pagination (Already Implemented)
Log files are paginated at the file level:
```
log_4.log (newest) -> log_3.log -> log_2.log -> ... -> log_0.log (oldest)
```

User can navigate between files using prev/next buttons. However, each individual file is still loaded synchronously.

### Log File Format
- Location: `{tempDirectory}/logs/`
- Naming: `log_{number}.log`
- Content: Plain text with timestamped entries
- Example entry format: `2026-03-21 05:30:15.123 [I] Sync: Starting sync operation`

## Proposed Fix

### Solution: Move File Loading to Background Isolate

Use Flutter's `compute()` function to load log files in a background isolate, keeping the main thread responsive.

#### Implementation Changes

**File:** `lib/ui/page/code_editor.dart`

1. Add import:
```dart
import 'package:flutter/foundation.dart';
```

2. Add loading state:
```dart
bool isLoading = true;
```

3. Add compute function (top-level, outside class):
```dart
// Must be top-level for compute() to work with isolates
String _loadLogFile(String path) {
  final file = File(path);
  return file.readAsStringSync();
}
```

4. Modify `initState()` to load asynchronously:
```dart
// Replace synchronous loading with:
if (widget.type == EditorType.LOGS && widget.path != null) {
  // Load on background isolate - UI stays responsive
  final content = await compute(_loadLogFile, widget.path!);
  controller.text = content.split("\n").reversed.join("\n");
} else {
  // Keep existing behavior for non-log files
  try {
    _mapFile();
    controller.text = writeMmap == null 
        ? widget.text ?? "" 
        : utf8.decode(writeMmap!.writableData, allowMalformed: true);
  } catch (e) {
    print(e);
  }
}
isLoading = false;
controller.addListener(_onTextChanged);
if (mounted) setState(() {});
```

5. Update `build()` to show loading indicator:
```dart
// In the Container child, add loading check:
child: widget.type == EditorType.LOGS && (isLoading || !logsCollapsed)
    ? Center(child: CircularProgressIndicator(color: colours.primaryLight))
    : ReEditor.CodeEditor(...)
```

### Why This Fix Works

1. **Non-blocking I/O:** File reading happens in a separate isolate
2. **Responsive UI:** Main thread can process events and show loading indicator
3. **Same memory efficiency:** Isolate has its own heap - no impact on main thread's GC
4. **Minimal code change:** Uses existing `compute()` infrastructure from Flutter

### Alternative Approaches Considered

1. **Pagination within log file:** Would require significant widget restructuring
2. **Streaming file read:** Would require custom async iterator pattern
3. **Keep mmap in isolate:** More complex, mmap not designed for isolate use

The `compute()` approach was chosen as the simplest fix that directly addresses the ANR.

## Testing Recommendations

1. Create log files of various sizes (1KB, 100KB, 1MB, 5MB, 10MB)
2. Test opening logs on each file size
3. Verify UI remains responsive during loading
4. Check memory usage doesn't spike during load
5. Test file navigation (prev/next between log files)

## Related Files

| File | Purpose |
|------|---------|
| `lib/ui/page/code_editor.dart` | Main log viewer implementation |
| `lib/api/helper.dart` | `openLogViewer()` entry point |
| `lib/api/logger.dart` | Log generation and storage |
| `lib/ui/component/sync_loader.dart` | UI trigger for log viewer |
