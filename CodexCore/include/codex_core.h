#ifndef CODEX_CORE_H
#define CODEX_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CodexCoreHandle CodexCoreHandle;
typedef struct CodexCoreNativeOfficialStream CodexCoreNativeOfficialStream;

typedef struct CodexCoreBuffer {
    uint8_t *ptr;
    size_t len;
    size_t capacity;
} CodexCoreBuffer;

typedef enum CodexCoreStatus {
    CODEX_CORE_STATUS_OK = 0,
    CODEX_CORE_STATUS_INVALID_ARGUMENT = 1,
    CODEX_CORE_STATUS_INVALID_JSON = 2,
    CODEX_CORE_STATUS_UNSUPPORTED_COMMAND = 3,
    CODEX_CORE_STATUS_NO_EVENT = 4,
    CODEX_CORE_STATUS_STORAGE = 5,
    CODEX_CORE_STATUS_NETWORK = 6,
    CODEX_CORE_STATUS_CANCELLED = 7,
    CODEX_CORE_STATUS_PANIC = 255
} CodexCoreStatus;

typedef int32_t (*CodexCoreEventCallback)(
    const uint8_t *bytes,
    size_t length,
    void *context
);

uint32_t codex_core_abi_version(void);
CodexCoreHandle *codex_core_create(void);
void codex_core_destroy(CodexCoreHandle *handle);
CodexCoreStatus codex_core_submit_json(
    CodexCoreHandle *handle,
    const uint8_t *bytes,
    size_t length
);
CodexCoreStatus codex_core_request_json(
    CodexCoreHandle *handle,
    const uint8_t *bytes,
    size_t length,
    CodexCoreBuffer *output
);
CodexCoreStatus codex_core_execute_official_response_json(
    CodexCoreHandle *handle,
    const uint8_t *bytes,
    size_t length
);
CodexCoreStatus codex_core_stream_official_response_json(
    CodexCoreHandle *handle,
    const uint8_t *bytes,
    size_t length,
    CodexCoreEventCallback callback,
    void *context
);
CodexCoreStatus codex_core_native_official_stream_create(
    CodexCoreHandle *handle,
    const uint8_t *bytes,
    size_t length,
    CodexCoreEventCallback callback,
    void *context,
    CodexCoreBuffer *prepared_request_output,
    CodexCoreNativeOfficialStream **stream_output
);
CodexCoreStatus codex_core_native_official_stream_begin_response_json(
    CodexCoreNativeOfficialStream *stream,
    uint16_t status,
    const uint8_t *headers_json,
    size_t headers_json_length
);
CodexCoreStatus codex_core_native_official_stream_push_body(
    CodexCoreNativeOfficialStream *stream,
    const uint8_t *bytes,
    size_t length
);
CodexCoreStatus codex_core_native_official_stream_end_body(
    CodexCoreNativeOfficialStream *stream
);
CodexCoreStatus codex_core_native_official_stream_cancel(
    CodexCoreNativeOfficialStream *stream
);
CodexCoreStatus codex_core_native_official_stream_finish(
    CodexCoreHandle *handle,
    CodexCoreNativeOfficialStream *stream
);
CodexCoreStatus codex_core_next_event_json(
    CodexCoreHandle *handle,
    CodexCoreBuffer *output
);
void codex_core_buffer_free(CodexCoreBuffer *buffer);

#ifdef __cplusplus
}
#endif

#endif
