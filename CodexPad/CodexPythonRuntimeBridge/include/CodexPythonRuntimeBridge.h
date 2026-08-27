#ifndef CODEX_PYTHON_RUNTIME_BRIDGE_H
#define CODEX_PYTHON_RUNTIME_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CodexPythonSession *CodexPythonSessionRef;

typedef enum CodexPythonStatus {
    CODEX_PYTHON_OK = 0,
    CODEX_PYTHON_INVALID_ARGUMENT = 1,
    CODEX_PYTHON_NOT_INITIALIZED = 2,
    CODEX_PYTHON_ALREADY_STARTED = 3,
    CODEX_PYTHON_INPUT_CLOSED = 4,
    CODEX_PYTHON_RUNTIME_ERROR = 5
} CodexPythonStatus;

typedef enum CodexPythonRunKind {
    CODEX_PYTHON_RUN_MODULE = 1,
    CODEX_PYTHON_RUN_PATH = 2,
    CODEX_PYTHON_RUN_COMMAND = 3,
    CODEX_PYTHON_RUN_ENTRYPOINT = 4
} CodexPythonRunKind;

typedef struct CodexPythonRuntimeConfig {
    const char *python_home_utf8;
    const char *const *module_search_paths_utf8;
    size_t module_search_path_count;
} CodexPythonRuntimeConfig;

typedef struct CodexPythonSessionConfig {
    CodexPythonRunKind run_kind;
    const char *target_utf8;
    const char *display_name_utf8;
    const char *working_directory_utf8;
    /*
     * argv_utf8 is the complete sys.argv value, including argv[0]. When argc
     * is zero the bridge supplies display_name_utf8 as the sole argv entry.
     */
    const char *const *argv_utf8;
    size_t argc;
    const char *const *environment_keys_utf8;
    const char *const *environment_values_utf8;
    size_t environment_count;
} CodexPythonSessionConfig;

typedef void (*CodexPythonBytesCallback)(
    void *context,
    const uint8_t *bytes,
    size_t length
);

/*
 * Callbacks execute on an internal session thread and never while that thread
 * owns CPython's GIL. Byte and error pointers are valid only for the duration
 * of the callback; consumers must copy data retained beyond the callback.
 */
typedef void (*CodexPythonTerminationCallback)(
    void *context,
    int32_t exit_code,
    const char *error_utf8
);

typedef struct CodexPythonCallbacks {
    void *context;
    CodexPythonBytesCallback stdout_callback;
    CodexPythonBytesCallback stderr_callback;
    CodexPythonTerminationCallback termination_callback;
} CodexPythonCallbacks;

CodexPythonStatus codex_python_runtime_initialize(
    const CodexPythonRuntimeConfig *config,
    char **error_utf8
);

CodexPythonStatus codex_python_session_create(
    const CodexPythonSessionConfig *config,
    const CodexPythonCallbacks *callbacks,
    CodexPythonSessionRef *session_out,
    char **error_utf8
);

CodexPythonStatus codex_python_session_start(
    CodexPythonSessionRef session,
    char **error_utf8
);

CodexPythonStatus codex_python_session_write(
    CodexPythonSessionRef session,
    const uint8_t *bytes,
    size_t length
);

CodexPythonStatus codex_python_session_close_stdin(
    CodexPythonSessionRef session
);

CodexPythonStatus codex_python_session_cancel(
    CodexPythonSessionRef session
);

void codex_python_session_release(CodexPythonSessionRef session);
void codex_python_error_free(char *error_utf8);

#ifdef __cplusplus
}
#endif

#endif
