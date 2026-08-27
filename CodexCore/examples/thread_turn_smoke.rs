use codex_core::{
    CodexCoreBuffer, CodexCoreStatus, codex_core_buffer_free, codex_core_create,
    codex_core_destroy, codex_core_next_event_json, codex_core_submit_json,
};
use std::slice;

const COMMANDS: [&[u8]; 4] = [
    br#"{"kind":"workspace.open","workspace":{"id":"11111111-1111-1111-1111-111111111111","displayName":"Mars Project","rootBookmarkId":null}}"#,
    br#"{"kind":"thread.start","thread":{"id":"22222222-2222-2222-2222-222222222222","workspaceId":"11111111-1111-1111-1111-111111111111","title":"First thread"}}"#,
    br#"{"kind":"turn.start","turn":{"id":"33333333-3333-3333-3333-333333333333","threadId":"22222222-2222-2222-2222-222222222222","status":"running"},"userItem":{"id":"44444444-4444-4444-4444-444444444444","threadId":"22222222-2222-2222-2222-222222222222","turnId":"33333333-3333-3333-3333-333333333333","kind":"userMessage","text":"Inspect this workspace"}}"#,
    br#"{"kind":"turn.complete","turnId":"33333333-3333-3333-3333-333333333333","assistantItem":{"id":"55555555-5555-5555-5555-555555555555","threadId":"22222222-2222-2222-2222-222222222222","turnId":"33333333-3333-3333-3333-333333333333","kind":"assistantMessage","text":"Workspace inspection complete"}}"#,
];

fn main() {
    let handle = codex_core_create();
    assert!(!handle.is_null());

    for command in COMMANDS {
        assert_eq!(
            codex_core_submit_json(handle, command.as_ptr(), command.len()),
            CodexCoreStatus::Ok
        );
    }

    let mut output = CodexCoreBuffer::default();
    for _ in 0..6 {
        assert_eq!(
            codex_core_next_event_json(handle, &mut output),
            CodexCoreStatus::Ok
        );
        assert!(!output.ptr.is_null());
        let event = unsafe { slice::from_raw_parts(output.ptr, output.len) };
        println!(
            "{}",
            std::str::from_utf8(event).expect("event must be UTF-8")
        );
        codex_core_buffer_free(&mut output);
        assert!(output.ptr.is_null());
        assert_eq!(output.len, 0);
        assert_eq!(output.capacity, 0);
    }

    assert_eq!(
        codex_core_next_event_json(handle, &mut output),
        CodexCoreStatus::NoEvent
    );
    codex_core_destroy(handle);
}
