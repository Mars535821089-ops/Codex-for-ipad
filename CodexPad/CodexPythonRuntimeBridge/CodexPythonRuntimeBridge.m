#define PY_SSIZE_T_CLEAN

#include "CodexPythonRuntimeBridge.h"

#include <Python/Python.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct CodexPythonSession {
    _Atomic int reference_count;
    pthread_mutex_t lock;
    pthread_cond_t input_changed;
    bool started;
    bool input_closed;
    bool cancelled;
    bool terminated;
    uint8_t *input;
    size_t input_length;
    size_t input_capacity;
    CodexPythonRunKind run_kind;
    char *target;
    char *display_name;
    char *working_directory;
    char **argv;
    size_t argc;
    char **environment_keys;
    char **environment_values;
    size_t environment_count;
    CodexPythonCallbacks callbacks;
};

static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static bool runtime_initialized = false;
static bool runtime_initialization_attempted = false;

static char *copy_string(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value);
    char *copy = malloc(length + 1);
    if (copy != NULL) {
        memcpy(copy, value, length + 1);
    }
    return copy;
}

static void set_error(char **error_utf8, const char *message) {
    if (error_utf8 == NULL) {
        return;
    }
    *error_utf8 = copy_string(
        message == NULL ? "embedded CPython runtime error" : message
    );
}

static void set_status_error(
    char **error_utf8,
    PyStatus status,
    const char *fallback
) {
    if (PyStatus_Exception(status) && status.err_msg != NULL) {
        set_error(error_utf8, status.err_msg);
    } else {
        set_error(error_utf8, fallback);
    }
}

static bool copy_string_array(
    const char *const *source,
    size_t count,
    char ***destination
) {
    *destination = NULL;
    if (count == 0) {
        return true;
    }
    char **values = calloc(count, sizeof(char *));
    if (values == NULL) {
        return false;
    }
    for (size_t index = 0; index < count; index++) {
        if (source == NULL || source[index] == NULL) {
            for (size_t prior = 0; prior < index; prior++) {
                free(values[prior]);
            }
            free(values);
            return false;
        }
        values[index] = copy_string(source[index]);
        if (values[index] == NULL) {
            for (size_t prior = 0; prior < index; prior++) {
                free(values[prior]);
            }
            free(values);
            return false;
        }
    }
    *destination = values;
    return true;
}

static void free_string_array(char **values, size_t count) {
    if (values == NULL) {
        return;
    }
    for (size_t index = 0; index < count; index++) {
        free(values[index]);
    }
    free(values);
}

static void session_retain(struct CodexPythonSession *session) {
    atomic_fetch_add_explicit(
        &session->reference_count,
        1,
        memory_order_relaxed
    );
}

static void session_destroy(struct CodexPythonSession *session) {
    pthread_mutex_destroy(&session->lock);
    pthread_cond_destroy(&session->input_changed);
    free(session->input);
    free(session->target);
    free(session->display_name);
    free(session->working_directory);
    free_string_array(session->argv, session->argc);
    free_string_array(
        session->environment_keys,
        session->environment_count
    );
    free_string_array(
        session->environment_values,
        session->environment_count
    );
    free(session);
}

void codex_python_session_release(CodexPythonSessionRef session) {
    if (session == NULL) {
        return;
    }
    int previous = atomic_fetch_sub_explicit(
        &session->reference_count,
        1,
        memory_order_acq_rel
    );
    if (previous == 1) {
        session_destroy(session);
    }
}

void codex_python_error_free(char *error_utf8) {
    free(error_utf8);
}

static struct CodexPythonSession *session_from_capsule(
    PyObject *capsule
) {
    if (capsule == Py_None) {
        return NULL;
    }
    return PyCapsule_GetPointer(capsule, "CodexPythonSession");
}

static size_t session_read_count(
    struct CodexPythonSession *session,
    Py_ssize_t requested,
    bool line
) {
    size_t count = session->input_length;
    if (line && session->input_length > 0) {
        const void *newline = memchr(
            session->input,
            '\n',
            session->input_length
        );
        if (newline != NULL) {
            count =
                (const uint8_t *)newline - session->input + 1;
        }
    }
    if (requested >= 0 && (size_t)requested < count) {
        count = (size_t)requested;
    }
    return count;
}

static bool session_read_ready(
    struct CodexPythonSession *session,
    Py_ssize_t requested,
    bool line
) {
    if (requested == 0) {
        return true;
    }
    if (session->input_length == 0) {
        return session->input_closed || session->cancelled;
    }
    if (!line) {
        if (requested >= 0) {
            return true;
        }
        return session->input_closed || session->cancelled;
    }
    if (memchr(session->input, '\n', session->input_length) != NULL) {
        return true;
    }
    if (requested >= 0
        && session->input_length >= (size_t)requested) {
        return true;
    }
    return session->input_closed || session->cancelled;
}

static PyObject *session_read(
    PyObject *arguments,
    bool line
) {
    PyObject *capsule = NULL;
    Py_ssize_t requested = -1;
    if (!PyArg_ParseTuple(arguments, "O|n", &capsule, &requested)) {
        return NULL;
    }
    struct CodexPythonSession *session =
        session_from_capsule(capsule);
    if (session == NULL) {
        if (capsule == Py_None) {
            return PyBytes_FromStringAndSize("", 0);
        }
        return NULL;
    }

    uint8_t *copy = NULL;
    size_t count = 0;
    Py_BEGIN_ALLOW_THREADS
    pthread_mutex_lock(&session->lock);
    while (!session_read_ready(session, requested, line)) {
        pthread_cond_wait(
            &session->input_changed,
            &session->lock
        );
    }
    count = session_read_count(session, requested, line);
    if (count > 0) {
        copy = malloc(count);
        if (copy != NULL) {
            memcpy(copy, session->input, count);
            memmove(
                session->input,
                session->input + count,
                session->input_length - count
            );
            session->input_length -= count;
        }
    }
    pthread_mutex_unlock(&session->lock);
    Py_END_ALLOW_THREADS

    if (count > 0 && copy == NULL) {
        return PyErr_NoMemory();
    }
    PyObject *result = PyBytes_FromStringAndSize(
        (const char *)copy,
        (Py_ssize_t)count
    );
    free(copy);
    return result;
}

static PyObject *stdio_read(PyObject *self, PyObject *arguments) {
    (void)self;
    return session_read(arguments, false);
}

static PyObject *stdio_readline(
    PyObject *self,
    PyObject *arguments
) {
    (void)self;
    return session_read(arguments, true);
}

static PyObject *stdio_write(
    PyObject *arguments,
    bool standard_error
) {
    PyObject *capsule = NULL;
    Py_buffer bytes;
    if (!PyArg_ParseTuple(arguments, "Oy*", &capsule, &bytes)) {
        return NULL;
    }
    struct CodexPythonSession *session =
        session_from_capsule(capsule);
    if (session == NULL) {
        PyBuffer_Release(&bytes);
        if (capsule == Py_None) {
            Py_RETURN_NONE;
        }
        return NULL;
    }
    CodexPythonBytesCallback callback = standard_error
        ? session->callbacks.stderr_callback
        : session->callbacks.stdout_callback;
    if (callback != NULL && bytes.len > 0) {
        /*
         * Swift callbacks must never run while CPython owns the GIL. Besides
         * preserving concurrency between MCP sessions, this also prevents a
         * callback that schedules more bridge work from deadlocking itself.
         * The parsed argument tuple keeps the exported buffer alive until
         * PyBuffer_Release below.
         */
        Py_BEGIN_ALLOW_THREADS
        callback(
            session->callbacks.context,
            (const uint8_t *)bytes.buf,
            (size_t)bytes.len
        );
        Py_END_ALLOW_THREADS
    }
    PyBuffer_Release(&bytes);
    Py_RETURN_NONE;
}

static PyObject *stdio_stdout(
    PyObject *self,
    PyObject *arguments
) {
    (void)self;
    return stdio_write(arguments, false);
}

static PyObject *stdio_stderr(
    PyObject *self,
    PyObject *arguments
) {
    (void)self;
    return stdio_write(arguments, true);
}

static PyObject *stdio_cancelled(
    PyObject *self,
    PyObject *arguments
) {
    (void)self;
    PyObject *capsule = NULL;
    if (!PyArg_ParseTuple(arguments, "O", &capsule)) {
        return NULL;
    }
    struct CodexPythonSession *session =
        session_from_capsule(capsule);
    if (session == NULL) {
        if (capsule == Py_None) {
            Py_RETURN_FALSE;
        }
        return NULL;
    }
    pthread_mutex_lock(&session->lock);
    bool cancelled = session->cancelled;
    pthread_mutex_unlock(&session->lock);
    if (cancelled) {
        Py_RETURN_TRUE;
    }
    Py_RETURN_FALSE;
}

static PyMethodDef stdio_methods[] = {
    {
        "read",
        (PyCFunction)stdio_read,
        METH_VARARGS,
        NULL,
    },
    {
        "readline",
        (PyCFunction)stdio_readline,
        METH_VARARGS,
        NULL,
    },
    {
        "stdout",
        (PyCFunction)stdio_stdout,
        METH_VARARGS,
        NULL,
    },
    {
        "stderr",
        (PyCFunction)stdio_stderr,
        METH_VARARGS,
        NULL,
    },
    {
        "cancelled",
        (PyCFunction)stdio_cancelled,
        METH_VARARGS,
        NULL,
    },
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef stdio_module = {
    PyModuleDef_HEAD_INIT,
    "_codex_stdio",
    NULL,
    -1,
    stdio_methods,
    NULL,
    NULL,
    NULL,
    NULL,
};

PyMODINIT_FUNC PyInit__codex_stdio(void) {
    return PyModule_Create(&stdio_module);
}

static const char *bootstrap_source =
    "import asyncio\n"
    "import collections.abc\n"
    "import contextvars\n"
    "import importlib\n"
    "import inspect\n"
    "import io\n"
    "import os\n"
    "import runpy\n"
    "import sys\n"
    "import traceback\n"
    "import types\n"
    "import _codex_stdio as _native\n"
    "_session = contextvars.ContextVar('_codex_session', default=None)\n"
    "_argv = contextvars.ContextVar('_codex_argv', default=())\n"
    "_environment = contextvars.ContextVar('_codex_environment', default={})\n"
    "_original_environment = dict(os.environ)\n"
    "_original_getcwd = os.getcwd\n"
    "_cwd = contextvars.ContextVar('_codex_cwd', default=_original_getcwd())\n"
    "class _InputBuffer(io.RawIOBase):\n"
    "    def readable(self): return True\n"
    "    def read(self, size=-1): return _native.read(_session.get(), size)\n"
    "    def readline(self, size=-1): return _native.readline(_session.get(), size)\n"
    "    def readinto(self, target):\n"
    "        data = self.read(len(target))\n"
    "        target[:len(data)] = data\n"
    "        return len(data)\n"
    "    def fileno(self): raise OSError('embedded stream has no file descriptor')\n"
    "class _Input(io.TextIOBase):\n"
    "    def __init__(self): self._buffer = _InputBuffer()\n"
    "    @property\n"
    "    def buffer(self): return self._buffer\n"
    "    @property\n"
    "    def encoding(self): return 'utf-8'\n"
    "    def readable(self): return True\n"
    "    def read(self, size=-1): return self._buffer.read(size).decode('utf-8', 'replace')\n"
    "    def readline(self, size=-1): return self._buffer.readline(size).decode('utf-8', 'replace')\n"
    "    def fileno(self): return self._buffer.fileno()\n"
    "class _OutputBuffer(io.RawIOBase):\n"
    "    def __init__(self, error=False): self._error = error\n"
    "    def writable(self): return True\n"
    "    def write(self, value):\n"
    "        data = bytes(value)\n"
    "        session = _session.get()\n"
    "        if session is not None:\n"
    "            (_native.stderr if self._error else _native.stdout)(session, data)\n"
    "        return len(data)\n"
    "    def flush(self): return None\n"
    "    def fileno(self): raise OSError('embedded stream has no file descriptor')\n"
    "class _Output(io.TextIOBase):\n"
    "    def __init__(self, error=False): self._buffer = _OutputBuffer(error)\n"
    "    @property\n"
    "    def buffer(self): return self._buffer\n"
    "    @property\n"
    "    def encoding(self): return 'utf-8'\n"
    "    def writable(self): return True\n"
    "    def write(self, value):\n"
    "        text = str(value)\n"
    "        self._buffer.write(text.encode('utf-8'))\n"
    "        return len(text)\n"
    "    def flush(self): return None\n"
    "    def fileno(self): return self._buffer.fileno()\n"
    "class _Argv(collections.abc.MutableSequence):\n"
    "    def _value(self): return list(_argv.get())\n"
    "    def __len__(self): return len(_argv.get())\n"
    "    def __getitem__(self, index): return _argv.get()[index]\n"
    "    def __setitem__(self, index, value):\n"
    "        items = self._value(); items[index] = value; _argv.set(tuple(items))\n"
    "    def __delitem__(self, index):\n"
    "        items = self._value(); del items[index]; _argv.set(tuple(items))\n"
    "    def insert(self, index, value):\n"
    "        items = self._value(); items.insert(index, value); _argv.set(tuple(items))\n"
    "class _Environment(collections.abc.MutableMapping):\n"
    "    def _value(self): return _environment.get()\n"
    "    def __getitem__(self, key): return self._value()[key]\n"
    "    def __setitem__(self, key, value):\n"
    "        items = dict(self._value()); items[str(key)] = str(value); _environment.set(items)\n"
    "    def __delitem__(self, key):\n"
    "        items = dict(self._value()); del items[key]; _environment.set(items)\n"
    "    def __iter__(self): return iter(self._value())\n"
    "    def __len__(self): return len(self._value())\n"
    "sys.stdin = _Input()\n"
    "sys.stdout = _Output(False)\n"
    "sys.stderr = _Output(True)\n"
    "sys.argv = _Argv()\n"
    "os.environ = _Environment()\n"
    "os.getcwd = lambda: _cwd.get()\n"
    "def _call_entrypoint(target):\n"
    "    module_name, separator, attribute = target.partition(':')\n"
    "    module = importlib.import_module(module_name)\n"
    "    value = module\n"
    "    if separator:\n"
    "        for component in attribute.split('.'):\n"
    "            value = getattr(value, component)\n"
    "    elif hasattr(module, 'main'):\n"
    "        value = module.main\n"
    "    else:\n"
    "        return runpy.run_module(module_name, run_name='__main__', alter_sys=False)\n"
    "    result = value()\n"
    "    if inspect.isawaitable(result): return asyncio.run(result)\n"
    "    return result\n"
    "def _run(session, kind, target, argv, environment, cwd):\n"
    "    tokens = (\n"
    "        _session.set(session),\n"
    "        _argv.set(tuple(argv)),\n"
    "        _environment.set(dict(environment) if environment else dict(_original_environment)),\n"
    "        _cwd.set(cwd or _original_getcwd()),\n"
    "    )\n"
    "    try:\n"
    "        if kind == 1:\n"
    "            runpy.run_module(target, run_name='__main__', alter_sys=False)\n"
    "        elif kind == 2:\n"
    "            runpy.run_path(target, run_name='__main__')\n"
    "        elif kind == 3:\n"
    "            namespace = {'__name__': '__main__', '__file__': '<string>'}\n"
    "            exec(compile(target, '<string>', 'exec'), namespace, namespace)\n"
    "        elif kind == 4:\n"
    "            _call_entrypoint(target)\n"
    "        else:\n"
    "            raise ValueError(f'unsupported Python run kind: {kind}')\n"
    "        return 0\n"
    "    except SystemExit as error:\n"
    "        if error.code is None: return 0\n"
    "        if isinstance(error.code, int): return int(error.code)\n"
    "        print(error.code, file=sys.stderr)\n"
    "        return 1\n"
    "    except BaseException:\n"
    "        traceback.print_exc(file=sys.stderr)\n"
    "        return 1\n"
    "    finally:\n"
    "        _cwd.reset(tokens[3])\n"
    "        _environment.reset(tokens[2])\n"
    "        _argv.reset(tokens[1])\n"
    "        _session.reset(tokens[0])\n"
    "_codex_bootstrap = types.ModuleType('_codex_bootstrap')\n"
    "_codex_bootstrap.run = _run\n"
    "sys.modules['_codex_bootstrap'] = _codex_bootstrap\n";

static bool append_search_path(
    PyConfig *config,
    const char *path,
    char **error_utf8
) {
    wchar_t *decoded = Py_DecodeLocale(path, NULL);
    if (decoded == NULL) {
        set_error(error_utf8, "failed to decode Python search path");
        return false;
    }
    PyStatus status = PyWideStringList_Append(
        &config->module_search_paths,
        decoded
    );
    PyMem_RawFree(decoded);
    if (PyStatus_Exception(status)) {
        set_status_error(
            error_utf8,
            status,
            "failed to configure Python search path"
        );
        return false;
    }
    return true;
}

CodexPythonStatus codex_python_runtime_initialize(
    const CodexPythonRuntimeConfig *config,
    char **error_utf8
) {
    if (error_utf8 != NULL) {
        *error_utf8 = NULL;
    }
    if (config == NULL
        || config->python_home_utf8 == NULL
        || config->module_search_paths_utf8 == NULL
        || config->module_search_path_count == 0) {
        set_error(error_utf8, "invalid embedded CPython configuration");
        return CODEX_PYTHON_INVALID_ARGUMENT;
    }

    pthread_mutex_lock(&runtime_lock);
    if (runtime_initialized) {
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_OK;
    }
    if (runtime_initialization_attempted) {
        pthread_mutex_unlock(&runtime_lock);
        set_error(
            error_utf8,
            "embedded CPython initialization previously failed"
        );
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    runtime_initialization_attempted = true;

    if (PyImport_AppendInittab(
            "_codex_stdio",
            PyInit__codex_stdio
        ) == -1) {
        pthread_mutex_unlock(&runtime_lock);
        set_error(error_utf8, "failed to register Python stdio bridge");
        return CODEX_PYTHON_RUNTIME_ERROR;
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    preconfig.configure_locale = 0;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        set_status_error(
            error_utf8,
            status,
            "failed to preinitialize embedded CPython"
        );
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_RUNTIME_ERROR;
    }

    PyConfig python_config;
    PyConfig_InitIsolatedConfig(&python_config);
    python_config.use_environment = 0;
    python_config.install_signal_handlers = 0;
    python_config.site_import = 1;
    python_config.write_bytecode = 0;
    python_config.buffered_stdio = 0;
    python_config.module_search_paths_set = 1;

    status = PyConfig_SetBytesString(
        &python_config,
        &python_config.home,
        config->python_home_utf8
    );
    if (PyStatus_Exception(status)) {
        set_status_error(
            error_utf8,
            status,
            "failed to set embedded CPython home"
        );
        PyConfig_Clear(&python_config);
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    status = PyConfig_SetBytesString(
        &python_config,
        &python_config.program_name,
        "Codex for ipad"
    );
    if (PyStatus_Exception(status)) {
        set_status_error(
            error_utf8,
            status,
            "failed to set embedded CPython program name"
        );
        PyConfig_Clear(&python_config);
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    for (
        size_t index = 0;
        index < config->module_search_path_count;
        index++
    ) {
        if (config->module_search_paths_utf8[index] == NULL
            || !append_search_path(
                &python_config,
                config->module_search_paths_utf8[index],
                error_utf8
            )) {
            PyConfig_Clear(&python_config);
            pthread_mutex_unlock(&runtime_lock);
            return CODEX_PYTHON_RUNTIME_ERROR;
        }
    }

    char *argv[] = {"Codex for ipad"};
    status = PyConfig_SetBytesArgv(&python_config, 1, argv);
    if (PyStatus_Exception(status)) {
        set_status_error(
            error_utf8,
            status,
            "failed to configure embedded CPython argv"
        );
        PyConfig_Clear(&python_config);
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    status = Py_InitializeFromConfig(&python_config);
    PyConfig_Clear(&python_config);
    if (PyStatus_Exception(status)) {
        set_status_error(
            error_utf8,
            status,
            "failed to initialize embedded CPython"
        );
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    if (PyRun_SimpleString(bootstrap_source) != 0) {
        PyErr_Clear();
        set_error(error_utf8, "failed to install Python stdio bridge");
        /*
         * Py_InitializeFromConfig succeeded, so the calling thread owns the
         * GIL even though the bootstrap failed. The runtime is deliberately
         * marked unusable, but releasing the GIL avoids permanently blocking
         * unrelated CPython cleanup or diagnostics.
         */
        PyEval_SaveThread();
        pthread_mutex_unlock(&runtime_lock);
        return CODEX_PYTHON_RUNTIME_ERROR;
    }

    runtime_initialized = true;
    PyEval_SaveThread();
    pthread_mutex_unlock(&runtime_lock);
    return CODEX_PYTHON_OK;
}

CodexPythonStatus codex_python_session_create(
    const CodexPythonSessionConfig *config,
    const CodexPythonCallbacks *callbacks,
    CodexPythonSessionRef *session_out,
    char **error_utf8
) {
    if (error_utf8 != NULL) {
        *error_utf8 = NULL;
    }
    if (session_out != NULL) {
        *session_out = NULL;
    }
    if (config == NULL
        || callbacks == NULL
        || session_out == NULL
        || config->target_utf8 == NULL
        || config->display_name_utf8 == NULL
        || config->run_kind < CODEX_PYTHON_RUN_MODULE
        || config->run_kind > CODEX_PYTHON_RUN_ENTRYPOINT
        || (config->argc > 0 && config->argv_utf8 == NULL)
        || config->argc > (size_t)PY_SSIZE_T_MAX
        || (config->environment_count > 0
            && (config->environment_keys_utf8 == NULL
                || config->environment_values_utf8 == NULL))) {
        set_error(error_utf8, "invalid embedded Python session");
        return CODEX_PYTHON_INVALID_ARGUMENT;
    }

    pthread_mutex_lock(&runtime_lock);
    bool initialized = runtime_initialized;
    pthread_mutex_unlock(&runtime_lock);
    if (!initialized) {
        set_error(error_utf8, "embedded CPython is not initialized");
        return CODEX_PYTHON_NOT_INITIALIZED;
    }

    struct CodexPythonSession *session =
        calloc(1, sizeof(struct CodexPythonSession));
    if (session == NULL) {
        set_error(error_utf8, "failed to allocate Python session");
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    atomic_init(&session->reference_count, 1);
    if (pthread_mutex_init(&session->lock, NULL) != 0) {
        free(session);
        set_error(error_utf8, "failed to initialize Python session lock");
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    if (pthread_cond_init(&session->input_changed, NULL) != 0) {
        pthread_mutex_destroy(&session->lock);
        free(session);
        set_error(
            error_utf8,
            "failed to initialize Python session input condition"
        );
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    session->run_kind = config->run_kind;
    session->target = copy_string(config->target_utf8);
    session->display_name =
        copy_string(config->display_name_utf8);
    session->working_directory =
        copy_string(config->working_directory_utf8);
    session->argc = config->argc;
    session->environment_count = config->environment_count;
    session->callbacks = *callbacks;

    bool copied =
        session->target != NULL
        && session->display_name != NULL
        && copy_string_array(
            config->argv_utf8,
            config->argc,
            &session->argv
        )
        && copy_string_array(
            config->environment_keys_utf8,
            config->environment_count,
            &session->environment_keys
        )
        && copy_string_array(
            config->environment_values_utf8,
            config->environment_count,
            &session->environment_values
        );
    if (!copied) {
        session_destroy(session);
        set_error(error_utf8, "failed to copy Python session data");
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    *session_out = session;
    return CODEX_PYTHON_OK;
}

static PyObject *python_string(const char *value) {
    return PyUnicode_DecodeUTF8(
        value == NULL ? "" : value,
        value == NULL ? 0 : (Py_ssize_t)strlen(value),
        "strict"
    );
}

static PyObject *session_argv(
    struct CodexPythonSession *session
) {
    size_t count = session->argc == 0 ? 1 : session->argc;
    PyObject *list = PyList_New((Py_ssize_t)count);
    if (list == NULL) {
        return NULL;
    }
    if (session->argc == 0) {
        PyObject *display_name =
            python_string(session->display_name);
        if (display_name == NULL) {
            Py_DECREF(list);
            return NULL;
        }
        PyList_SET_ITEM(list, 0, display_name);
        return list;
    }
    for (size_t index = 0; index < session->argc; index++) {
        PyObject *value = python_string(session->argv[index]);
        if (value == NULL) {
            Py_DECREF(list);
            return NULL;
        }
        PyList_SET_ITEM(list, (Py_ssize_t)index, value);
    }
    return list;
}

static PyObject *session_environment(
    struct CodexPythonSession *session
) {
    PyObject *dictionary = PyDict_New();
    if (dictionary == NULL) {
        return NULL;
    }
    for (
        size_t index = 0;
        index < session->environment_count;
        index++
    ) {
        PyObject *key =
            python_string(session->environment_keys[index]);
        PyObject *value =
            python_string(session->environment_values[index]);
        if (key == NULL
            || value == NULL
            || PyDict_SetItem(dictionary, key, value) != 0) {
            Py_XDECREF(key);
            Py_XDECREF(value);
            Py_DECREF(dictionary);
            return NULL;
        }
        Py_DECREF(key);
        Py_DECREF(value);
    }
    return dictionary;
}

static void *session_thread_main(void *context) {
    struct CodexPythonSession *session = context;
    int32_t exit_code = 1;
    const char *fallback_error = NULL;
    PyGILState_STATE gil = PyGILState_Ensure();

    PyObject *module = PyImport_ImportModule("_codex_bootstrap");
    PyObject *function = module == NULL
        ? NULL
        : PyObject_GetAttrString(module, "run");
    PyObject *capsule = PyCapsule_New(
        session,
        "CodexPythonSession",
        NULL
    );
    PyObject *kind = PyLong_FromLong((long)session->run_kind);
    PyObject *target = python_string(session->target);
    PyObject *argv = session_argv(session);
    PyObject *environment = session_environment(session);
    PyObject *cwd = python_string(session->working_directory);

    if (module == NULL
        || function == NULL
        || !PyCallable_Check(function)
        || capsule == NULL
        || kind == NULL
        || target == NULL
        || argv == NULL
        || environment == NULL
        || cwd == NULL) {
        fallback_error = "failed to prepare embedded Python session";
        PyErr_Clear();
    } else {
        PyObject *result = PyObject_CallFunctionObjArgs(
            function,
            capsule,
            kind,
            target,
            argv,
            environment,
            cwd,
            NULL
        );
        if (result == NULL) {
            fallback_error = "embedded Python session failed";
            PyErr_Clear();
        } else {
            long code = PyLong_AsLong(result);
            if (!PyErr_Occurred()
                && code >= INT32_MIN
                && code <= INT32_MAX) {
                exit_code = (int32_t)code;
            } else {
                fallback_error =
                    "invalid embedded Python exit status";
                PyErr_Clear();
            }
            Py_DECREF(result);
        }
    }

    Py_XDECREF(cwd);
    Py_XDECREF(environment);
    Py_XDECREF(argv);
    Py_XDECREF(target);
    Py_XDECREF(kind);
    Py_XDECREF(capsule);
    Py_XDECREF(function);
    Py_XDECREF(module);
    PyGILState_Release(gil);

    pthread_mutex_lock(&session->lock);
    session->terminated = true;
    session->input_closed = true;
    pthread_cond_broadcast(&session->input_changed);
    pthread_mutex_unlock(&session->lock);

    if (session->callbacks.termination_callback != NULL) {
        session->callbacks.termination_callback(
            session->callbacks.context,
            exit_code,
            fallback_error
        );
    }
    codex_python_session_release(session);
    return NULL;
}

CodexPythonStatus codex_python_session_start(
    CodexPythonSessionRef session,
    char **error_utf8
) {
    if (error_utf8 != NULL) {
        *error_utf8 = NULL;
    }
    if (session == NULL) {
        set_error(error_utf8, "invalid embedded Python session");
        return CODEX_PYTHON_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&session->lock);
    if (session->started) {
        pthread_mutex_unlock(&session->lock);
        set_error(error_utf8, "embedded Python session already started");
        return CODEX_PYTHON_ALREADY_STARTED;
    }
    session->started = true;
    session_retain(session);
    pthread_t thread;
    int result = pthread_create(
        &thread,
        NULL,
        session_thread_main,
        session
    );
    if (result != 0) {
        session->started = false;
        pthread_mutex_unlock(&session->lock);
        codex_python_session_release(session);
        set_error(error_utf8, "failed to start embedded Python thread");
        return CODEX_PYTHON_RUNTIME_ERROR;
    }
    pthread_detach(thread);
    pthread_mutex_unlock(&session->lock);
    return CODEX_PYTHON_OK;
}

CodexPythonStatus codex_python_session_write(
    CodexPythonSessionRef session,
    const uint8_t *bytes,
    size_t length
) {
    if (session == NULL || (length > 0 && bytes == NULL)) {
        return CODEX_PYTHON_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&session->lock);
    if (session->input_closed
        || session->cancelled
        || session->terminated) {
        pthread_mutex_unlock(&session->lock);
        return CODEX_PYTHON_INPUT_CLOSED;
    }
    if (length > 0) {
        if (length
            > (size_t)PY_SSIZE_T_MAX - session->input_length) {
            pthread_mutex_unlock(&session->lock);
            return CODEX_PYTHON_RUNTIME_ERROR;
        }
        size_t required = session->input_length + length;
        if (required > session->input_capacity) {
            size_t capacity =
                session->input_capacity == 0
                ? 4096
                : session->input_capacity;
            while (capacity < required) {
                if (capacity > SIZE_MAX / 2) {
                    capacity = required;
                    break;
                }
                capacity *= 2;
            }
            uint8_t *resized = realloc(session->input, capacity);
            if (resized == NULL) {
                pthread_mutex_unlock(&session->lock);
                return CODEX_PYTHON_RUNTIME_ERROR;
            }
            session->input = resized;
            session->input_capacity = capacity;
        }
        memcpy(
            session->input + session->input_length,
            bytes,
            length
        );
        session->input_length += length;
    }
    pthread_cond_broadcast(&session->input_changed);
    pthread_mutex_unlock(&session->lock);
    return CODEX_PYTHON_OK;
}

CodexPythonStatus codex_python_session_close_stdin(
    CodexPythonSessionRef session
) {
    if (session == NULL) {
        return CODEX_PYTHON_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&session->lock);
    session->input_closed = true;
    pthread_cond_broadcast(&session->input_changed);
    pthread_mutex_unlock(&session->lock);
    return CODEX_PYTHON_OK;
}

CodexPythonStatus codex_python_session_cancel(
    CodexPythonSessionRef session
) {
    if (session == NULL) {
        return CODEX_PYTHON_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&session->lock);
    session->cancelled = true;
    session->input_closed = true;
    pthread_cond_broadcast(&session->input_changed);
    pthread_mutex_unlock(&session->lock);
    return CODEX_PYTHON_OK;
}
