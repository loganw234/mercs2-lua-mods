/* probe_marker.c — throwaway ASI used to confirm where the modkit
 * deploys type="asi" assets. Loads cleanly (valid DLL entry point,
 * DllMain returns TRUE) but does absolutely nothing else — no hooks,
 * no threads, no side effects. Safe to install then delete.
 *
 * If you're reading this in production, someone forgot to clean up.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID reserved) {
    (void)h; (void)reason; (void)reserved;
    return TRUE;
}
