#ifndef RUNNER_SYNTHETIC_KEYS_H_
#define RUNNER_SYNTHETIC_KEYS_H_

#include <windows.h>

// Makes keystrokes another program sends look like keystrokes a keyboard sent.
//
// Windows 11's clipboard history (Win+V), and dictation tools such as Wispr
// Flow, put their text on the clipboard and then press Ctrl+V on the app's
// behalf. The key messages they send carry no scan code — only the virtual
// key — and the Flutter engine names keys by scan code. Every one of those
// keys therefore arrives as the same unknown physical key: Ctrl and V collide,
// the engine releases Ctrl to make room for V, and the framework never sees a
// V pressed while Ctrl is held. Nothing is pasted, and no error is raised.
//
// This subclasses |flutter_view| — the engine's own child window, the one the
// key messages are addressed to — and fills in the scan code Windows would
// have sent for that virtual key before the engine reads the message. Real
// keystrokes already carry one and pass through untouched. The subclass
// removes itself when the window is destroyed.
void RepairSyntheticKeys(HWND flutter_view);

#endif  // RUNNER_SYNTHETIC_KEYS_H_
