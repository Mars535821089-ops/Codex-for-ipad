#define _POSIX_C_SOURCE 200809L

#include "codex_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *stage, size_t index, int status) {
    fprintf(
        stderr,
        "bridge_stage=%s index=%zu status=%d\n",
        stage,
        index,
        status
    );
    exit(20);
}

static size_t trim_record_separator(char *line, size_t length) {
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
        length -= 1;
    }
    return length;
}

static size_t drain_events(CodexCoreHandle *handle, const char *stage) {
    size_t count = 0;
    for (;;) {
        CodexCoreBuffer output = {0};
        CodexCoreStatus status = codex_core_next_event_json(handle, &output);
        if (status == CODEX_CORE_STATUS_NO_EVENT) {
            return count;
        }
        if (status != CODEX_CORE_STATUS_OK) {
            fail(stage, count + 1, status);
        }
        count += 1;
        codex_core_buffer_free(&output);
    }
}

static size_t submit_all(
    CodexCoreHandle *handle,
    const char *commands_path
) {
    FILE *commands = fopen(commands_path, "rb");
    if (commands == NULL) {
        fail("open_commands", 0, -1);
    }

    char *line = NULL;
    size_t capacity = 0;
    size_t submitted = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, commands)) >= 0) {
        size_t record_length = trim_record_separator(line, (size_t)length);
        if (record_length == 0) {
            continue;
        }
        CodexCoreStatus status = codex_core_submit_json(
            handle,
            (const uint8_t *)line,
            record_length
        );
        submitted += 1;
        if (status != CODEX_CORE_STATUS_OK) {
            free(line);
            fclose(commands);
            fail("submit", submitted, status);
        }
    }
    free(line);
    fclose(commands);
    if (submitted < 2) {
        fail("submit_count", submitted, -1);
    }
    return submitted;
}

static void submit_storage_open(
    CodexCoreHandle *handle,
    const char *commands_path
) {
    FILE *commands = fopen(commands_path, "rb");
    if (commands == NULL) {
        fail("reopen_commands", 0, -1);
    }
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    do {
        length = getline(&line, &capacity, commands);
        if (length < 0) {
            free(line);
            fclose(commands);
            fail("reopen_record", 0, -1);
        }
    } while (trim_record_separator(line, (size_t)length) == 0);

    size_t record_length = trim_record_separator(line, (size_t)length);
    CodexCoreStatus status = codex_core_submit_json(
        handle,
        (const uint8_t *)line,
        record_length
    );
    free(line);
    fclose(commands);
    if (status != CODEX_CORE_STATUS_OK) {
        fail("reopen", 1, status);
    }
}

static size_t request_all(
    CodexCoreHandle *handle,
    const char *requests_path,
    const char *responses_path
) {
    FILE *requests = fopen(requests_path, "rb");
    if (requests == NULL) {
        fail("open_requests", 0, -1);
    }
    FILE *responses = fopen(responses_path, "wb");
    if (responses == NULL) {
        fclose(requests);
        fail("open_responses", 0, -1);
    }

    char *line = NULL;
    size_t capacity = 0;
    size_t requested = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, requests)) >= 0) {
        size_t record_length = trim_record_separator(line, (size_t)length);
        if (record_length == 0) {
            continue;
        }
        CodexCoreBuffer output = {0};
        CodexCoreStatus status = codex_core_request_json(
            handle,
            (const uint8_t *)line,
            record_length,
            &output
        );
        requested += 1;
        if (status != CODEX_CORE_STATUS_OK) {
            free(line);
            fclose(requests);
            fclose(responses);
            fail("request", requested, status);
        }
        if (output.len > 0 && fwrite(output.ptr, 1, output.len, responses) != output.len) {
            codex_core_buffer_free(&output);
            free(line);
            fclose(requests);
            fclose(responses);
            fail("write_response", requested, -1);
        }
        fputc('\n', responses);
        codex_core_buffer_free(&output);
    }
    free(line);
    fclose(requests);
    fclose(responses);
    return requested;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fail("arguments", (size_t)argc, -1);
    }

    CodexCoreHandle *writer = codex_core_create();
    if (writer == NULL) {
        fail("create_writer", 0, -1);
    }
    size_t submitted = submit_all(writer, argv[1]);
    size_t persisted_events = drain_events(writer, "drain_writer");
    codex_core_destroy(writer);

    CodexCoreHandle *reader = codex_core_create();
    if (reader == NULL) {
        fail("create_reader", 0, -1);
    }
    submit_storage_open(reader, argv[1]);
    size_t replayed_events = drain_events(reader, "drain_reader");
    size_t requests = request_all(reader, argv[2], argv[3]);
    codex_core_destroy(reader);

    FILE *metrics = fopen(argv[4], "wb");
    if (metrics == NULL) {
        fail("open_metrics", 0, -1);
    }
    fprintf(
        metrics,
        "%zu %zu %zu %zu\n",
        submitted,
        persisted_events,
        replayed_events,
        requests
    );
    fclose(metrics);
    return 0;
}
