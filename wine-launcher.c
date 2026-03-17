/*
 * wine-launcher.c — Compiled x86_64 launcher for relocatable Wine distribution.
 *
 * Reads argv[0] basename to determine what to exec:
 *   "wine"       → libexec/wine
 *   "wineserver" → libexec/wineserver
 *   anything else (winecfg, regedit, …) → libexec/wine <basename>
 *
 * Sets DYLD_FALLBACK_LIBRARY_PATH and WINELOADER before exec.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    /* Get absolute path to this binary */
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0) {
        fprintf(stderr, "wine-launcher: _NSGetExecutablePath failed\n");
        return 1;
    }
    char self[PATH_MAX];
    if (!realpath(raw, self)) {
        perror("wine-launcher: realpath");
        return 1;
    }

    /* Compute WINE_ROOT = dirname(dirname(self)) */
    char *bindir = dirname(self);       /* .../wine/libexec   */
    char root[PATH_MAX];
    snprintf(root, sizeof(root), "%s/..", bindir);
    char wine_root[PATH_MAX];
    if (!realpath(root, wine_root)) {
        perror("wine-launcher: realpath root");
        return 1;
    }

    /* Set environment */
    char lib_path[PATH_MAX];
    snprintf(lib_path, sizeof(lib_path), "%s/lib/external", wine_root);
    const char *existing = getenv("DYLD_FALLBACK_LIBRARY_PATH");
    if (existing && existing[0]) {
        char combined[PATH_MAX * 2];
        snprintf(combined, sizeof(combined), "%s:%s", lib_path, existing);
        setenv("DYLD_FALLBACK_LIBRARY_PATH", combined, 1);
    } else {
        setenv("DYLD_FALLBACK_LIBRARY_PATH", lib_path, 1);
    }

    char loader[PATH_MAX];
    snprintf(loader, sizeof(loader), "%s/libexec/wine", wine_root);
    setenv("WINELOADER", loader, 1);

    /* Determine what to exec based on argv[0] basename */
    char *name = basename(argv[0]);

    if (strcmp(name, "wine") == 0 || strcmp(name, "wine64") == 0) {
        /* Exec libexec/wine directly */
        argv[0] = loader;
        execv(loader, argv);
    } else if (strcmp(name, "wineserver") == 0) {
        /* Exec libexec/wineserver */
        char server[PATH_MAX];
        snprintf(server, sizeof(server), "%s/libexec/wineserver", wine_root);
        argv[0] = server;
        execv(server, argv);
    } else if (strcmp(name, "winegcc") == 0 || strcmp(name, "wineg++") == 0 ||
               strcmp(name, "winebuild") == 0 || strcmp(name, "widl") == 0 ||
               strcmp(name, "winedump") == 0 || strcmp(name, "wmc") == 0 ||
               strcmp(name, "wrc") == 0) {
        /* Dev tools: exec libexec/<tool> directly */
        char tool[PATH_MAX];
        snprintf(tool, sizeof(tool), "%s/libexec/%s", wine_root, name);
        argv[0] = tool;
        execv(tool, argv);
    } else {
        /* argv[0] dispatch: exec libexec/wine <basename> args... */
        int new_argc = argc + 1;
        char **new_argv = malloc((new_argc + 1) * sizeof(char *));
        if (!new_argv) {
            perror("wine-launcher: malloc");
            return 1;
        }
        new_argv[0] = loader;
        new_argv[1] = name;
        for (int i = 1; i < argc; i++)
            new_argv[i + 1] = argv[i];
        new_argv[new_argc] = NULL;
        execv(loader, new_argv);
    }

    perror("wine-launcher: execv");
    return 1;
}
